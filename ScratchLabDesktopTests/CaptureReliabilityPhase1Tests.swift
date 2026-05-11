import AVFoundation
import CoreGraphics
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
        var hardResetCallCount = 0
        var requestedModes: [BeatEngineMode] = []
        var requestedBPMs: [Int] = []
        var shouldThrowOnStart = false

        func start(mode: BeatEngineMode, bpm: Int) throws {
            if shouldThrowOnStart {
                throw ScratchLabBeatEngineError.unableToStartAudio
            }
            startCallCount += 1
            requestedModes.append(mode)
            requestedBPMs.append(bpm)
        }

        func stop() {
            stopCallCount += 1
        }

        func hardResetBeatPlayback() {
            hardResetCallCount += 1
        }
    }

    private final class MockScratchCoachDemoPlayable: ScratchCoachDemoPlayable {
        var isPlaying = false
        var currentTime: TimeInterval = 0
        var playCallCount = 0
        var pauseCallCount = 0
        var stopCallCount = 0
        var prepareCallCount = 0
        var playReturnValue = true

        func prepareToPlay() {
            prepareCallCount += 1
        }

        func play() -> Bool {
            playCallCount += 1
            isPlaying = playReturnValue
            return playReturnValue
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

    @MainActor
    func testMacRoutineSessionSetupAllowsBlankPerformerAndUsesFallbackDisplayName() {
        let viewModel = SessionSetupViewModel(surface: .macRoutine)
        viewModel.scratchType = .unknown
        viewModel.bpmText = ""

        XCTAssertEqual(viewModel.validationMessages, [])
        XCTAssertEqual(viewModel.sessionName(defaultAppName: "Untitled Session"), "Untitled Session")
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

    // MARK: - Beat Lifecycle Tests

    @MainActor
    func testBeatCanStartStopStartAgain() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        store.startPlayback()
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playbackState, .playing)

        store.stopPlayback()
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.playbackState, .stopped)

        store.startPlayback()
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playbackState, .playing)
        XCTAssertEqual(engine.startCallCount, 2)
    }

    @MainActor
    func testHardResetReturnsBeatToReadyState() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        store.startPlayback()
        store.stopPlayback()

        store.retryPlayback()

        XCTAssertEqual(engine.hardResetCallCount, 1)
        XCTAssertEqual(engine.startCallCount, 2)
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playbackState, .playing)
    }

    @MainActor
    func testStartBeatSelfHealsFromFailedState() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        engine.shouldThrowOnStart = true
        store.startPlayback()
        XCTAssertFalse(store.isPlaying)
        guard case .failed = store.playbackState else {
            return XCTFail("Expected failed state")
        }

        engine.shouldThrowOnStart = false
        store.retryPlayback()
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playbackState, .playing)
        XCTAssertEqual(engine.hardResetCallCount, 1)
    }

    @MainActor
    func testBPMChangeAfterStopReschedulesAtNewTempo() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        store.setBPM(70)
        store.startPlayback()
        store.stopPlayback()
        store.setBPM(90)
        store.startPlayback()

        XCTAssertEqual(engine.requestedBPMs, [70, 90])
    }

    @MainActor
    func testStopPlaybackAfterStartSetsStoppedState() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        store.startPlayback()
        store.stopPlayback()

        XCTAssertEqual(store.playbackState, .stopped)
        XCTAssertFalse(store.isPlaying)
    }

    @MainActor
    func testStartFailureSurfacesFailedState() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        engine.shouldThrowOnStart = true
        store.startPlayback()

        guard case .failed(let reason) = store.playbackState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotNil(store.playbackErrorMessage)
    }

    @MainActor
    func testBeatOffOnAfterFailureCallsHardReset() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        engine.shouldThrowOnStart = true
        store.startPlayback()
        engine.shouldThrowOnStart = false

        store.retryPlayback()

        XCTAssertEqual(engine.hardResetCallCount, 1)
        XCTAssertTrue(store.isPlaying)
    }

    @MainActor
    func testRepeatedTakesCanEachStartBeat() throws {
        let defaults = try makeEphemeralUserDefaults()
        let engine = MockPracticeBeatPlaybackEngine()
        let store = PracticeBeatStore(defaults: defaults, beatEngine: engine)

        store.setBeatEnabled(true)
        for bpm in [70, 90, 110] {
            store.setBPM(bpm)
            store.startPlayback()
            XCTAssertTrue(store.isPlaying, "Beat should be playing at \(bpm) BPM")
            store.handleRecordingFlowStarted()
            XCTAssertFalse(store.isPlaying, "Beat should stop after recording at \(bpm) BPM")
        }
        XCTAssertEqual(engine.startCallCount, 3)
        XCTAssertEqual(engine.requestedBPMs, [70, 90, 110])
    }

    // MARK: - Captured Notation Display Model Tests

    @MainActor
    func testCapturedNotationSnapshotWithMovementEventsIsDetectedSource() {
        let snapshot = makeDetectedNotationSnapshot()
        XCTAssertEqual(snapshot.notationSource, "detected")
        XCTAssertFalse(snapshot.recordMovementEvents.isEmpty)
        XCTAssertFalse(snapshot.audioEvents.isEmpty)
    }

    @MainActor
    func testCapturedNotationSnapshotAudioOnlyIsPartialSource() {
        let snapshot = makeAudioOnlyDetectedNotationSnapshot()
        XCTAssertEqual(snapshot.notationSource, "partial")
        XCTAssertTrue(snapshot.recordMovementEvents.isEmpty)
        XCTAssertFalse(snapshot.audioEvents.isEmpty)
    }

    @MainActor
    func testCapturedNotationSnapshotPreservesAllAudioEvents() {
        let snapshot = makeDetectedNotationSnapshot()
        XCTAssertEqual(snapshot.audioEvents.count, 2)
        XCTAssertEqual(snapshot.audioEvents.first?.eventKind, "scratchBurst")
    }

    @MainActor
    func testCapturedNotationSnapshotPreservesAllMovementEvents() {
        let snapshot = makeDetectedNotationSnapshot()
        XCTAssertEqual(snapshot.recordMovementEvents.count, 2)
        XCTAssertEqual(snapshot.recordMovementEvents.first?.direction, "forward")
        XCTAssertEqual(snapshot.recordMovementEvents.last?.direction, "backward")
    }

    @MainActor
    func testPartialNotationSnapshotHasNoMovementEvents() {
        let snapshot = makeAudioOnlyDetectedNotationSnapshot()
        XCTAssertTrue(snapshot.recordMovementEvents.isEmpty)
        XCTAssertFalse(snapshot.hasDetectedMovementEvents)
        XCTAssertTrue(snapshot.hasAudioEvents)
    }

    @MainActor
    func testCapturedNotationConfidenceReflectsSource() {
        let detected = makeDetectedNotationSnapshot()
        XCTAssertNotNil(detected.notationConfidence)
        XCTAssertGreaterThan(detected.notationConfidence ?? 0, 0.0)

        let partial = makeAudioOnlyDetectedNotationSnapshot()
        XCTAssertNotNil(partial.notationConfidence)
    }

    @MainActor
    func testMacCaptureEngineNormalizesCameraSpaceDirectionToRecordDirection() {
        XCTAssertEqual(
            MacCaptureEngine.normalizedRecordDirection(forCameraSpaceDirection: .movingBackward),
            .forward
        )
        XCTAssertEqual(
            MacCaptureEngine.normalizedRecordDirection(forCameraSpaceDirection: .movingForward),
            .backward
        )
        XCTAssertNil(MacCaptureEngine.normalizedRecordDirection(forCameraSpaceDirection: .idle))
        XCTAssertNil(MacCaptureEngine.normalizedRecordDirection(forCameraSpaceDirection: .searching))
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

    @MainActor
    func testBabyScratchDemoPlaybackCoordinatorConfiguresBabyScratchAudio() throws {
        let mockPlayable = MockScratchCoachDemoPlayable()
        let root = try makeTemporaryDirectory()
        let resourceURL = root.appendingPathComponent(ScratchLabDemoSessionBuilder.demoAudioFileName)
        var requestedAudioNames: [String] = []
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { audioName in
                requestedAudioNames.append(audioName)
                return resourceURL
            },
            playerFactory: { url in
                XCTAssertEqual(url, resourceURL)
                return mockPlayable
            }
        )
        let coordinator = BabyScratchDemoPlaybackCoordinator(audioPlayer: player)

        coordinator.configureBabyScratchIfNeeded()

        XCTAssertEqual(requestedAudioNames, [ScratchLabDemoSessionBuilder.demoAudioFileName])
        XCTAssertTrue(coordinator.isConfiguredForBabyScratch)
        XCTAssertTrue(coordinator.isAudioAvailable)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.lastErrorMessage)
        XCTAssertEqual(mockPlayable.prepareCallCount, 1)
    }

    @MainActor
    func testBabyScratchDemoPlaybackCoordinatorDoesNotFakePlaybackWhenAudioIsMissing() {
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in nil },
            playerFactory: { _ in
                XCTFail("Missing Baby Scratch audio should not create a playback instance.")
                return MockScratchCoachDemoPlayable()
            }
        )
        let coordinator = BabyScratchDemoPlaybackCoordinator(audioPlayer: player)

        coordinator.playBabyScratch()

        XCTAssertFalse(coordinator.isConfiguredForBabyScratch)
        XCTAssertFalse(coordinator.isAudioAvailable)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(player.playbackState, .stopped)
        XCTAssertEqual(coordinator.lastErrorMessage, "Baby Scratch demo audio is unavailable.")
    }

    @MainActor
    func testBabyScratchDemoPlaybackCoordinatorDoesNotFakePlaybackWhenPlayFails() throws {
        let mockPlayable = MockScratchCoachDemoPlayable()
        mockPlayable.playReturnValue = false
        let root = try makeTemporaryDirectory()
        let resourceURL = root.appendingPathComponent(ScratchLabDemoSessionBuilder.demoAudioFileName)
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in resourceURL },
            playerFactory: { _ in mockPlayable }
        )
        let coordinator = BabyScratchDemoPlaybackCoordinator(audioPlayer: player)

        coordinator.playBabyScratch()

        XCTAssertTrue(coordinator.isConfiguredForBabyScratch)
        XCTAssertTrue(coordinator.isAudioAvailable)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(player.playbackState, .stopped)
        XCTAssertEqual(mockPlayable.playCallCount, 1)
        XCTAssertEqual(coordinator.lastErrorMessage, "Baby Scratch demo audio could not start.")
    }

    @MainActor
    func testBabyScratchDemoPlaybackCoordinatorPauseStopAndReplayState() throws {
        let mockPlayable = MockScratchCoachDemoPlayable()
        let root = try makeTemporaryDirectory()
        let resourceURL = root.appendingPathComponent(ScratchLabDemoSessionBuilder.demoAudioFileName)
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in resourceURL },
            playerFactory: { _ in mockPlayable }
        )
        let coordinator = BabyScratchDemoPlaybackCoordinator(audioPlayer: player)

        coordinator.playBabyScratch()
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertTrue(coordinator.isPlaying)

        mockPlayable.currentTime = 1.25
        coordinator.pause()
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(mockPlayable.pauseCallCount, 1)
        XCTAssertEqual(coordinator.currentAudioTime, 1.25, accuracy: 0.0001)

        coordinator.replayBabyScratch()
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(mockPlayable.currentTime, 0, accuracy: 0.0001)

        coordinator.stop()
        XCTAssertEqual(coordinator.playbackState, .stopped)
        XCTAssertTrue(coordinator.isStopped)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(mockPlayable.currentTime, 0, accuracy: 0.0001)
    }

    func testNotationTickNoOpsWhenDemoPlaybackIsPaused() throws {
        let notationURL = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: notationURL, encoding: .utf8)
        let tickSource = try sourceSlice(
            in: source,
            from: "func tick(captureEngine: MacCaptureEngine)",
            through: "private func fireTargetStrokes("
        )

        XCTAssertTrue(tickSource.contains("guard demo.playbackState == .playing else"))
        XCTAssertTrue(tickSource.contains("if demo.playbackState == .stopped, playbackTime != 0"))
        XCTAssertTrue(tickSource.contains("if demo.playbackState == .playing && !demo.isPlaying"))
        XCTAssertTrue(tickSource.contains("let audioTime = demo.currentAudioTime"))
        XCTAssertTrue(tickSource.contains("if playbackTime != newLoopTime"))
        XCTAssertFalse(tickSource.contains("if isPlaying && !demo.isPlaying"))

        let guardRange = try XCTUnwrap(tickSource.range(of: "guard demo.playbackState == .playing else"))
        let audioTimeRange = try XCTUnwrap(tickSource.range(of: "let audioTime = demo.currentAudioTime"))
        let playbackSetRange = try XCTUnwrap(tickSource.range(of: "playbackTime = newLoopTime"))
        XCTAssertLessThan(guardRange.lowerBound, audioTimeRange.lowerBound)
        XCTAssertLessThan(guardRange.lowerBound, playbackSetRange.lowerBound)
    }

    func testCoachPauseHoldsPoseFromAudioTimeAndAvoidsPausedTimelineWork() throws {
        let coachSourceURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let macSourceURL = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let coachSource = try String(contentsOf: coachSourceURL, encoding: .utf8)
        let macSource = try String(contentsOf: macSourceURL, encoding: .utf8)
        let rigSource = try sourceSlice(
            in: coachSource,
            from: "struct ScratchCoachRigView: View",
            through: "private var hasCustomAnimationStateProvider"
        )

        XCTAssertTrue(rigSource.contains("if isPlayingProvider()"))
        XCTAssertTrue(rigSource.contains("TimelineView(.periodic"))
        XCTAssertTrue(rigSource.contains("rigContent(\n                    playbackTime: playbackTimeProvider(),\n                    isPlaying: false"))
        XCTAssertTrue(rigSource.contains("ScratchLabPerformanceSignpost.withInterval(\"CoachRigUpdate\")"))
        XCTAssertTrue(macSource.contains("guard !babyScratchDemo.isStopped else { return .babyScratchOpen }"))
        XCTAssertTrue(macSource.contains("BabyScratchDemoPlaybackCoordinator.coachPose(for: audioTime)"))
        XCTAssertFalse(macSource.contains("CACurrentMediaTime()"))
    }

    func testPausePerformanceSignpostsAndDiagnosticsAreWired() throws {
        let coreURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let notationURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let coachURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let captureURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let audioURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/AudioEngine.swift")
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")

        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)
        let notationSource = try String(contentsOf: notationURL, encoding: .utf8)
        let coachSource = try String(contentsOf: coachURL, encoding: .utf8)
        let captureSource = try String(contentsOf: captureURL, encoding: .utf8)
        let exportSource = try String(contentsOf: exportURL, encoding: .utf8)
        let audioSource = try String(contentsOf: audioURL, encoding: .utf8)
        let macSource = try String(contentsOf: macURL, encoding: .utf8)

        XCTAssertTrue(coreSource.contains("enum ScratchLabPerformanceSignpost"))
        XCTAssertTrue(notationSource.contains("ScratchLabPerformanceSignpost.begin(\"NotationTick\")"))
        XCTAssertTrue(coachSource.contains("ScratchLabPerformanceSignpost.withInterval(\"CoachRigUpdate\")"))
        XCTAssertTrue(captureSource.contains("ScratchLabPerformanceSignpost.begin(\"CameraFrameProcess\")"))
        XCTAssertTrue(captureSource.contains("ScratchLabPerformanceSignpost.begin(\"CaptureFrameProcess\")"))
        XCTAssertTrue(captureSource.contains("ScratchLabPerformanceSignpost.begin(\"AudioAnalyze\")"))
        XCTAssertTrue(audioSource.contains("ScratchLabPerformanceSignpost.begin(\"AudioAnalyze\")"))
        XCTAssertTrue(exportSource.contains("ScratchLabPerformanceSignpost.begin(\"ExportZIP\")"))
        XCTAssertTrue(macSource.contains("private var performanceDiagnosticsCard: some View"))
        XCTAssertTrue(macSource.contains("Playback"))
        XCTAssertTrue(macSource.contains("Camera"))
        XCTAssertTrue(macSource.contains("Last notation tick"))
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
        let forwardState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.18,
            isPlaying: true
        )
        let forwardHoldState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.24,
            isPlaying: true
        )
        let backwardState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.43,
            isPlaying: true
        )
        let backwardHoldState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.52,
            isPlaying: true
        )
        let stoppedState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.30,
            isPlaying: false
        )

        XCTAssertEqual(
            forwardState.crossfaderPosition,
            ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition,
            accuracy: 0.0001
        )
        XCTAssertTrue(forwardState.crossfaderOpenState)
        XCTAssertEqual(forwardState.recordPosition, 0.7979, accuracy: 0.001)
        XCTAssertEqual(forwardState.recordRotationDegrees, 47.8723, accuracy: 0.001)
        XCTAssertEqual(forwardHoldState.recordPosition, 1, accuracy: 0.0001)
        XCTAssertEqual(forwardHoldState.recordRotationDegrees, 60, accuracy: 0.0001)
        XCTAssertLessThan(backwardState.recordPosition, forwardHoldState.recordPosition)
        XCTAssertGreaterThan(backwardState.recordPosition, 0)
        XCTAssertLessThan(backwardState.recordRotationDegrees, 60)
        XCTAssertGreaterThan(backwardState.recordRotationDegrees, 0)
        XCTAssertEqual(backwardHoldState, .babyScratchOpen)
        XCTAssertEqual(stoppedState, .neutral)
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

        for _ in 0..<240 {
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

        for _ in 0..<240 {
            if coordinator.lastResult?.archiveURL == destinationURL { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.archiveURL, destinationURL)
        XCTAssertFalse(result.shouldCleanupAfterUse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(coordinator.statusMessage, "Export saved.")
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

        for _ in 0..<240 {
            if coordinator.lastResult?.archiveURL == destinationURL { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.archiveURL, destinationURL)
        XCTAssertFalse(result.shouldCleanupAfterUse)
        XCTAssertTrue(fileManager.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(coordinator.statusMessage, "Export saved.")
    }

    @MainActor
    func testSessionExportCoordinatorSaveArchiveFailureSurfacesRecoverableError() async throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root, useRealMedia: true)
        let destinationURL = root
            .appendingPathComponent("Missing Parent", isDirectory: true)
            .appendingPathComponent("SavedSession.zip")
        let coordinator = SessionExportCoordinator(
            archiveSaveDestinationProvider: { _ in destinationURL }
        )

        coordinator.saveArchiveCopy(for: .package(package))

        for _ in 0..<240 {
            if case .failed(.unableToSaveArchive) = coordinator.state { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        if case .failed(.unableToSaveArchive) = coordinator.state {
            XCTAssertEqual(
                coordinator.statusMessage,
                "Export failed: ScratchLab couldn't save to the selected location. Try Desktop or choose another folder."
            )
        } else {
            XCTFail("Expected save to fail for a missing parent directory")
        }
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
        XCTAssertTrue(source.contains("NSFileCoordinator()"))
        XCTAssertTrue(source.contains("statusMessage = \"Choose save location\""))
        XCTAssertTrue(source.contains("case .unableToSaveArchive"))
    }

    func testScratchLabDesktopEntitlementsAllowUserSelectedArchiveSave() throws {
        let entitlementsURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/ScratchLabDesktop.entitlements")
        let source = try String(contentsOf: entitlementsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("com.apple.security.files.user-selected.read-write"))
    }

    func testMacCaptureEngineFormattedAudioSignalPercentCoversFiniteValuesAndClamps() {
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: 0.0, hasPublishedAudioLevel: true), "0%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: 0.5, hasPublishedAudioLevel: true), "50%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: 1.0, hasPublishedAudioLevel: true), "100%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: -0.4, hasPublishedAudioLevel: true), "0%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: 1.6, hasPublishedAudioLevel: true), "100%")
    }

    func testMacCaptureEngineFormattedAudioSignalPercentReturnsSafeZeroForInvalidOrUnavailableInput() {
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: .nan, hasPublishedAudioLevel: true), "0%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: .infinity, hasPublishedAudioLevel: true), "0%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: nil, hasPublishedAudioLevel: true), "0%")
        XCTAssertEqual(MacCaptureEngine.formattedAudioPercent(for: 0.4, hasPublishedAudioLevel: false), "0%")
    }

    func testMacCaptureEnginePracticeAudioStatusTextUsesSafeUnavailableStates() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedAudioDeviceUniqueID = ""

        XCTAssertEqual(engine.practiceAudioStatusText, "Audio Missing")

        engine.selectedAudioDeviceUniqueID = "missing-device"
        XCTAssertEqual(engine.practiceAudioStatusText, "Audio Missing")
    }

    @MainActor
    func testMacCaptureEngineAudioSignalStatusSeparatesReadinessFromSignal() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.availableAudioDevices = []
        engine.selectedAudioDeviceUniqueID = ""

        XCTAssertEqual(engine.audioReadinessText, "Audio Missing")
        XCTAssertEqual(engine.audioSignalStatusText, "No input")

        let device = AVCaptureDevice.default(for: .audio)
        if let device {
            engine.availableAudioDevices = [device]
            engine.selectedAudioDeviceUniqueID = device.uniqueID
            XCTAssertEqual(engine.audioReadinessText, "Audio Ready")
            XCTAssertEqual(engine.audioSignalStatusText, "No signal")
        }
    }

    func testPreferredCaptureAudioDeviceSelectsExactSeratoVirtualAudioOverMicrophone() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "mic", name: "Built-in Microphone"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "serato", name: "Serato Virtual Audio")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: nil,
            previousSelectionUniqueID: nil,
            systemDefaultUniqueID: "mic"
        )

        XCTAssertEqual(decision.device?.uniqueID, "serato")
        XCTAssertEqual(decision.priority, .exactSeratoVirtualAudio)
    }

    func testPreferredCaptureAudioDeviceSelectsSeratoLikeDeviceOverMicrophone() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "mic", name: "MacBook Pro Microphone"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "seratoAlt", name: "Serato DJ Pro Output")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: nil,
            previousSelectionUniqueID: nil,
            systemDefaultUniqueID: "mic"
        )

        XCTAssertEqual(decision.device?.uniqueID, "seratoAlt")
        XCTAssertEqual(decision.priority, .seratoLike)
    }

    func testPreferredCaptureAudioDevicePreservesExplicitUserSelectionWhenStillAvailable() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "mic", name: "Built-in Microphone"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "serato", name: "Serato Virtual Audio")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: "mic",
            previousSelectionUniqueID: "mic",
            systemDefaultUniqueID: "mic"
        )

        XCTAssertEqual(decision.device?.uniqueID, "mic")
        XCTAssertEqual(decision.priority, .explicitUserSelection)
    }

    func testPreferredCaptureAudioDeviceFallsBackToSeratoWhenPreviousSelectionIsMissing() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "serato", name: "Serato Virtual Audio"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "mic", name: "Built-in Microphone")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: nil,
            previousSelectionUniqueID: "missing",
            systemDefaultUniqueID: "mic"
        )

        XCTAssertEqual(decision.device?.uniqueID, "serato")
        XCTAssertEqual(decision.priority, .exactSeratoVirtualAudio)
    }

    func testPreferredCaptureAudioDeviceFallsBackToSystemDefaultWhenSeratoIsMissing() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "first", name: "Built-in Microphone"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "default", name: "USB Mixer Record")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: nil,
            previousSelectionUniqueID: nil,
            systemDefaultUniqueID: "default"
        )

        XCTAssertEqual(decision.device?.uniqueID, "default")
        XCTAssertEqual(decision.priority, .systemDefault)
    }

    func testPreferredCaptureAudioDeviceFallsBackToFirstAvailableWhenNoHigherPriorityMatchExists() {
        let devices = [
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "first", name: "Built-in Microphone"),
            MacCaptureEngine.AudioInputDeviceChoice(uniqueID: "second", name: "USB Audio Codec")
        ]

        let decision = MacCaptureEngine.preferredCaptureAudioDevice(
            from: devices,
            explicitSelectionUniqueID: nil,
            previousSelectionUniqueID: nil,
            systemDefaultUniqueID: "missing"
        )

        XCTAssertEqual(decision.device?.uniqueID, "first")
        XCTAssertEqual(decision.priority, .firstAvailable)
    }

    func testCaptureInputStatusUsesSelectedAudioDeviceStatusLine() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("detail: captureEngine.selectedAudioDeviceStatusLine"))
        XCTAssertTrue(source.contains("Text(captureEngine.selectedAudioDeviceStatusLine)"))
        XCTAssertTrue(source.contains("Button(\"Use Serato Audio\")"))
    }

    func testRoutineRecordingMetadataUsesSelectedAudioDeviceNameAndUniqueID() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let audioDeviceName = audioDevices.first(where: { $0.uniqueID == selectedAudioID })?.localizedName"))
        XCTAssertTrue(source.contains("audioDeviceUniqueID: selectedAudioID"))
        XCTAssertTrue(source.contains("audioDeviceName: audioDeviceName"))
    }

    func testCaptureTabAutoSelectsAudioWithoutPractice() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("captureEngine.autoSelectCaptureAudioDeviceIfNeeded()"))
        XCTAssertTrue(source.contains("WorkspaceTab.resolved(from: newValue) == .capture"))
        XCTAssertTrue(source.contains("captureEngine.refreshDevices()"))
    }

    @MainActor
    func testMacCaptureEngineStaleSignalResetsToZero() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let device = AVCaptureDevice.default(for: .audio)
        if let device {
            engine.availableAudioDevices = [device]
            engine.selectedAudioDeviceUniqueID = device.uniqueID
        }

        engine.publishAudioSignalLevel(1.0, receivedAt: 10)
        XCTAssertGreaterThan(engine.currentAudioSignalLevel, 0)

        engine.refreshAudioSignalForCurrentTime(now: 11)
        XCTAssertEqual(engine.currentAudioSignalLevel, 0)
        XCTAssertEqual(engine.formattedAudioSignalPercent, "0%")
        XCTAssertEqual(engine.audioSignalStatusText, device == nil ? "No input" : "No signal")
    }

    @MainActor
    func testMacCaptureEngineStopResetsSignalLevel() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let device = AVCaptureDevice.default(for: .audio)
        if let device {
            engine.availableAudioDevices = [device]
            engine.selectedAudioDeviceUniqueID = device.uniqueID
        }
        engine.publishAudioSignalLevel(0.8, receivedAt: 1)
        if device == nil {
            XCTAssertEqual(engine.currentAudioSignalLevel, 0)
        } else {
            XCTAssertGreaterThan(engine.currentAudioSignalLevel, 0)
        }

        engine.stop()

        XCTAssertEqual(engine.currentAudioSignalLevel, 0)
        XCTAssertEqual(engine.formattedAudioSignalPercent, "0%")
    }

    func testMacCaptureEngineFormattedAudioPercentSourceHasNoFatalDisplayGuards() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sourceSlice = try sourceSlice(
            in: source,
            from: "var formattedAudioSignalPercent: String {",
            through: "var audioReadinessText: String {"
        )

        XCTAssertFalse(sourceSlice.contains("assertionFailure"))
        XCTAssertFalse(sourceSlice.contains("precondition"))
        XCTAssertFalse(sourceSlice.contains("fatalError"))
        XCTAssertFalse(sourceSlice.contains("!"))
        XCTAssertTrue(source.contains("static func formattedAudioPercent("))
    }

    func testPracticeHeaderUsesSafeAudioStatusText() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sourceSlice = try sourceSlice(
            in: source,
            from: "private var practiceHeaderCard: some View {",
            through: "private var practiceControlCard: some View {"
        )

        XCTAssertTrue(sourceSlice.contains("captureEngine.practiceAudioStatusText"))
        XCTAssertFalse(sourceSlice.contains("captureEngine.formattedAudioPercent,"))
        XCTAssertFalse(sourceSlice.contains("assertionFailure"))
        XCTAssertFalse(sourceSlice.contains("fatalError"))
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
        XCTAssertFalse(source.contains("ScratchLabBabyScratchDemoMotionPattern"))
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

    // MARK: - App Store P1 Regression Tests

    func testInfoPlistDoesNotDeclareGameCenterDashboardKey() throws {
        let plistURL = projectRootURL().appendingPathComponent("ScratchLab/Info.plist")
        let source = try String(contentsOf: plistURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("GCSupportsGameCenterDashboard"),
            "GCSupportsGameCenterDashboard must not appear in Info.plist — no Game Center entitlement exists"
        )
    }

    func testMainMenuViewDoesNotContainPlaceholderStubs() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("OnlineBattleLobbyView"),
            "OnlineBattleLobbyView placeholder must be removed (Rule 2.3.1)"
        )
        XCTAssertFalse(
            source.contains("TutorialHubView"),
            "TutorialHubView placeholder must be removed (Rule 2.3.1)"
        )
    }

    func testIOSAppTargetDoesNotIncludeAIBattleModeView() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("AIBattleModeView.swift in Sources"),
            "AIBattleModeView.swift must not be compiled into the iOS app target (Rule 2.5.1)"
        )
    }

    func testIOSAppTargetDoesNotIncludeFormulaPlaygroundView() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: projectURL, encoding: .utf8)

        // FormulaPlaygroundView has no navigation path in the iOS app — remove it from Sources.
        // The four Formula model files (AST/Catalog/Parser/Renderer) must stay because
        // ScratchRenderTimeline and ScratchRenderEvent are used by PracticeModeView and LevelSelectView.
        XCTAssertFalse(
            source.contains("A1000022 /* FormulaPlaygroundView.swift in Sources */"),
            "FormulaPlaygroundView must not be compiled into the iOS app target (Rule 2.5.1)"
        )

        // Formula model files must still be present in the iOS target.
        XCTAssertTrue(
            source.contains("A1000018 /* ScratchFormulaAST.swift in Sources */"),
            "ScratchFormulaAST.swift must remain in iOS target — used by ScratchRenderTimeline"
        )
        XCTAssertTrue(
            source.contains("A1000021 /* ScratchFormulaRenderer.swift in Sources */"),
            "ScratchFormulaRenderer.swift must remain in iOS target — provides ScratchRenderTimeline/ScratchRenderEvent"
        )

        // Desktop test entries must still be present.
        XCTAssertTrue(source.contains("B5AA0004A1B2C3D4E5F60709 /* ScratchFormulaAST.swift in Sources */"))
        XCTAssertTrue(source.contains("B5AA0005A1B2C3D4E5F60709 /* ScratchFormulaCatalog.swift in Sources */"))
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

    func testDemoModeProducesFeedbackWithoutHardware() throws {
        let mainMenuURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let mainMenuSource = try String(contentsOf: mainMenuURL, encoding: .utf8)
        let demoStart = try XCTUnwrap(mainMenuSource.range(of: "private struct DemoModeView: View"))
        let demoEnd = try XCTUnwrap(mainMenuSource.range(of: "// MARK: - Menu Button Component"))
        let demoSource = String(mainMenuSource[demoStart.lowerBound..<demoEnd.lowerBound])

        XCTAssertTrue(mainMenuSource.contains("title: \"Try Demo\""))
        XCTAssertTrue(mainMenuSource.contains("subtitle: \"See scratch feedback instantly\""))
        XCTAssertTrue(mainMenuSource.contains(".navigationDestination(isPresented: $showingDemoMode)"))
        XCTAssertTrue(demoSource.contains("ScratchLabDemoModeController()"))
        XCTAssertTrue(demoSource.contains("demoController.startDemo()"))
        XCTAssertTrue(demoSource.contains("ScratchCoachCardContent("))
        XCTAssertTrue(demoSource.contains("animationStateProvider:"))
        XCTAssertTrue(demoSource.contains("Motion Feedback"))
        XCTAssertFalse(demoSource.contains("CameraPreviewView("))
        XCTAssertFalse(demoSource.contains("audioEngine.start()"))
        XCTAssertFalse(demoSource.contains("requestRecordPermission"))

        let coreURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)
        XCTAssertTrue(coreSource.contains("final class ScratchLabDemoModeAnalyzer"))
        XCTAssertTrue(coreSource.contains("struct ScratchNotation"))
        XCTAssertTrue(coreSource.contains("struct BabyScratchReferenceMotionTimeline"))
        XCTAssertTrue(coreSource.contains("struct BabyScratchExtractedStrokeResource"))
        XCTAssertTrue(coreSource.contains("baby_scratch_strokes"))
        XCTAssertTrue(coreSource.contains("baby_scratch"))
        XCTAssertTrue(coreSource.contains("usesNotationResource"))
        XCTAssertTrue(coreSource.contains("usesExtractedStrokeResource"))
        XCTAssertTrue(coreSource.contains("fallbackStrokeSegments"))
        XCTAssertTrue(coreSource.contains("struct ScratchLabBabyScratchDemoMotionPattern"))
        XCTAssertTrue(coreSource.contains("static let demoStart: TimeInterval = 0"))
        XCTAssertTrue(coreSource.contains("static let demoEnd: TimeInterval = 42.866625"))
        XCTAssertTrue(coreSource.contains("private static let activityFrameSize = 1_024"))
        XCTAssertTrue(coreSource.contains("private static let activeEnergyThresholdOn: Float = 0.20"))
        XCTAssertTrue(coreSource.contains("private static let activeEnergyThresholdOff: Float = 0.10"))
        XCTAssertTrue(coreSource.contains("activitySegmentDirections"))
        XCTAssertTrue(coreSource.contains("segmentIndex.isMultiple(of: 2)"))
        XCTAssertTrue(coreSource.contains("processFrame(\n        playbackTime: TimeInterval"))
        XCTAssertTrue(coreSource.contains("static let demoAudioFileName = \"baby_noBeat.wav\""))

        let macAnalyzerURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let macAnalyzerSource = try String(contentsOf: macAnalyzerURL, encoding: .utf8)
        let macDemoStart = try XCTUnwrap(macAnalyzerSource.range(of: "private var macDemoModeCard: some View"))
        let macDemoEnd = try XCTUnwrap(macAnalyzerSource.range(of: "private var captureSidebar: some View"))
        let macDemoSource = String(macAnalyzerSource[macDemoStart.lowerBound..<macDemoEnd.lowerBound])
        XCTAssertTrue(macDemoSource.contains("Text(\"Try Demo\")"))
        XCTAssertTrue(macDemoSource.contains("Text(\"See scratch feedback instantly\")"))
        XCTAssertTrue(macDemoSource.contains("No hardware needed for demo"))
        XCTAssertTrue(macAnalyzerSource.contains("@StateObject private var demoModeController = ScratchLabDemoModeController()"))
        XCTAssertTrue(macAnalyzerSource.contains("if liveInputEnabled {\n                startMacLiveInput()"))
        XCTAssertTrue(macAnalyzerSource.contains("Button(liveInputEnabled ? \"Live Input Enabled\" : \"Start Live Input\")"))
        XCTAssertTrue(macAnalyzerSource.contains("private func exportMacDemoSession()"))
        XCTAssertTrue(macAnalyzerSource.contains("try ScratchLabDemoSessionBuilder().makePackage()"))
        XCTAssertFalse(macAnalyzerSource.contains(".onAppear {\n            captureEngine.start()"))
        XCTAssertFalse(macDemoSource.contains("captureEngine.start()"))
        XCTAssertFalse(macDemoSource.contains("requestAccess"))

        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let sampleBuffer = try ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)
        var producedBalances: [ScratchMotionBalance] = []
        let frameCount = 1_024
        let maximumFrameWindows = max(1, Int((sampleBuffer.duration * sampleBuffer.sampleRate) / Double(frameCount)))
        for _ in 0..<maximumFrameWindows {
            let frame = analyzer.processNextFrame(frameCount: frameCount)
            if let balance = frame.feedback?.balance, balance != .listening {
                producedBalances.append(balance)
                break
            }
        }

        XCTAssertFalse(producedBalances.isEmpty)
        XCTAssertTrue(producedBalances.allSatisfy { $0 == .balanced || $0 == .unbalanced })
    }

    func testDemoModeQuietAudioReturnsNeutralCoachPose() {
        let samples = Array(repeating: Float(0.0001), count: 48_000 * 2)
        let sampleBuffer = ScratchLabDemoAudioSampleBuffer(samples: samples, sampleRate: 48_000)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        let frame = analyzer.processFrame(playbackTime: 0.42, windowDuration: 1.0 / 30.0)
        let laterFrame = analyzer.processFrame(playbackTime: 0.84, windowDuration: 1.0 / 30.0)

        XCTAssertEqual(frame.animationState, .neutral)
        XCTAssertEqual(frame.animationState, laterFrame.animationState)
        XCTAssertEqual(frame.direction, laterFrame.direction)
        XCTAssertEqual(frame.direction, .neutral)
        XCTAssertEqual(frame.feedback?.balance, .listening)
    }

    func testDemoModeActiveAudioReturnsMovingCoachPose() {
        let samples = Array(repeating: Float(0.35), count: 48_000 * 2)
        let sampleBuffer = ScratchLabDemoAudioSampleBuffer(samples: samples, sampleRate: 48_000)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        // Mid-first-stroke (forward 0.27 → 0.778 in the bundled notation).
        let frame = analyzer.processFrame(playbackTime: 0.40, windowDuration: 1.0 / 30.0)

        XCTAssertGreaterThan(abs(frame.animationState.recordPosition), 0.2)
        XCTAssertGreaterThan(abs(frame.animationState.recordRotationDegrees), 5)
        XCTAssertNotEqual(frame.direction, .neutral)
    }

    func testDemoModeBabyScratchPatternIncludesHoldPhases() {
        // First forward hold: stroke 0 ends at 0.778, holdAfter=0.292 → hold runs 0.778..1.07.
        let forwardHoldA = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: 0.85,
            activityLevel: 1
        )
        let forwardHoldB = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: 1.00,
            activityLevel: 1
        )
        // First backward hold: stroke 1 ends at 1.378, holdAfter=0.082 → hold runs 1.378..1.46.
        let backwardHoldA = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: 1.40,
            activityLevel: 1
        )
        let backwardHoldB = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: 1.42,
            activityLevel: 1
        )

        XCTAssertEqual(forwardHoldA.animationState, forwardHoldB.animationState)
        XCTAssertEqual(forwardHoldA.direction, .neutral)
        XCTAssertEqual(forwardHoldA.animationState.recordPosition, 1, accuracy: 0.0001)
        XCTAssertEqual(backwardHoldA.animationState, backwardHoldB.animationState)
        XCTAssertEqual(backwardHoldA.direction, .neutral)
        XCTAssertEqual(backwardHoldA.animationState, .neutral)
    }

    private func decodedBabyScratchStrokeResource() throws -> BabyScratchExtractedStrokeResource {
        let resourceURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoMotion/baby_scratch_strokes.json")
        let data = try Data(contentsOf: resourceURL)
        return try JSONDecoder().decode(BabyScratchExtractedStrokeResource.self, from: data)
    }

    private func decodedBabyScratchNotation() throws -> ScratchNotation {
        let resourceURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json")
        let data = try Data(contentsOf: resourceURL)
        return try JSONDecoder().decode(ScratchNotation.self, from: data)
    }

    func testBabyScratchNotationJSONDecodesAndContainsNoSourceProvenance() throws {
        let resourceURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json")
        let rawJSON = try String(contentsOf: resourceURL, encoding: .utf8)
        let notation = try decodedBabyScratchNotation()

        XCTAssertEqual(notation.scratchID, "baby")
        XCTAssertEqual(notation.demoStart, BabyScratchReferenceMotionTimeline.demoStart, accuracy: 0.0001)
        XCTAssertEqual(notation.demoEnd, BabyScratchReferenceMotionTimeline.demoEnd, accuracy: 0.0001)
        XCTAssertEqual(notation.strokes.count, 10)
        XCTAssertEqual(notation.strokes.count, notation.strokeSegments.count)
        XCTAssertTrue(notation.strokes.allSatisfy { $0.faderState == .open })
        let phraseStart = try XCTUnwrap(notation.phraseStart)
        let phraseEnd = try XCTUnwrap(notation.phraseEnd)
        let firstStroke = try XCTUnwrap(notation.strokes.first)
        let lastStroke = try XCTUnwrap(notation.strokes.last)
        XCTAssertEqual(phraseStart, firstStroke.startTime, accuracy: 0.0001)
        XCTAssertEqual(phraseEnd, lastStroke.endTime, accuracy: 0.0001)
        XCTAssertLessThan(phraseEnd, 6.5)
        XCTAssertEqual(notation.timelineDuration, phraseEnd, accuracy: 0.0001)
        XCTAssertTrue(notation.strokes.allSatisfy { $0.startTime >= phraseStart && $0.endTime <= phraseEnd })
        let slowToFastGap = notation.strokes[2].startTime - notation.strokes[1].endTime
        XCTAssertLessThan(slowToFastGap, 0.20)
        XCTAssertEqual(notation.strokes[2].startTime, 1.46, accuracy: 0.0001)
        XCTAssertFalse(rawJSON.contains("/Users/"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("cxl"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("makemkv"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("qbert"))
    }

    func testBabyScratchNotationClassifiesNonUniformStrokeSpeeds() throws {
        let notation = try decodedBabyScratchNotation()
        let durations = notation.strokes.map(\.duration)
        let roundedDurations = Set(durations.map { Int(($0 * 1_000).rounded()) })
        let fastDurations = notation.strokes
            .filter { $0.speedClassification == .fast }
            .map(\.duration)
        let slowDurations = notation.strokes
            .filter { $0.speedClassification == .slow }
            .map(\.duration)
        let fastestSlow = try XCTUnwrap(slowDurations.min())
        let slowestFast = try XCTUnwrap(fastDurations.max())
        let slowAverage = slowDurations.reduce(0, +) / Double(slowDurations.count)
        let fastAverage = fastDurations.reduce(0, +) / Double(fastDurations.count)
        let roundedDurationsByTenThousand = durations.map { Int(($0 * 10_000).rounded()) }

        XCTAssertGreaterThan(roundedDurations.count, 1)
        XCTAssertLessThan(slowestFast, fastestSlow)
        XCTAssertGreaterThanOrEqual(slowDurations.count, 3)
        XCTAssertGreaterThanOrEqual(fastDurations.count, 3)
        XCTAssertGreaterThan(slowAverage, fastAverage)
        XCTAssertEqual(
            roundedDurationsByTenThousand,
            [5080, 3080, 3030, 5280, 3080, 2880, 5680, 3230, 2830, 8480]
        )
    }

    func testBabyScratchExtractedMotionJSONDecodesAndContainsNoSourceProvenance() throws {
        let resourceURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoMotion/baby_scratch_strokes.json")
        let rawJSON = try String(contentsOf: resourceURL, encoding: .utf8)
        let resource = try decodedBabyScratchStrokeResource()

        XCTAssertEqual(resource.scratchID, "baby")
        XCTAssertEqual(resource.timingSource, "wav_transient_extraction")
        XCTAssertEqual(resource.demoStart, BabyScratchReferenceMotionTimeline.demoStart, accuracy: 0.0001)
        XCTAssertEqual(resource.demoEnd, BabyScratchReferenceMotionTimeline.demoEnd, accuracy: 0.0001)
        XCTAssertEqual(resource.strokes.count, 10)
        XCTAssertEqual(resource.strokes.count, resource.strokeSegments.count)
        let phraseStart = try XCTUnwrap(resource.phraseStart)
        let phraseEnd = try XCTUnwrap(resource.phraseEnd)
        let firstStroke = try XCTUnwrap(resource.strokes.first)
        let lastStroke = try XCTUnwrap(resource.strokes.last)
        XCTAssertEqual(phraseStart, firstStroke.startTime, accuracy: 0.0001)
        XCTAssertEqual(phraseEnd, lastStroke.endTime, accuracy: 0.0001)
        XCTAssertEqual(resource.timelineDuration, phraseEnd, accuracy: 0.0001)
        XCTAssertTrue(resource.strokes.allSatisfy { $0.startTime >= phraseStart && $0.endTime <= phraseEnd })
        XCTAssertLessThan(resource.strokes[2].startTime - resource.strokes[1].endTime, 0.20)
        XCTAssertFalse(rawJSON.contains("/Users/"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("cxl"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("makemkv"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("qbert"))
    }

    func testBabyScratchExtractedMotionResourceIsBundledForApps() throws {
        let projectSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let resourcePhaseMatches = projectSource.components(
            separatedBy: "Resources/CoachDemoMotion in Resources"
        ).count - 1
        let notationPhaseMatches = projectSource.components(
            separatedBy: "Resources/Notation in Resources"
        ).count - 1

        XCTAssertTrue(projectSource.contains("Resources/CoachDemoMotion"))
        XCTAssertGreaterThanOrEqual(resourcePhaseMatches, 2)
        XCTAssertTrue(projectSource.contains("Resources/Notation"))
        XCTAssertGreaterThanOrEqual(notationPhaseMatches, 2)
    }

    func testBabyScratchReferenceMotionTimelineUsesChapterOffsetAndNonUniformSegments() throws {
        let resource = try decodedBabyScratchNotation()
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let keyframes = BabyScratchReferenceMotionTimeline.keyframes
        let durations = timeline.map(\.duration)
        let roundedDurations = Set(durations.map { Int(($0 * 1_000).rounded()) })
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let audioFile = try AVAudioFile(forReading: audioURL)
        let bundledDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        XCTAssertTrue(BabyScratchReferenceMotionTimeline.usesNotationResource)
        XCTAssertFalse(BabyScratchReferenceMotionTimeline.usesExtractedStrokeResource)
        XCTAssertEqual(timeline.count, resource.strokes.count)
        XCTAssertGreaterThan(keyframes.count, timeline.count)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.demoStart, 0, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.demoEnd, 42.866625, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.sourceDuration, 42.866625, accuracy: 0.0001)
        XCTAssertEqual(bundledDuration, BabyScratchReferenceMotionTimeline.sourceDuration, accuracy: 0.01)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.sourceTime(forPlaybackTime: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.timelineTime(forSourceTime: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.timelineTime(forPlaybackTime: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.timelineTime(forPlaybackTime: 1.46), 1.46, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.phraseStart, 0.27, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.phraseEnd, 5.743, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.phraseLoopDuration, 5.473, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleCount, 4)
        XCTAssertEqual(
            BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration,
            BabyScratchReferenceMotionTimeline.sourceDuration / 4,
            accuracy: 0.0001
        )
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.phraseDuration, resource.timelineDuration, accuracy: 0.0001)
        XCTAssertEqual(timeline[0].startTime, resource.strokes[0].startTime, accuracy: 0.0001)
        XCTAssertEqual(timeline[0].endTime, resource.strokes[0].endTime, accuracy: 0.0001)
        XCTAssertEqual(timeline[0].direction, resource.strokes[0].motionDirection)
        XCTAssertEqual(timeline[0].holdAfter, resource.strokeSegments[0].holdAfter, accuracy: 0.0001)
        XCTAssertGreaterThan(roundedDurations.count, 1)
        XCTAssertGreaterThanOrEqual(timeline.count, 10)
        XCTAssertLessThanOrEqual(timeline.count, 20)
        XCTAssertEqual(keyframes[0].sourceTime, BabyScratchReferenceMotionTimeline.demoStart + timeline[0].startTime, accuracy: 0.0001)
        XCTAssertEqual(keyframes[0].handViewerHour, 3, accuracy: 0.0001)
        XCTAssertEqual(keyframes[0].stickerViewerHour, 6, accuracy: 0.0001)
        XCTAssertEqual(keyframes[1].handViewerHour, 5, accuracy: 0.0001)
        XCTAssertEqual(keyframes[1].stickerViewerHour, 8, accuracy: 0.0001)
        XCTAssertEqual(keyframes[1].recordRotationDegrees, 60, accuracy: 0.0001)
        XCTAssertEqual(
            ScratchLabBabyScratchDemoMotionPattern.babyScratchStrokeTimelineDuration,
            resource.timelineDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(ScratchLabBabyScratchDemoMotionPattern.babyScratchDemoPhaseOffset, 0, accuracy: 0.0001)
        XCTAssertFalse(ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(playbackTime: 0))
        XCTAssertTrue(
            ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(
                playbackTime: timeline[0].startTime + 0.001
            )
        )
        XCTAssertFalse(
            ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(
                playbackTime: timeline[0].endTime + min(0.02, max(0.001, timeline[0].holdAfter / 2))
            )
        )
        XCTAssertTrue(
            ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(
                playbackTime: timeline[1].startTime + 0.001
            )
        )
    }

    func testBabyScratchCoachTimingLoadsNotationAtAudioPlaybackTime() throws {
        let resource = try decodedBabyScratchNotation()
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let firstForwardAfterPair = try XCTUnwrap(timeline.dropFirst(2).first)

        XCTAssertTrue(BabyScratchReferenceMotionTimeline.usesNotationResource)
        XCTAssertFalse(BabyScratchReferenceMotionTimeline.usesExtractedStrokeResource)
        XCTAssertEqual(resource.strokes.count, 10)
        XCTAssertEqual(timeline.count, 10)
        XCTAssertEqual(firstForwardAfterPair.direction, .forward)
        XCTAssertEqual(firstForwardAfterPair.startTime, 1.46, accuracy: 0.0001)
        XCTAssertEqual(resource.strokes[2].startTime, 1.46, accuracy: 0.0001)

        let poseAtThirdStrokeStart = BabyScratchReferenceMotionTimeline.pose(at: 1.46)
        XCTAssertEqual(poseAtThirdStrokeStart.direction, .forward)
        XCTAssertEqual(poseAtThirdStrokeStart.scratchProgress, 0, accuracy: 0.0001)

        let pastEndPose = BabyScratchReferenceMotionTimeline.pose(
            at: BabyScratchReferenceMotionTimeline.sourceDuration + 1.0
        )
        XCTAssertEqual(pastEndPose.direction, .neutral)
        XCTAssertEqual(pastEndPose.scratchProgress, 0, accuracy: 0.0001)
    }

    func testBabyScratchCoachTimingUsesFullAudioCycleAndPhraseLoopMode() throws {
        let firstStroke = try XCTUnwrap(BabyScratchReferenceMotionTimeline.strokeSegments.first)
        let postPhraseSilenceTime: TimeInterval = 5.85
        let postPhraseSilencePose = BabyScratchReferenceMotionTimeline.pose(at: postPhraseSilenceTime)
        // Probe inside stroke 0 of cycle 2 (small offset past the boundary to avoid FP drift).
        let secondAudioCycleProbe = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration
            + BabyScratchReferenceMotionTimeline.phraseStart + 0.10
        let secondAudioCyclePose = BabyScratchReferenceMotionTimeline.pose(at: secondAudioCycleProbe)
        let notationPhraseLoopTime = BabyScratchReferenceMotionTimeline.phraseEnd + 0.254
        let notationPhraseLoopPose = BabyScratchReferenceMotionTimeline.pose(
            at: notationPhraseLoopTime,
            loopMode: .notationPhrase
        )
        let disabledLoopPose = BabyScratchReferenceMotionTimeline.pose(
            at: BabyScratchReferenceMotionTimeline.sourceDuration + 0.01,
            loopMode: .disabled
        )

        XCTAssertFalse(ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(playbackTime: postPhraseSilenceTime))
        XCTAssertEqual(postPhraseSilencePose.direction, .neutral)
        XCTAssertEqual(postPhraseSilencePose.scratchProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(secondAudioCyclePose.direction, firstStroke.direction)
        XCTAssertGreaterThan(secondAudioCyclePose.scratchProgress, 0)
        XCTAssertLessThan(secondAudioCyclePose.scratchProgress, 0.5)
        XCTAssertTrue(ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(playbackTime: secondAudioCycleProbe))
        XCTAssertEqual(
            BabyScratchReferenceMotionTimeline.timelineTime(
                forPlaybackTime: notationPhraseLoopTime,
                loopMode: .notationPhrase
            ),
            0.524,
            accuracy: 0.001
        )
        XCTAssertEqual(notationPhraseLoopPose.direction, .forward)
        XCTAssertGreaterThan(notationPhraseLoopPose.scratchProgress, 0.45)
        XCTAssertLessThan(notationPhraseLoopPose.scratchProgress, 0.55)
        XCTAssertEqual(disabledLoopPose.direction, .neutral)
        XCTAssertEqual(disabledLoopPose.scratchProgress, 0, accuracy: 0.0001)
    }

    #if DEBUG
    func testBabyScratchCoachTimingDebugProbeReportsStrokeProgress() {
        let firstScratchStart = BabyScratchReferenceMotionTimeline.debugTimingProbe(at: 0.27)
        let firstScratchEnd = BabyScratchReferenceMotionTimeline.debugTimingProbe(at: 0.778)
        let slowBackwardEnd = BabyScratchReferenceMotionTimeline.debugTimingProbe(at: 2.368)
        let firstFastForwardStart = BabyScratchReferenceMotionTimeline.debugTimingProbe(at: 1.46)
        let postPhraseSilence = BabyScratchReferenceMotionTimeline.debugTimingProbe(at: 5.85)
        let postPhrasePhraseLoop = BabyScratchReferenceMotionTimeline.debugTimingProbe(
            at: 5.997,
            loopMode: .notationPhrase
        )

        XCTAssertEqual(BabyScratchReferenceMotionTimeline.debugProbePlaybackTimes, [0.27, 0.778, 2.368, 1.46, 5.85, 5.997])
        XCTAssertEqual(firstScratchStart.strokeIndex, 0)
        XCTAssertEqual(firstScratchStart.direction, .forward)
        XCTAssertFalse(firstScratchStart.isHold)
        XCTAssertEqual(firstScratchStart.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(firstScratchEnd.strokeIndex, 0)
        XCTAssertEqual(firstScratchEnd.direction, .neutral)
        XCTAssertTrue(firstScratchEnd.isHold)
        XCTAssertEqual(firstScratchEnd.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(slowBackwardEnd.strokeIndex, 3)
        XCTAssertEqual(slowBackwardEnd.direction, .neutral)
        XCTAssertTrue(slowBackwardEnd.isHold)
        XCTAssertEqual(slowBackwardEnd.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(slowBackwardEnd.timingSource, "Notation/baby_scratch.json")

        XCTAssertEqual(firstFastForwardStart.strokeIndex, 2)
        XCTAssertEqual(firstFastForwardStart.direction, .forward)
        XCTAssertFalse(firstFastForwardStart.isHold)
        XCTAssertEqual(firstFastForwardStart.timelineTime, 1.46, accuracy: 0.0001)
        XCTAssertEqual(firstFastForwardStart.progress, 0, accuracy: 0.0001)

        XCTAssertNil(postPhraseSilence.strokeIndex)
        XCTAssertEqual(postPhraseSilence.direction, .neutral)
        XCTAssertTrue(postPhraseSilence.isHold)
        XCTAssertEqual(postPhrasePhraseLoop.strokeIndex, 0)
        XCTAssertEqual(postPhrasePhraseLoop.direction, .forward)
        XCTAssertFalse(postPhrasePhraseLoop.isHold)
        XCTAssertEqual(postPhrasePhraseLoop.timelineTime, 0.524, accuracy: 0.001)
        XCTAssertEqual(postPhrasePhraseLoop.progress, 0.5, accuracy: 0.001)
        XCTAssertTrue(BabyScratchReferenceMotionTimeline.debugTimingReport(at: 1.46).contains("stroke=2"))
    }
    #endif

    func testBabyScratchReferenceMotionTimelineDoesNotSkipAlternatingStrokes() throws {
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let resource = try decodedBabyScratchNotation()

        XCTAssertEqual(timeline.count, resource.strokes.count)
        XCTAssertGreaterThanOrEqual(timeline.count, 10)
        XCTAssertLessThanOrEqual(timeline.count, 20)
        XCTAssertEqual(timeline.map(\.direction), resource.strokeSegments.map(\.direction))
        for index in 0..<timeline.count {
            let expectedDirection: ScratchMotionDirection = index.isMultiple(of: 2) ? .forward : .backward
            XCTAssertEqual(timeline[index].direction, expectedDirection)
        }
        XCTAssertEqual(timeline[0].startProgress, 0, accuracy: 0.0001)
        for index in 0..<(timeline.count - 1) {
            XCTAssertEqual(timeline[index].endProgress, timeline[index + 1].startProgress, accuracy: 0.0001)
        }

        let sortedByStartTime = timeline.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(timeline, sortedByStartTime)
        let gaps = zip(timeline, timeline.dropFirst()).map { next, following in
            following.startTime - next.endTime
        }
        XCTAssertTrue(gaps.contains { $0 < 0.20 })
        XCTAssertGreaterThan(Set(gaps.map { Int(($0 * 1_000).rounded()) }).count, 1)
    }

    func testBabyScratchReferenceMotionTimelineUsesNotationWithoutGeometryChanges() throws {
        let resource = try decodedBabyScratchNotation()
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let coreSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(BabyScratchReferenceMotionTimeline.usesNotationResource)
        XCTAssertTrue(coreSource.contains("ScratchNotation.loadBabyScratchFromBundle()"))
        XCTAssertTrue(coreSource.contains("?? extractedStrokeResource?.strokeSegments"))
        XCTAssertEqual(timeline.count, resource.strokes.count)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.phraseDuration, resource.timelineDuration, accuracy: 0.0001)
        XCTAssertFalse(coreSource.contains("0.9208"))
        XCTAssertFalse(coreSource.contains("1.5750"))
        XCTAssertFalse(coreSource.contains("2.3600"))
        XCTAssertFalse(coreSource.contains("fast chiga"))
        XCTAssertFalse(coreSource.contains("smoothStep"))

        XCTAssertEqual(BabyScratchReferenceMotionTimeline.handStartViewerHour, 3, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.handEndViewerHour, 5, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.stickerStartViewerHour, 6, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.stickerEndViewerHour, 8, accuracy: 0.0001)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.recordRotationRangeDegrees, 60, accuracy: 0.0001)
    }

    #if DEBUG
    func testBabyScratchReferenceAssetManifestIncludesAvailableVideoAngles() throws {
        let manifest = BabyScratchReferenceAsset.babyScratch79BPM
        let expectedAnglePaths: Set<String> = [
            "processed_makemkv/baby/79bpm/angle_1_video.mkv",
            "processed_makemkv/baby/79bpm/angle_2_video.mkv",
            "processed_makemkv/baby/79bpm/angle_3_video.mkv",
            "processed_makemkv/baby/79bpm/angle_4_video.mkv",
        ]
        let expectedFocus: Set<BabyScratchReferenceValidationFocus> = [
            .handPosition,
            .recordStickerMovement,
            .directionChanges,
            .holdPhases,
            .strokeSpeed,
        ]
        let durations = BabyScratchReferenceMotionTimeline.strokeSegments.map(\.duration)
        let roundedDurations = Set(durations.map { Int(($0 * 1_000).rounded()) })

        XCTAssertEqual(manifest.scratchName, "Baby Scratch")
        XCTAssertEqual(manifest.bpm, 79)
        XCTAssertEqual(manifest.demoStart, BabyScratchReferenceMotionTimeline.demoStart, accuracy: 0.0001)
        XCTAssertEqual(manifest.demoEnd, BabyScratchReferenceMotionTimeline.demoEnd, accuracy: 0.0001)
        XCTAssertEqual(manifest.audioPath, "processed_makemkv/baby/79bpm/angle_1_noBeat.wav")
        XCTAssertEqual(manifest.timingSource, .wavAudio)
        XCTAssertEqual(manifest.videoUsage, .visualReferenceOnly)
        XCTAssertEqual(manifest.motionTimelinePath, "Notation/baby_scratch.json")
        XCTAssertEqual(manifest.embeddedMotionTimelineName, "BabyScratchReferenceMotionTimelineFallback")
        XCTAssertFalse(manifest.automaticVideoTrackingEnabled)
        XCTAssertEqual(Set(manifest.videoAngles.map(\.path)), expectedAnglePaths)
        XCTAssertEqual(manifest.videoAngles.first?.angleID, "angle_1")
        XCTAssertEqual(manifest.videoAngles.first?.role, .primary)
        XCTAssertTrue(manifest.videoAngles.dropFirst().allSatisfy { $0.role == .validation })
        XCTAssertEqual(
            Set(manifest.videoAngles.flatMap(\.validationFocus)),
            expectedFocus
        )
        XCTAssertGreaterThan(roundedDurations.count, 1)

        let referenceRoot = URL(fileURLWithPath: "/Users/karlwatson/Movies/CXL DATASET")
        let sourceFolder = referenceRoot.appendingPathComponent("processed_makemkv/baby/79bpm")
        if FileManager.default.fileExists(atPath: sourceFolder.path) {
            let availableAnglePaths = Set(
                try FileManager.default.contentsOfDirectory(atPath: sourceFolder.path)
                    .filter { $0.hasPrefix("angle_") && $0.hasSuffix("_video.mkv") }
                    .map { "processed_makemkv/baby/79bpm/\($0)" }
            )

            XCTAssertEqual(Set(manifest.videoAngles.map(\.path)), availableAnglePaths)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: referenceRoot.appendingPathComponent(manifest.audioPath).path
                )
            )
            for angle in manifest.videoAngles {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: referenceRoot.appendingPathComponent(angle.path).path
                    ),
                    angle.path
                )
            }
        }
    }
    #endif

    func testDemoModeDoesNotPlayRawBabyScratchReferenceVideoAngles() throws {
        let mainMenuSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift"),
            encoding: .utf8
        )
        let coachSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift"),
            encoding: .utf8
        )
        let macAnalyzerSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift"),
            encoding: .utf8
        )
        let coreSource = try String(
            contentsOf: projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift"),
            encoding: .utf8
        )
        let demoSources = [
            "MainMenuView.swift": mainMenuSource,
            "ScratchCoachViews.swift": coachSource,
            "MacAnalyzerView.swift": macAnalyzerSource,
        ]

        for (fileName, source) in demoSources {
            XCTAssertFalse(source.contains("VideoPlayer("), fileName)
            XCTAssertFalse(source.contains("AVPlayer("), fileName)
            XCTAssertFalse(source.contains(".mkv"), fileName)
        }

        XCTAssertTrue(coreSource.contains("struct BabyScratchReferenceAsset"))
        XCTAssertTrue(coreSource.contains("videoUsage: .visualReferenceOnly"))
        XCTAssertTrue(coreSource.contains("motionTimelinePath: \"Notation/baby_scratch.json\""))
        XCTAssertTrue(coreSource.contains("embeddedMotionTimelineName: \"BabyScratchReferenceMotionTimelineFallback\""))
        XCTAssertTrue(coreSource.contains("automaticVideoTrackingEnabled: false"))
        XCTAssertTrue(coreSource.contains("let timelineState = BabyScratchReferenceMotionTimeline.pose("))
        XCTAssertTrue(coachSource.contains("demoMotionSampleBuffer?.coachRigAnimationState("))
    }

    func testBabyScratchReferenceMotionPoseLinksHandRecordAndStickerProgress() throws {
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let firstStroke = try XCTUnwrap(timeline.first)
        let holdSegment = try XCTUnwrap(timeline.first { $0.holdAfter > 0.03 })
        let midPose = BabyScratchReferenceMotionTimeline.pose(
            at: firstStroke.startTime + (firstStroke.duration / 2)
        )
        let holdPoseA = BabyScratchReferenceMotionTimeline.pose(
            at: holdSegment.endTime + min(0.01, holdSegment.holdAfter / 3)
        )
        let holdPoseB = BabyScratchReferenceMotionTimeline.pose(
            at: holdSegment.endTime + min(0.02, holdSegment.holdAfter * 2 / 3)
        )
        let preScratchPose = BabyScratchReferenceMotionTimeline.pose(at: 0)

        XCTAssertEqual(preScratchPose.direction, .neutral)
        XCTAssertEqual(preScratchPose.scratchProgress, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(midPose.scratchProgress, 0.45)
        XCTAssertLessThan(midPose.scratchProgress, 0.55)
        XCTAssertEqual(midPose.handViewerHour, 3 + (2 * midPose.scratchProgress), accuracy: 0.0001)
        XCTAssertEqual(midPose.stickerViewerHour, 6 + (2 * midPose.scratchProgress), accuracy: 0.0001)
        XCTAssertEqual(midPose.recordRotationDegrees, 60 * midPose.scratchProgress, accuracy: 0.0001)
        XCTAssertEqual(holdPoseA, holdPoseB)
        XCTAssertTrue(holdPoseA.isHold)
        XCTAssertEqual(holdPoseA.direction, .neutral)
    }

    func testDemoModeInactiveAudioOverridesPatternWithNeutralPose() {
        let inactiveState = ScratchLabBabyScratchDemoMotionPattern.state(
            playbackTime: 0.06,
            activityLevel: 0.09
        )

        XCTAssertEqual(inactiveState.animationState, .neutral)
        XCTAssertEqual(inactiveState.direction, .neutral)
        XCTAssertEqual(inactiveState.feedback.balance, .listening)
    }

    func testDemoModeMotionFollowsAudioBurstTiming() throws {
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let firstForward = try XCTUnwrap(timeline.first { $0.direction == .forward })
        let firstBackward = try XCTUnwrap(
            timeline.first { $0.startTime > firstForward.startTime && $0.direction == .backward }
        )
        let secondForward = try XCTUnwrap(
            timeline.first { $0.startTime > firstBackward.startTime && $0.direction == .forward }
        )
        let secondBackward = try XCTUnwrap(
            timeline.first { $0.startTime > secondForward.startTime && $0.direction == .backward }
        )
        let firstHoldTime = firstForward.endTime + min(0.02, max(0.001, firstForward.holdAfter / 2))
        func strokeTime(_ segment: ScratchLabBabyScratchStrokeSegment, progress: TimeInterval) -> TimeInterval {
            segment.startTime + (segment.duration * progress)
        }
        let sampleRate = 48_000
        let samples = Array(repeating: Float(0.35), count: sampleRate * 2)
        let sampleBuffer = ScratchLabDemoAudioSampleBuffer(samples: samples, sampleRate: Double(sampleRate))
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        let firstStrokeFrame = analyzer.processFrame(
            playbackTime: strokeTime(firstForward, progress: 0.60),
            windowDuration: 1.0 / 30.0
        )
        let firstBackwardFrame = analyzer.processFrame(
            playbackTime: strokeTime(firstBackward, progress: 0.60),
            windowDuration: 1.0 / 30.0
        )
        let firstHoldFrame = analyzer.processFrame(playbackTime: firstHoldTime, windowDuration: 1.0 / 30.0)
        let secondForwardFrame = analyzer.processFrame(
            playbackTime: strokeTime(secondForward, progress: 0.60),
            windowDuration: 1.0 / 30.0
        )
        let secondBackwardFrame = analyzer.processFrame(
            playbackTime: strokeTime(secondBackward, progress: 0.60),
            windowDuration: 1.0 / 30.0
        )

        XCTAssertEqual(firstStrokeFrame.direction, .forward)
        XCTAssertGreaterThan(firstStrokeFrame.animationState.recordPosition, 0.2)
        XCTAssertEqual(firstBackwardFrame.direction, .backward)
        XCTAssertLessThan(firstBackwardFrame.animationState.recordPosition, firstStrokeFrame.animationState.recordPosition)
        XCTAssertEqual(firstHoldFrame.direction, .neutral)
        XCTAssertEqual(firstHoldFrame.animationState.recordPosition, 1, accuracy: 0.0001)
        XCTAssertEqual(secondForwardFrame.direction, .forward)
        XCTAssertEqual(secondBackwardFrame.direction, .backward)
        XCTAssertLessThan(secondBackwardFrame.animationState.recordPosition, secondForwardFrame.animationState.recordPosition)
    }

    func testLowerCoachRigAnimationUsesBabyScratchStrokeTimeline() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let sampleBuffer = try ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        let firstForward = try XCTUnwrap(timeline.first { $0.direction == .forward })
        let firstBackward = try XCTUnwrap(
            timeline.first { $0.startTime > firstForward.startTime && $0.direction == .backward }
        )
        let secondForward = try XCTUnwrap(
            timeline.first { $0.startTime > firstBackward.startTime && $0.direction == .forward }
        )
        let secondBackward = try XCTUnwrap(
            timeline.first { $0.startTime > secondForward.startTime && $0.direction == .backward }
        )
        let laterForward = try XCTUnwrap(
            timeline.first { $0.startTime > 1.3 && $0.direction == .forward }
        )
        let laterBackward = try XCTUnwrap(
            timeline.first { $0.startTime > laterForward.startTime && $0.direction == .backward }
        )
        let firstHoldTime = firstForward.endTime + min(0.02, max(0.001, firstForward.holdAfter / 2))
        func strokeTime(_ segment: ScratchLabBabyScratchStrokeSegment, progress: TimeInterval) -> TimeInterval {
            segment.startTime + (segment.duration * progress)
        }

        let firstForwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(firstForward, progress: 0.60),
            isPlaying: true
        )
        let firstBackwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(firstBackward, progress: 0.60),
            isPlaying: true
        )
        let firstHoldState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: firstHoldTime,
            isPlaying: true
        )
        let secondForwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(secondForward, progress: 0.60),
            isPlaying: true
        )
        let secondBackwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(secondBackward, progress: 0.60),
            isPlaying: true
        )
        let laterForwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(laterForward, progress: 0.60),
            isPlaying: true
        )
        let laterBackwardState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: strokeTime(laterBackward, progress: 0.60),
            isPlaying: true
        )
        let pausedState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: firstForward.startTime + (firstForward.duration / 2),
            isPlaying: false
        )

        XCTAssertGreaterThan(firstForwardState.recordPosition, 0.2)
        XCTAssertLessThan(firstBackwardState.recordPosition, firstForwardState.recordPosition)
        XCTAssertEqual(firstHoldState.recordPosition, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(secondForwardState.recordPosition, 0.2)
        XCTAssertLessThan(secondBackwardState.recordPosition, secondForwardState.recordPosition)
        XCTAssertGreaterThan(laterForwardState.recordPosition, 0.2)
        XCTAssertLessThan(laterBackwardState.recordPosition, laterForwardState.recordPosition)
        XCTAssertEqual(pausedState, .babyScratchOpen)
        XCTAssertEqual(
            firstForwardState.crossfaderPosition,
            ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            secondBackwardState.crossfaderPosition,
            ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition,
            accuracy: 0.0001
        )
        XCTAssertTrue(firstForwardState.crossfaderOpenState)
        XCTAssertTrue(secondBackwardState.crossfaderOpenState)
    }

    func testLowerCoachRigBabyScratchPoseIsRepeatableForSameTimestamp() {
        let activeBurst = Array(repeating: Float(0.35), count: 12_000)
        let silence = Array(repeating: Float(0), count: 12_000)
        let samples = activeBurst + silence + activeBurst + silence
        let sampleBuffer = ScratchLabDemoAudioSampleBuffer(samples: samples, sampleRate: 48_000)

        let firstState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: 0.04,
            isPlaying: true
        )
        let secondState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: 0.04,
            isPlaying: true
        )

        XCTAssertEqual(firstState, secondState)
    }

    func testLowerCoachRigUsesNotationTimeWithoutDemoStartDoubleOffset() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let sampleBuffer = try ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        let firstStrokeMidpoint: TimeInterval = 0.524
        let secondAudioCycleFirstStroke = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration
            + BabyScratchReferenceMotionTimeline.phraseStart
        let activeState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: firstStrokeMidpoint,
            isPlaying: true
        )
        let secondCycleState = sampleBuffer.coachRigAnimationState(
            scratchType: "baby",
            playbackTime: secondAudioCycleFirstStroke + 0.10,
            isPlaying: true
        )

        XCTAssertGreaterThan(activeState.recordPosition, 0.2)
        XCTAssertGreaterThan(secondCycleState.recordPosition, 0.1)
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.timelineTime(forPlaybackTime: 1.46), 1.46, accuracy: 0.0001)
        XCTAssertEqual(
            BabyScratchReferenceMotionTimeline.timelineTime(
                forSourceTime: BabyScratchReferenceMotionTimeline.demoStart + 1.46
            ),
            1.46,
            accuracy: 0.0001
        )
        XCTAssertEqual(BabyScratchReferenceMotionTimeline.sourceTime(forPlaybackTime: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(
            BabyScratchReferenceMotionTimeline.sourceTime(
                forPlaybackTime: BabyScratchReferenceMotionTimeline.sourceDuration + 1
            ),
            BabyScratchReferenceMotionTimeline.demoEnd,
            accuracy: 0.0001
        )
    }

    func testBundledDemoAudioDrivesNeutralAndMovingCoachFrames() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let sampleBuffer = try ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        var foundNeutral = false
        var foundMoving = false
        var playbackTime: TimeInterval = 0
        while playbackTime < sampleBuffer.duration {
            let frame = analyzer.processFrame(playbackTime: playbackTime, windowDuration: 1.0 / 30.0)
            foundNeutral = foundNeutral || frame.animationState == .neutral
            foundMoving = foundMoving || abs(frame.animationState.recordPosition) > 0.08
            if foundNeutral && foundMoving {
                break
            }
            playbackTime += 0.05
        }

        XCTAssertTrue(foundNeutral)
        XCTAssertTrue(foundMoving)
    }

    func testBundledDemoAudioHasSubstantialNeutralHoldWindows() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let sampleBuffer = try ScratchLabDemoAudioSampleBuffer(audioURL: audioURL)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        var neutralFrames = 0
        var movingFrames = 0
        var longestNeutralRun = 0
        var currentNeutralRun = 0
        var playbackTime: TimeInterval = 0
        var totalFrames = 0

        while playbackTime < sampleBuffer.duration {
            let frame = analyzer.processFrame(playbackTime: playbackTime, windowDuration: 1.0 / 30.0)
            totalFrames += 1
            if frame.animationState == .neutral {
                neutralFrames += 1
                currentNeutralRun += 1
                longestNeutralRun = max(longestNeutralRun, currentNeutralRun)
            } else {
                movingFrames += 1
                currentNeutralRun = 0
            }
            playbackTime += 0.05
        }

        XCTAssertGreaterThan(totalFrames, 0)
        XCTAssertGreaterThan(movingFrames, 0)
        XCTAssertGreaterThanOrEqual(Double(neutralFrames) / Double(totalFrames), 0.40)
        XCTAssertGreaterThanOrEqual(longestNeutralRun, 4)
    }

    func testDemoModeMotionPatternDoesNotUseRandomValues() throws {
        let coreURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)
        let demoStart = try XCTUnwrap(coreSource.range(of: "struct BabyScratchReferenceMotionTimeline"))
        let demoEnd = try XCTUnwrap(coreSource.range(of: "struct ScratchLabDemoSessionBuilder"))
        let demoSource = String(coreSource[demoStart.lowerBound..<demoEnd.lowerBound])

        let forbiddenTokens = [
            ".random",
            "randomElement",
            "arc4random",
            "GKRandom",
            "UUID()"
        ]

        for forbiddenToken in forbiddenTokens {
            XCTAssertFalse(
                demoSource.contains(forbiddenToken),
                "Demo Mode motion source must not use \(forbiddenToken)."
            )
        }
    }

    func testDemoModeProducesRepeatableMotionFramesForSameTimestamp() {
        let samples = Array(repeating: Float(0.35), count: 48_000 * 2)
        let sampleBuffer = ScratchLabDemoAudioSampleBuffer(samples: samples, sampleRate: 48_000)
        let analyzer = ScratchLabDemoModeAnalyzer(sampleBuffer: sampleBuffer)

        let firstFrame = analyzer.processFrame(playbackTime: 0.44, windowDuration: 1.0 / 30.0)
        let secondFrame = analyzer.processFrame(playbackTime: 0.44, windowDuration: 1.0 / 30.0)

        XCTAssertEqual(firstFrame, secondFrame)
        XCTAssertEqual(firstFrame.animationState, secondFrame.animationState)
        XCTAssertEqual(firstFrame.direction, .backward)
        XCTAssertEqual(firstFrame.feedback?.balance, .balanced)
        XCTAssertEqual(firstFrame.feedback?.timingErrorMilliseconds, 0)
    }

    func testDemoModeExportSucceeds() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let root = try makeTemporaryDirectory()
        let builder = ScratchLabDemoSessionBuilder(audioURLProvider: { audioName in
            audioName == ScratchLabDemoSessionBuilder.demoAudioFileName ? audioURL : nil
        })
        let package = try builder.makePackage(
            rootDirectory: root.appendingPathComponent("demo-package", isDirectory: true),
            sessionID: "demo-mode-test-session",
            now: Date(timeIntervalSince1970: 1_720_010_000)
        )

        XCTAssertEqual(package.metadata.workflow, "demo_mode")
        XCTAssertEqual(package.metadata.sessionName, "ScratchLab Demo")
        XCTAssertEqual(package.metadata.scratchTypeID, CaptureSessionScratchType.babyScratch.rawValue)
        XCTAssertEqual(package.metadata.takeCount, 1)
        XCTAssertEqual(package.takes.count, 1)
        XCTAssertEqual(package.takes.first?.audioPresent, true)
        XCTAssertEqual(package.takes.first?.motionPresent, false)
        XCTAssertNil(package.takes.first?.watchCaptureSession)
        let demoTake = try XCTUnwrap(package.takes.first)
        let demoAudioPath = try XCTUnwrap(demoTake.audioArtifactURL?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: demoTake.mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: demoAudioPath))

        let archiveDirectory = root.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let result = try SessionArchiveBuilder().createArchive(
            from: package,
            options: SessionExportOptions(mixMode: .scratchOnly),
            in: archiveDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))

        let archiveRoot = try unzipArchive(
            result.archiveURL,
            to: root.appendingPathComponent("demo-unzipped", isDirectory: true)
        )
        let metadata = try decodeSessionMetadataDocument(from: archiveRoot)
        let exportMetadata = try decodeExportMetadataDocument(from: archiveRoot)

        XCTAssertEqual(metadata.session.workflow, "demo_mode")
        XCTAssertEqual(metadata.session.scratchTypeID, CaptureSessionScratchType.babyScratch.rawValue)
        XCTAssertEqual(metadata.session.takeCount, 1)
        XCTAssertEqual(metadata.takes.first?.captureMode, CaptureSessionCaptureMode.calibrationNoClick.rawValue)
        XCTAssertEqual(exportMetadata.exportMixMode, ExportMixMode.scratchOnly.rawValue)
        XCTAssertEqual(exportMetadata.takes.first?.exportMixMode, ExportMixMode.scratchOnly.rawValue)
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

        XCTAssertTrue(source.contains("babyScratchDemo.configureBabyScratchIfNeeded()"))
        XCTAssertTrue(source.contains("babyScratchDemo.stop()"))
        XCTAssertTrue(source.contains("\"Demo audio unavailable for this scratch.\""))
        XCTAssertTrue(source.contains("ScratchCoachCardContent("))
        XCTAssertTrue(source.contains("babyScratchDemo.currentAudioTime"))
        XCTAssertTrue(source.contains("animationStateProvider:"))
        XCTAssertTrue(source.contains("BabyScratchDemoPlaybackCoordinator.coachPose(for: audioTime)"))
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
        XCTAssertTrue(source.contains("BabyScratchDemoPlaybackCoordinator.coachPose(for: playbackTime)"))
        XCTAssertTrue(source.contains("BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)"))
        XCTAssertTrue(source.contains("demoMotionSampleBuffer?.coachRigAnimationState("))
        XCTAssertTrue(source.contains(".task(id: demoMotionProfileTaskID)"))
        XCTAssertTrue(source.contains("@State private var showsDetails = false"))
        XCTAssertTrue(source.contains("Dis" + "closureGroup(isExpanded: $showsDetails)"))
        XCTAssertTrue(source.contains("instruction.coachScript"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"scratchlab-coach-rig\")"))
        XCTAssertFalse(source.contains("struct ScratchCoachCharacterView: View"))
    }

    func testLowerScratchCoachRigUsesSharedAudioSyncedComponent() throws {
        let sharedURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let practiceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let mainMenuURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let sharedSource = try String(contentsOf: sharedURL, encoding: .utf8)
        let practiceSource = try String(contentsOf: practiceURL, encoding: .utf8)
        let macSource = try String(contentsOf: macURL, encoding: .utf8)
        let mainMenuSource = try String(contentsOf: mainMenuURL, encoding: .utf8)

        XCTAssertEqual(sharedSource.components(separatedBy: "struct ScratchCoachRigView: View").count - 1, 1)
        XCTAssertTrue(sharedSource.contains("private func resolvedAnimationState("))
        XCTAssertTrue(sharedSource.contains("ScratchCoachDemoAudioPlayer.bundledDemoAudioURL(named: audioFileName, in: .main)"))
        XCTAssertTrue(sharedSource.contains("BabyScratchDemoPlaybackCoordinator.coachPose(for: playbackTime)"))
        XCTAssertTrue(sharedSource.contains("BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)"))
        XCTAssertTrue(sharedSource.contains("private static let babyScratchCrossfaderPosition"))
        XCTAssertTrue(sharedSource.contains("private static let babyScratchLeftHandPose"))
        XCTAssertTrue(sharedSource.contains("private static let recordHandBasePose"))
        XCTAssertTrue(sharedSource.contains("private static let recordStickerBasePose"))
        XCTAssertTrue(sharedSource.contains("ScratchCoachRigGeometry.recordHandUnitPoint(progress: 0)"))
        XCTAssertTrue(sharedSource.contains("ScratchCoachRigGeometry.recordStickerUnitPoint(progress: 0)"))
        XCTAssertFalse(sharedSource.contains(".animation("))
        XCTAssertFalse(sharedSource.contains("withAnimation("))
        XCTAssertTrue(practiceSource.contains("ScratchCoachCardContent("))
        XCTAssertTrue(practiceSource.contains("playbackTimeProvider: { demoPlayer.currentPlaybackTime }"))
        XCTAssertTrue(macSource.contains("ScratchCoachCardContent("))
        XCTAssertTrue(macSource.contains("playbackTimeProvider: { babyScratchDemo.currentAudioTime }"))
        XCTAssertTrue(macSource.contains("animationStateProvider:"))
        XCTAssertTrue(macSource.contains("BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)"))
        XCTAssertTrue(mainMenuSource.contains("ScratchCoachCardContent("))
        XCTAssertTrue(mainMenuSource.contains("animationStateProvider:"))
        XCTAssertFalse(practiceSource.contains("struct ScratchCoachRigView"))
        XCTAssertFalse(macSource.contains("struct ScratchCoachRigView"))
        XCTAssertFalse(mainMenuSource.contains("struct ScratchCoachRigView"))
    }

    func testScratchCoachRigDoesNotRenderToneArm() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let platterStart = try XCTUnwrap(source.range(of: "private func platter("))
        let platterEnd = try XCTUnwrap(source.range(of: "private func recordStickerLineMarker("))
        let platterSource = String(source[platterStart.lowerBound..<platterEnd.lowerBound])

        XCTAssertFalse(source.contains("ScratchCoachToneArmPose"))
        XCTAssertFalse(source.contains("toneArm(center: platterCenter, radius: platterRadius)"))
        XCTAssertFalse(source.contains("private func toneArm("))
        XCTAssertFalse(source.contains("battleSafeToneArm"))
        XCTAssertFalse(source.contains("toneArmPose"))
        XCTAssertTrue(platterSource.contains(".rotationEffect(.degrees(animationState.recordRotationDegrees))"))
        XCTAssertTrue(platterSource.contains("Self.recordStickerBasePose"))
        XCTAssertTrue(platterSource.contains("recordMarkerOffset("))
    }

    func testScratchCoachRigCrossfaderRendersBelowVolumeFaders() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mixerStart = try XCTUnwrap(source.range(of: "private func mixer("))
        let mixerEnd = try XCTUnwrap(source.range(of: "private var knob: some View"))
        let mixerSource = String(source[mixerStart.lowerBound..<mixerEnd.lowerBound])

        XCTAssertTrue(source.contains("private static let volumeFaderYRatio: CGFloat = 0.46"))
        XCTAssertTrue(source.contains("private static let crossfaderYRatio: CGFloat = 0.80"))
        XCTAssertTrue(mixerSource.contains("let volumeFaderY = rect.height * Self.volumeFaderYRatio"))
        XCTAssertTrue(mixerSource.contains("let crossfaderY = rect.height * Self.crossfaderYRatio"))
        XCTAssertTrue(mixerSource.contains("channelVolumeFader(active: true, height: volumeFaderHeight)"))
        XCTAssertTrue(mixerSource.contains(".position(x: rect.width * 0.5, y: volumeFaderY)"))
        XCTAssertTrue(mixerSource.contains(".position(x: rect.width * 0.5, y: crossfaderY)"))
        XCTAssertLessThan(
            try XCTUnwrap(mixerSource.range(of: "volumeFaderY")).lowerBound,
            try XCTUnwrap(mixerSource.range(of: "crossfaderY")).lowerBound
        )
    }

    func testScratchCoachRigBabyScratchUsesFixedLeftHandAndCenteredFader() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let faderStart = try XCTUnwrap(source.range(of: "private func faderHandPoint("))
        let faderEnd = try XCTUnwrap(source.range(of: "private func boothShadow("))
        let faderSource = String(source[faderStart.lowerBound..<faderEnd.lowerBound])

        XCTAssertTrue(source.contains("private static let babyScratchCrossfaderPosition = ScratchCoachDemoAnimationState.babyScratchCrossfaderPosition"))
        XCTAssertTrue(source.contains("private static let babyScratchLeftHandPose = CGPoint(x: 0.50, y: 0.66)"))
        XCTAssertTrue(faderSource.contains("guard isBabyScratch else"))
        XCTAssertTrue(faderSource.contains("Self.babyScratchLeftHandPose.x"))
        XCTAssertTrue(faderSource.contains("Self.babyScratchLeftHandPose.y"))
        XCTAssertTrue(source.contains("return isBabyScratch ? .babyScratchOpen : .neutral"))
        XCTAssertTrue(source.contains("?? (isBabyScratch ? .babyScratchOpen : .neutral)"))
    }

    func testScratchCoachRigRecordHandAndStickerUseBabyScratchClockPositions() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let recordHandStart = try XCTUnwrap(source.range(of: "private func recordHandPoint("))
        let recordHandEnd = try XCTUnwrap(source.range(of: "private func faderHandPoint("))
        let platterStart = try XCTUnwrap(source.range(of: "private func platter("))
        let platterEnd = try XCTUnwrap(source.range(of: "private func recordStickerLineMarker("))
        let recordHandSource = String(source[recordHandStart.lowerBound..<recordHandEnd.lowerBound])
        let platterSource = String(source[platterStart.lowerBound..<platterEnd.lowerBound])
        let stickerLineStart = try XCTUnwrap(source.range(of: "private func recordStickerLineMarker("))
        let stickerLineEnd = try XCTUnwrap(source.range(of: "private func recordMarkerOffset("))
        let stickerLineSource = String(source[stickerLineStart.lowerBound..<stickerLineEnd.lowerBound])

        XCTAssertTrue(source.contains("Clock positions are authored in coach/deck space and converted to front-facing viewer space using 180° rotation."))
        XCTAssertTrue(source.contains("clockPerspectiveRotationHours: Double = 6"))
        XCTAssertTrue(source.contains("babyScratchHandStartCoachHour: Double = 9"))
        XCTAssertTrue(source.contains("babyScratchHandEndCoachHour: Double = 11"))
        XCTAssertTrue(source.contains("babyScratchStickerStartCoachHour: Double = 12"))
        XCTAssertTrue(source.contains("babyScratchStickerEndCoachHour: Double = 2"))
        XCTAssertTrue(source.contains("static func frontFacingViewerHour(coachHour: Double) -> Double"))
        XCTAssertTrue(source.contains("static func viewerAngleDegrees(coachHour: Double) -> Double"))
        XCTAssertTrue(source.contains("recordHandRadiusMultiplier: CGFloat = 0.92"))
        XCTAssertTrue(source.contains("recordStickerRadiusMultiplier: CGFloat = 0.72"))
        XCTAssertTrue(source.contains("private static let recordHandBasePose = ScratchCoachRigGeometry.recordHandUnitPoint(progress: 0)"))
        XCTAssertTrue(source.contains("private static let recordStickerBasePose = ScratchCoachRigGeometry.recordStickerUnitPoint(progress: 0)"))
        XCTAssertTrue(recordHandSource.contains("ScratchCoachRigGeometry.recordHandPoint("))
        XCTAssertTrue(recordHandSource.contains("x: center.x + radius * Self.recordHandBasePose.x"))
        XCTAssertTrue(recordHandSource.contains("+ CGFloat(animationState.recordPosition) * 24"))
        XCTAssertTrue(platterSource.contains("recordStickerLineMarker(radius: radius)"))
        XCTAssertTrue(platterSource.contains("Self.recordStickerBasePose.x"))
        XCTAssertTrue(platterSource.contains("Self.recordStickerBasePose.y"))
        XCTAssertTrue(platterSource.contains(".rotationEffect(.degrees(animationState.recordRotationDegrees))"))
        XCTAssertTrue(stickerLineSource.contains("Capsule()"))
        XCTAssertTrue(stickerLineSource.contains(".frame(width: 5, height: max(14, radius * 0.46))"))
        XCTAssertFalse(stickerLineSource.contains("Circle()"))
        XCTAssertFalse(platterSource.contains("Self.toneArmPose"))
    }

    func testScratchCoachRigGeometryMapsBabyHandAndStickerAngles() {
        XCTAssertEqual(ScratchCoachRigGeometry.frontFacingViewerHour(coachHour: 9), 3, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.frontFacingViewerHour(coachHour: 11), 5, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.frontFacingViewerHour(coachHour: 12), 6, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.frontFacingViewerHour(coachHour: 2), 8, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.viewerAngleDegrees(coachHour: 9), 0, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.viewerAngleDegrees(coachHour: 11), 60, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.viewerAngleDegrees(coachHour: 12), 90, accuracy: 0.0001)
        XCTAssertEqual(ScratchCoachRigGeometry.viewerAngleDegrees(coachHour: 2), 150, accuracy: 0.0001)

        let handStart = ScratchCoachRigGeometry.recordHandUnitPoint(progress: 0)
        let handEnd = ScratchCoachRigGeometry.recordHandUnitPoint(progress: 1)
        let stickerStart = ScratchCoachRigGeometry.recordStickerUnitPoint(progress: 0)
        let stickerEnd = ScratchCoachRigGeometry.recordStickerUnitPoint(progress: 1)
        let stickerRotation = ScratchCoachRigGeometry.recordStickerRotationDegrees(progress: 1)
        let leftDeckCenter = CGPoint(x: 80, y: 120)
        let rightDeckCenter = CGPoint(x: 240, y: 120)
        let leftStart = ScratchCoachRigGeometry.recordHandPoint(
            center: leftDeckCenter,
            radius: 40,
            progress: 0
        )
        let rightStart = ScratchCoachRigGeometry.recordHandPoint(
            center: rightDeckCenter,
            radius: 40,
            progress: 0
        )
        let leftEnd = ScratchCoachRigGeometry.recordHandPoint(
            center: leftDeckCenter,
            radius: 40,
            progress: 1
        )
        let rightEnd = ScratchCoachRigGeometry.recordHandPoint(
            center: rightDeckCenter,
            radius: 40,
            progress: 1
        )

        XCTAssertEqual(handStart.x, 0.92, accuracy: 0.01)
        XCTAssertEqual(handStart.y, 0, accuracy: 0.01)
        XCTAssertEqual(handEnd.x, 0.46, accuracy: 0.02)
        XCTAssertEqual(handEnd.y, 0.80, accuracy: 0.02)
        XCTAssertEqual(stickerStart.x, 0, accuracy: 0.01)
        XCTAssertEqual(stickerStart.y, 0.72, accuracy: 0.01)
        XCTAssertEqual(stickerEnd.x, -0.62, accuracy: 0.02)
        XCTAssertEqual(stickerEnd.y, 0.36, accuracy: 0.02)
        XCTAssertEqual(stickerRotation, 60, accuracy: 0.0001)
        XCTAssertEqual(leftStart.x - leftDeckCenter.x, rightStart.x - rightDeckCenter.x, accuracy: 0.0001)
        XCTAssertEqual(leftStart.y - leftDeckCenter.y, rightStart.y - rightDeckCenter.y, accuracy: 0.0001)
        XCTAssertEqual(leftEnd.x - leftDeckCenter.x, rightEnd.x - rightDeckCenter.x, accuracy: 0.0001)
        XCTAssertEqual(leftEnd.y - leftDeckCenter.y, rightEnd.y - rightDeckCenter.y, accuracy: 0.0001)
        XCTAssertLessThan(leftEnd.x, leftStart.x)
        XCTAssertGreaterThan(leftEnd.y, leftStart.y)
    }

    func testScratchCoachRigSourceHasNoRandomOrFreeRunningMotionCursor() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rigStart = try XCTUnwrap(source.range(of: "struct ScratchCoachRigView: View"))
        let rigEnd = try XCTUnwrap(source.range(of: "struct ScratchCoachCardContent<Controls: View>: View"))
        let rigSource = String(source[rigStart.lowerBound..<rigEnd.lowerBound])

        XCTAssertFalse(rigSource.contains(".random"))
        XCTAssertFalse(rigSource.contains("randomElement"))
        XCTAssertFalse(rigSource.contains("UUID("))
        XCTAssertFalse(rigSource.contains("cursorTime +="))
        XCTAssertFalse(rigSource.contains("let playbackTime = isPlaying ? playbackTimeProvider() : 0"))
        XCTAssertTrue(rigSource.contains("playbackTime: playbackTimeProvider()"))
        XCTAssertTrue(rigSource.contains("demoMotionSampleBuffer?.coachRigAnimationState("))
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

    func testReviewDecisionPersistsWithoutChangingRawTakeIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let files = CaptureCore.LocalRecordingFiles(
            baseName: "routine-session_take001_routine",
            mediaURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.mov"),
            sidecarURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.json")
        )
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: "routine-session",
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: "routine-session", takeNumber: 1),
            files: files,
            recordingRole: "routine_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: now
        )
        let reviewed = sidecar.reviewed(
            status: .corrected,
            label: "chirp",
            detectedLabel: "Baby Scratch",
            confidence: 42,
            reviewedAt: now.addingTimeInterval(5)
        )

        let decoded = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: try reviewed.encodedData()
        )

        XCTAssertEqual(decoded.mediaFileName, sidecar.mediaFileName)
        XCTAssertEqual(decoded.sidecarFileName, sidecar.sidecarFileName)
        XCTAssertEqual(decoded.takeID, sidecar.takeID)
        XCTAssertEqual(decoded.reviewDecision?.status, .corrected)
        XCTAssertEqual(decoded.reviewDecision?.label, "chirp")
        XCTAssertEqual(decoded.reviewDecision?.detectedLabel, "Baby Scratch")
        XCTAssertEqual(decoded.reviewDecision?.confidence, 42)
        XCTAssertEqual(decoded.auditTrail.last?.category, "label_reviewed")
    }

    func testLocalRecordingSidecarPersistsDetectedNotationSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let files = CaptureCore.LocalRecordingFiles(
            baseName: "routine-session_take001_routine",
            mediaURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.mov"),
            sidecarURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.json")
        )
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: "routine-session",
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: "routine-session", takeNumber: 1),
            files: files,
            recordingRole: "routine_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: now
        )
        let notation = makeDetectedNotationSnapshot()
        let finalized = sidecar
            .finalized(
                endedAt: now.addingTimeInterval(2),
                mediaFileName: files.mediaURL.lastPathComponent,
                captureErrorDescription: nil
            )
            .withDetectedNotation(notation, recordedAt: now.addingTimeInterval(2))

        let decoded = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: try finalized.encodedData()
        )

        XCTAssertEqual(decoded.detectedNotation?.notationSource, "detected")
        XCTAssertEqual(decoded.detectedNotation?.detectionSources, ["audio", "video"])
        XCTAssertEqual(decoded.detectedNotation?.recordMovementEvents.count, 2)
        XCTAssertEqual(decoded.detectedNotation?.audioEvents.count, 2)
        XCTAssertEqual(decoded.detectedNotation?.recordMovementEvents.first?.direction, "forward")
        XCTAssertEqual(decoded.auditTrail.last?.category, "notation_snapshot")
    }

    func testExportedDetectedNotationUsesSavedSnapshot() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)
        sidecar = sidecar.withDetectedNotation(makeDetectedNotationSnapshot())
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let decoder = JSONDecoder()
        let notationDocument = try decoder.decode(SessionExportNotationDocument.self, from: data)

        XCTAssertEqual(notationDocument.notationSource, .detected)
        XCTAssertEqual(notationDocument.detectionSources, ["audio", "video"])
        XCTAssertEqual(notationDocument.labelSource, .detected)
        XCTAssertEqual(notationDocument.labelConfidence, 57)
        XCTAssertEqual(try XCTUnwrap(notationDocument.notationConfidence), 0.79, accuracy: 0.001)
        XCTAssertEqual(notationDocument.recordMovementEvents.count, 2)
        XCTAssertEqual(notationDocument.audioEvents.count, 2)
        XCTAssertEqual(notationDocument.recordMovementEvents.first?.direction, "forward")
        XCTAssertEqual(notationDocument.recordMovementEvents.first?.movementKind, "normalPush")
    }

    func testExportedUnavailableNotationClearsNotationConfidence() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root)
        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let decoder = JSONDecoder()
        let notationDocument = try decoder.decode(SessionExportNotationDocument.self, from: data)

        XCTAssertEqual(notationDocument.notationSource, .unavailable)
        XCTAssertTrue(notationDocument.recordMovementEvents.isEmpty)
        XCTAssertTrue(notationDocument.audioEvents.isEmpty)
        XCTAssertNil(notationDocument.notationConfidence)
        XCTAssertEqual(notationDocument.notes, "No notation events detected")
    }

    func testExportedPartialNotationUsesAudioEventsWithoutMovement() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)
        sidecar = sidecar.withDetectedNotation(makeAudioOnlyDetectedNotationSnapshot())
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let notationDocument = try JSONDecoder().decode(SessionExportNotationDocument.self, from: data)

        XCTAssertEqual(notationDocument.notationSource, .partial)
        XCTAssertEqual(notationDocument.detectionSources, ["audio"])
        XCTAssertTrue(notationDocument.recordMovementEvents.isEmpty)
        XCTAssertEqual(notationDocument.audioEvents.count, 2)
        XCTAssertEqual(try XCTUnwrap(notationDocument.notationConfidence), 0.63, accuracy: 0.001)
        XCTAssertEqual(notationDocument.notes, "Detected audio notation without confirmed movement direction")
    }

    func testNotationNormalizerDropsNearZeroMovementNoise() {
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()
        let noisyEvent = makeMovementEvent(
            startTime: 0.10,
            endTime: 0.42,
            startPosition: 0.501,
            endPosition: 0.502,
            direction: "forward",
            confidence: 0.72
        )

        let normalized = normalizer.normalize(events: [noisyEvent], audioEvents: [])

        XCTAssertTrue(normalized.isEmpty)
    }

    func testNotationNormalizerMergesAdjacentSameDirectionSegments() {
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()
        let first = makeMovementEvent(
            startTime: 0.10,
            endTime: 0.20,
            startPosition: 0.05,
            endPosition: 0.28,
            direction: "forward",
            confidence: 0.70
        )
        let second = makeMovementEvent(
            startTime: 0.24,
            endTime: 0.36,
            startPosition: 0.28,
            endPosition: 0.72,
            direction: "forward",
            confidence: 0.82
        )

        let normalized = normalizer.normalize(events: [first, second], audioEvents: [])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.direction, "forward")
        XCTAssertEqual(try XCTUnwrap(normalized.first?.startTime), 0.10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(normalized.first?.endTime), 0.36, accuracy: 0.001)
    }

    func testNotationNormalizerClassifiesForwardAndBackwardStrokeSpeeds() {
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()

        XCTAssertEqual(
            normalizer.classifyMovementKind(direction: "forward", duration: 0.09, delta: 0.48, speed: 5.33),
            .fastPush
        )
        XCTAssertEqual(
            normalizer.classifyMovementKind(direction: "forward", duration: 0.20, delta: 0.34, speed: 1.7),
            .normalPush
        )
        XCTAssertEqual(
            normalizer.classifyMovementKind(direction: "backward", duration: 0.42, delta: 0.20, speed: 0.48),
            .slowPullDrag
        )
        XCTAssertEqual(
            normalizer.classifyMovementKind(direction: "backward", duration: 0.10, delta: 0.40, speed: 4.0),
            .fastPull
        )
    }

    func testRoutineDetectedNotationBuilderEmitsMultipleAlternatingMovementEventsForBabyScratchPhrase() {
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 100)
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()

        let observations: [(TimeInterval, MacCaptureEngine.HandMotionState, Double)] = [
            (100.00, .steady, 0.50),
            (100.05, .movingRight, 0.56),
            (100.10, .movingRight, 0.68),
            (100.16, .movingRight, 0.84),
            (100.20, .movingLeft, 0.78),
            (100.26, .movingLeft, 0.60),
            (100.32, .movingLeft, 0.32),
            (100.38, .movingRight, 0.46),
            (100.44, .movingRight, 0.70),
            (100.50, .movingRight, 0.88),
            (100.56, .movingLeft, 0.74),
            (100.62, .movingLeft, 0.52),
            (100.70, .movingLeft, 0.20)
        ]

        for (time, state, x) in observations {
            builder.recordObservation(
                state: state,
                position: CGPoint(x: x, y: 0.5),
                confidence: 0.92,
                now: time
            )
        }

        let rawEvents = builder.movementEvents(now: 100.72)
        let normalized = normalizer.normalize(events: rawEvents, audioEvents: [])

        XCTAssertEqual(rawEvents.count, 4)
        XCTAssertEqual(rawEvents.map(\.direction), ["forward", "backward", "forward", "backward"])
        XCTAssertEqual(normalized.count, 4)
        XCTAssertEqual(normalized.map(\.direction), ["forward", "backward", "forward", "backward"])
    }

    func testRoutineDetectedNotationBuilderSplitsDirectionChangesInsteadOfMergingStrokes() {
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 200)

        let observations: [(TimeInterval, MacCaptureEngine.HandMotionState, Double)] = [
            (200.00, .movingRight, 0.24),
            (200.07, .movingRight, 0.48),
            (200.13, .movingRight, 0.78),
            (200.18, .movingLeft, 0.72),
            (200.24, .movingLeft, 0.51),
            (200.31, .movingLeft, 0.18)
        ]

        for (time, state, x) in observations {
            builder.recordObservation(
                state: state,
                position: CGPoint(x: x, y: 0.5),
                confidence: 0.88,
                now: time
            )
        }

        let events = builder.movementEvents(now: 200.33)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].direction, "forward")
        XCTAssertEqual(events[1].direction, "backward")
        XCTAssertLessThan(events[0].endTime, events[1].startTime)
        XCTAssertGreaterThan(abs(events[0].endPosition - events[0].startPosition), 0.40)
        XCTAssertGreaterThan(abs(events[1].endPosition - events[1].startPosition), 0.40)
    }

    func testRoutineDetectedNotationBuilderKeepsNormalBabyScratchRepetitionsAboveSuppressionThresholds() {
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 300)
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()

        let observations: [(TimeInterval, MacCaptureEngine.HandMotionState, Double)] = [
            (300.00, .movingRight, 0.40),
            (300.06, .movingRight, 0.52),
            (300.12, .movingRight, 0.64),
            (300.18, .movingLeft, 0.58),
            (300.24, .movingLeft, 0.46),
            (300.30, .movingLeft, 0.34),
            (300.36, .movingRight, 0.42),
            (300.42, .movingRight, 0.54),
            (300.48, .movingRight, 0.66),
            (300.54, .movingLeft, 0.58),
            (300.60, .movingLeft, 0.46),
            (300.66, .movingLeft, 0.34)
        ]

        for (time, state, x) in observations {
            builder.recordObservation(
                state: state,
                position: CGPoint(x: x, y: 0.5),
                confidence: 0.84,
                now: time
            )
        }

        let normalized = normalizer.normalize(events: builder.movementEvents(now: 300.68), audioEvents: [])

        XCTAssertEqual(normalized.count, 4)
        XCTAssertTrue(normalized.allSatisfy { $0.movementKind == .normalPush || $0.movementKind == .normalPull })
    }

    func testRoutineDetectedNotationBuilderRejectsTinyJitterWithoutCreatingMovementEvents() {
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(startedAt: 400)
        let normalizer = MacCaptureEngine.RoutineNotationEventNormalizer()

        let observations: [(TimeInterval, MacCaptureEngine.HandMotionState, Double)] = [
            (400.00, .movingRight, 0.500),
            (400.05, .movingRight, 0.507),
            (400.10, .movingLeft, 0.503),
            (400.15, .movingLeft, 0.496),
            (400.20, .movingRight, 0.502),
            (400.25, .movingRight, 0.509)
        ]

        for (time, state, x) in observations {
            builder.recordObservation(
                state: state,
                position: CGPoint(x: x, y: 0.5),
                confidence: 0.80,
                now: time
            )
        }

        let normalized = normalizer.normalize(events: builder.movementEvents(now: 400.27), audioEvents: [])

        XCTAssertTrue(normalized.isEmpty)
    }

    func testNotationFusionFallsBackToPartialWhenMotionIsOnlyJitter() {
        let fusion = MacCaptureEngine.RoutineNotationFusionEngine()
        let audioSnapshot = ScratchAudioNotationSnapshot(
            audioEvents: [
                makeAudioNotationEventCandidate(
                    startTime: 0.12,
                    endTime: 0.24,
                    peakLevel: 0.35,
                    rmsLevel: 0.16,
                    confidence: 0.68,
                    eventKind: .scratchBurst
                )
            ],
            confidence: 0.68
        )
        let jitterMotion = [
            makeMovementEvent(
                startTime: 0.11,
                endTime: 0.23,
                startPosition: 0.500,
                endPosition: 0.503,
                direction: "forward",
                confidence: 0.81
            )
        ]

        let snapshot = fusion.snapshot(
            audioSnapshot: audioSnapshot,
            motionEvents: jitterMotion,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 0.57
        )

        XCTAssertEqual(snapshot.notationSource, "partial")
        XCTAssertTrue(snapshot.recordMovementEvents.isEmpty)
        XCTAssertEqual(snapshot.audioEvents.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.notationConfidence), 0.68, accuracy: 0.001)
    }

    func testNotationFusionUsesFilteredMovementConfidenceForDetectedNotation() {
        let fusion = MacCaptureEngine.RoutineNotationFusionEngine()
        let audioSnapshot = ScratchAudioNotationSnapshot(
            audioEvents: [
                makeAudioNotationEventCandidate(
                    startTime: 0.10,
                    endTime: 0.22,
                    peakLevel: 0.42,
                    rmsLevel: 0.19,
                    confidence: 0.70,
                    eventKind: .scratchBurst
                )
            ],
            confidence: 0.70
        )
        let motionEvents = [
            makeMovementEvent(
                startTime: 0.09,
                endTime: 0.23,
                startPosition: 0.08,
                endPosition: 0.68,
                direction: "forward",
                confidence: 0.80
            ),
            makeMovementEvent(
                startTime: 0.28,
                endTime: 0.45,
                startPosition: 0.500,
                endPosition: 0.501,
                direction: "backward",
                confidence: 0.75
            )
        ]

        let snapshot = fusion.snapshot(
            audioSnapshot: audioSnapshot,
            motionEvents: motionEvents,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 0.57
        )

        XCTAssertEqual(snapshot.notationSource, "detected")
        XCTAssertEqual(snapshot.recordMovementEvents.count, 1)
        XCTAssertEqual(snapshot.recordMovementEvents.first?.movementKind, .fastPush)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.notationConfidence),
            try XCTUnwrap(snapshot.recordMovementEvents.first?.confidence),
            accuracy: 0.001
        )
    }

    func testNotationFusionDropsLowConfidenceDirectionalMotionWhileRemainingPartial() {
        let fusion = MacCaptureEngine.RoutineNotationFusionEngine()
        let audioSnapshot = ScratchAudioNotationSnapshot(
            audioEvents: [
                makeAudioNotationEventCandidate(
                    startTime: 0.10,
                    endTime: 0.24,
                    peakLevel: 0.39,
                    rmsLevel: 0.17,
                    confidence: 0.66,
                    eventKind: .scratchBurst
                )
            ],
            confidence: 0.66
        )
        let weakMotion = [
            makeMovementEvent(
                startTime: 0.10,
                endTime: 0.24,
                startPosition: 0.14,
                endPosition: 0.30,
                direction: "forward",
                confidence: 0.33
            )
        ]

        let snapshot = fusion.snapshot(
            audioSnapshot: audioSnapshot,
            motionEvents: weakMotion,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 0.57
        )

        XCTAssertEqual(snapshot.notationSource, "partial")
        XCTAssertEqual(snapshot.detectionSources, ["audio", "video"])
        XCTAssertTrue(snapshot.recordMovementEvents.isEmpty)
        XCTAssertEqual(snapshot.audioEvents.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.notationConfidence), 0.66, accuracy: 0.001)
    }

    func testNotationFusionKeepsOffTimingDirectionalMotionTruthfulWhileRemainingPartial() {
        let fusion = MacCaptureEngine.RoutineNotationFusionEngine()
        let audioSnapshot = ScratchAudioNotationSnapshot(
            audioEvents: [
                makeAudioNotationEventCandidate(
                    startTime: 0.12,
                    endTime: 0.24,
                    peakLevel: 0.43,
                    rmsLevel: 0.19,
                    confidence: 0.74,
                    eventKind: .scratchBurst
                )
            ],
            confidence: 0.74
        )
        let offTimingMotion = [
            makeMovementEvent(
                startTime: 0.34,
                endTime: 0.50,
                startPosition: 0.10,
                endPosition: 0.62,
                direction: "forward",
                confidence: 0.91
            )
        ]

        let snapshot = fusion.snapshot(
            audioSnapshot: audioSnapshot,
            motionEvents: offTimingMotion,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 0.57
        )

        XCTAssertEqual(snapshot.notationSource, "partial")
        XCTAssertEqual(snapshot.detectionSources, ["audio", "video"])
        XCTAssertEqual(snapshot.recordMovementEvents.count, 1)
        XCTAssertEqual(snapshot.recordMovementEvents.first?.direction, "forward")
        XCTAssertEqual(snapshot.audioEvents.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.notationConfidence), 0.74, accuracy: 0.001)
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
        XCTAssertEqual(manifest?["session_root"] as? String, "session_2024_03_10_dj_alpha_baby_scratch_70_90_110_bpm")
        XCTAssertFalse(String(data: manifestData, encoding: .utf8)?.contains("/Users/") ?? true)

        let takes = try XCTUnwrap(manifest?["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.count, 3)
        let firstFiles = try XCTUnwrap(takes.first?["files"] as? [String: String])
        XCTAssertEqual(firstFiles["camA"], "video/DJALPHA_baby_070_take01_camA.mov")
        XCTAssertEqual(firstFiles["serato"], "audio/DJALPHA_baby_070_take01_scratch_only.wav")
        XCTAssertEqual(firstFiles["scratch_only"], "audio/DJALPHA_baby_070_take01_scratch_only.wav")
        XCTAssertNil(firstFiles["beat_only"])
        XCTAssertNil(firstFiles["scratch_with_beat"])
        XCTAssertEqual(firstFiles["notation"], "notation/take-001_detected_notation.json")
        let firstStemAvailability = try XCTUnwrap(takes.first?["stem_availability"] as? [String: String])
        XCTAssertEqual(firstStemAvailability["scratch_only"], "available")
        XCTAssertEqual(firstStemAvailability["beat_only"], "unavailable")
        XCTAssertEqual(firstStemAvailability["scratch_with_beat"], "unavailable")
        let firstArtifacts = try XCTUnwrap(takes.first?["artifacts"] as? [String: [String: Any]])
        XCTAssertEqual(firstArtifacts["scratch_only"]?["path"] as? String, "audio/DJALPHA_baby_070_take01_scratch_only.wav")
        XCTAssertEqual(firstArtifacts["serato"]?["path"] as? String, "audio/DJALPHA_baby_070_take01_scratch_only.wav")
        XCTAssertNil(firstArtifacts["beat_only"])
        XCTAssertNil(firstArtifacts["scratch_with_beat"])

        let takeLog = preview.takeLogCSV
        XCTAssertTrue(takeLog.contains("bpm,take_number,raw_camA,raw_camB,raw_audio,raw_watch,verbal_slate_used,sync_clap_used,notes"))
        XCTAssertTrue(takeLog.contains("\"70\",\"1\",\"\",\"\",\"\",\"\",\"true\",\"true\",\"take 1 note\""))
        XCTAssertEqual(
            takeLog.split(whereSeparator: \.isNewline).count - 1,
            takes.count,
            "take_log row count must agree with manifest take count"
        )

        let metadataDocument = try builder.metadataDocument(for: validatedPackage)
        XCTAssertEqual(metadataDocument.takes.first?.notationFile, "notation/take-001_detected_notation.json")
        XCTAssertEqual(metadataDocument.takes.first?.notationSource, "unavailable")
        XCTAssertEqual(metadataDocument.takes.first?.labelSource, "unknown")
        XCTAssertNil(metadataDocument.takes.first?.labelConfidence)
        XCTAssertNil(metadataDocument.takes.first?.notationConfidence)
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
        XCTAssertEqual(manifest["session_root"] as? String, "session_2024_03_10_dj_alpha_stab_90_bpm")
        XCTAssertEqual((manifest["takes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((manifest["takes"] as? [[String: Any]])?.first?["scratch_type"] as? String, "stab")
        let firstTake = try XCTUnwrap((manifest["takes"] as? [[String: Any]])?.first)
        let files = try XCTUnwrap(firstTake["files"] as? [String: String])
        XCTAssertEqual(files["camA"], "video/DJALPHA_stab_090_take01_camA.mov")
        XCTAssertEqual(files["notation"], "notation/take-001_detected_notation.json")
        XCTAssertEqual(files["serato"], "audio/DJALPHA_stab_090_take01_scratch_only.wav")
        XCTAssertEqual(files["scratch_only"], "audio/DJALPHA_stab_090_take01_scratch_only.wav")
        XCTAssertNil(files["beat_only"])
        XCTAssertNil(files["scratch_with_beat"])
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

    func testMacDesktopMainLayoutExposesSimpleCaptureModes() throws {
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("case practice"))
        XCTAssertTrue(source.contains("case capture"))
        XCTAssertTrue(source.contains("case review"))
        XCTAssertTrue(source.contains("case advanced"))
        XCTAssertTrue(source.contains("case .practice: return \"Practice\""))
        XCTAssertTrue(source.contains("case .capture: return \"Capture\""))
        XCTAssertTrue(source.contains("case .review: return \"Review\""))
        XCTAssertTrue(source.contains("case .advanced: return \"Advanced\""))
        XCTAssertTrue(source.contains("advancedWorkspace"))
        XCTAssertTrue(source.contains("static func resolved(from storedValue: String)"))
    }

    func testMacCaptureScreenContainsSimpleDatasetWorkflowLabels() throws {
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macSourceURL, encoding: .utf8)
        let engineSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let engineSource = try String(contentsOf: engineSourceURL, encoding: .utf8)

        for label in [
            "Capture Session",
            "Auto Detect",
            "Baby Scratch",
            "Chirp",
            "Transform",
            "Flare",
            "Unknown",
            "No Beat",
            "Click",
            "Beat",
            "Calibration",
            "Camera Ready",
            "Mixer MIDI",
            "Mixer Optional",
            "Watch Optional",
            "Start Capture",
            "\"Stop\" : \"Record\"",
            "Save Take",
            "Retake",
            "Export Session",
            "Untitled Session",
            "Unknown Performer"
        ] {
            XCTAssertTrue(source.contains(label), "Missing Capture label \(label)")
        }

        for engineLabel in [
            "Audio Ready",
            "Default audio input",
            "Default camera",
            "Not Connected",
            "No signal"
        ] {
            XCTAssertTrue(
                source.contains(engineLabel) || engineSource.contains(engineLabel),
                "Missing Capture label \(engineLabel)"
            )
        }

        let primarySource = try sourceSlice(
            in: source,
            from: "private var practiceSidebar",
            through: "private var reviewSidebar"
        )
        for forbidden in ["debug", "test only", "dev only", "internal only", "fake", "dummy", "CXL Dataset", "QBERT", "DVD", "rip"] {
            XCTAssertFalse(
                primarySource.localizedCaseInsensitiveContains(forbidden),
                "Primary Practice/Capture source exposes \(forbidden)"
            )
        }
    }

    func testReviewPreviewUsesSavedNotationSnapshotNotLiveDetectionCounters() throws {
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("currentRoutineNotationSnapshot?.recordMovementEvents.isEmpty == false"))
        XCTAssertTrue(source.contains("hasPartialReviewNotation"))
        XCTAssertTrue(source.contains("Audio-only take"))
        XCTAssertTrue(source.contains("Hand motion wasn't detected — review timing only."))
        XCTAssertTrue(source.contains("No record movement detected."))
        XCTAssertTrue(source.contains("ScratchNotation.detectedPreview("))
        XCTAssertTrue(source.contains("Notation unavailable for this take."))
        XCTAssertFalse(source.contains("hasRecordedTake && (captureEngine.cxlEventCount > 0 || captureEngine.scratchDetectionCount > 0)"))
    }

    func testAudioNotationDetectorDetectsScratchBurstsAndSilenceGap() {
        let detector = ScratchAudioNotationDetector()
        let sampleRate = 44_100.0
        let burst = repeatingWave(amplitude: 0.34, frequency: 180, sampleRate: sampleRate, duration: 0.12)
        let silence = [Float](repeating: 0, count: Int(sampleRate * 0.08))
        let pull = repeatingWave(amplitude: 0.26, frequency: 140, sampleRate: sampleRate, duration: 0.16)

        detector.process(samples: burst + silence + pull, sampleRate: sampleRate)
        let snapshot = detector.snapshot()

        XCTAssertTrue(snapshot.audioEvents.contains(where: { $0.eventKind == .scratchBurst }))
        XCTAssertTrue(snapshot.audioEvents.contains(where: { $0.eventKind == .silenceGap || $0.eventKind == .possibleCut }))
        XCTAssertNotNil(snapshot.confidence)
    }

    func testAudioNotationDetectorLeavesDirectionUnspecified() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Models/ScratchMotionAnalysis.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("movingRight -> forward"))
        XCTAssertFalse(source.contains("movingLeft -> backward"))
        XCTAssertTrue(source.contains("struct ScratchAudioNotationEventCandidate"))
        XCTAssertTrue(source.contains("let eventKind: ScratchAudioNotationEventKind"))
    }

    func testMacCaptureEngineSourceDocumentsSingleDirectionNormalizationHelper() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("static func normalizedRecordDirection("))
        XCTAssertTrue(source.contains("final class RoutineDetectedNotationBuilder"))
        XCTAssertTrue(source.contains("func recordObservation("))
        XCTAssertTrue(source.contains("self.activeRoutineDetectedNotationBuilder?.recordObservation("))
        XCTAssertTrue(source.contains("return .backward"))
        XCTAssertTrue(source.contains("return .forward"))
        XCTAssertTrue(source.contains("Self.normalizedRecordDirection(forCameraSpaceDirection: direction)"))
    }

    func testMacCaptureEngineSourcePublishesMovementDiagnosticsAndTruthfulCapturedEvents() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let routineRecordingHandPoseInterval: CFTimeInterval = 0.04"))
        XCTAssertTrue(source.contains("@Published private(set) var routineMovementDiagnostics"))
        XCTAssertTrue(source.contains("private func publishRoutineMovementDiagnostics("))
        XCTAssertTrue(source.contains("recordMovementEvents: candidateMovementEvents"))
        XCTAssertTrue(source.contains("debugSession?.recordRawDrop(.durationTooShort)"))
        XCTAssertTrue(source.contains("debugSession?.recordNormalizedDrop(.deltaTooSmall)"))
    }

    func testMacReviewScreenContainsCorrectionAndExportLabels() throws {
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macSourceURL, encoding: .utf8)

        for label in [
            "Detected scratch type",
            "Confidence",
            "Stroke count",
            "Fader event count",
            "Captured Notation",
            "Audio-only take",
            "No record movement detected.",
            "Hand motion wasn't detected — review timing only.",
            "No take ready for review",
            "Record a take in Capture to see detected notation, confidence, and label options.",
            "Accept",
            "Correct Label",
            "Leave Unknown",
            "Export ZIP",
            "baby_scratch",
            "manual_label"
        ] {
            XCTAssertTrue(source.contains(label), "Missing Review label \(label)")
        }

        XCTAssertTrue(source.contains("reviewDecisionByTakeID[reviewTakeID]"))
        XCTAssertTrue(source.contains("persistReviewDecision"))
        XCTAssertTrue(source.contains("sidecar.reviewed"))
        XCTAssertTrue(source.contains("without changing the raw captured media"))
        XCTAssertTrue(source.contains("if hasRecordedTake {"))
        XCTAssertTrue(source.contains("if hasReviewNotationPreview {"))
        XCTAssertFalse(source.contains("title: \"Mini Notation Timeline\""))
    }

    func testMacAdvancedScreenContainsTechnicalToolsOutsidePrimaryNavigation() throws {
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macSourceURL, encoding: .utf8)

        let advancedSource = try sourceSlice(
            in: source,
            from: "private var advancedToolsCard",
            through: "private var routineSessionCard"
        )

        for label in [
            "Notation Lab",
            "Input diagnostics",
            "MIDI device mapping",
            "Deck/mixer calibration",
            "Export manifest info",
            "App Review demo tools",
            "Test Lab",
            "Raw JSON/sidecar inspection",
            "Watch motion diagnostics",
            "Timing checks",
            "Advanced Capture Details"
        ] {
            XCTAssertTrue(advancedSource.contains(label), "Missing Advanced label \(label)")
        }

        let tabSource = try sourceSlice(
            in: source,
            from: "TabView(selection: workspaceTabBinding)",
            through: ".background(Color(nsColor: .windowBackgroundColor))"
        )
        XCTAssertFalse(tabSource.contains("Notation Lab"))
        XCTAssertFalse(tabSource.contains("Test Lab"))
        XCTAssertFalse(tabSource.contains("Advanced Capture Details"))
    }

    @MainActor
    func testRawJSONInspectorOpenWithoutSelectionShowsEmptyState() {
        let viewModel = RawJSONInspectorViewModel(previewByteLimit: 256, previewLineLimit: 12)

        viewModel.openForCurrentSelection(nil)

        XCTAssertEqual(viewModel.state, .empty)
        XCTAssertEqual(viewModel.previewText, "")
        XCTAssertNil(viewModel.selectedFileName)
    }

    @MainActor
    func testRawJSONInspectorMissingFileReturnsFailedState() async throws {
        let viewModel = RawJSONInspectorViewModel(previewByteLimit: 256, previewLineLimit: 12)
        let missingURL = try makeTemporaryDirectory().appendingPathComponent("missing-sidecar.json")

        viewModel.openForCurrentSelection(missingURL)
        try await waitForRawJSONInspector(viewModel)

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected missing file to fail")
        }
        XCTAssertTrue(message.contains("could not find"))
        XCTAssertEqual(viewModel.selectedFileName, "missing-sidecar.json")
    }

    @MainActor
    func testRawJSONInspectorLargeJSONReturnsTruncatedPreview() async throws {
        let root = try makeTemporaryDirectory()
        let jsonURL = root.appendingPathComponent("large-sidecar.json")
        let payload = "{\n" + (0..<600).map { #"  "line\#($0)": "value\#($0)""# }.joined(separator: ",\n") + "\n}"
        try payload.write(to: jsonURL, atomically: true, encoding: .utf8)

        let viewModel = RawJSONInspectorViewModel(previewByteLimit: 256, previewLineLimit: 20)
        viewModel.openForCurrentSelection(jsonURL)
        try await waitForRawJSONInspector(viewModel)

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertTrue(viewModel.previewText.contains("Preview truncated for performance."))
        XCTAssertEqual(viewModel.selectedFileName, "large-sidecar.json")
        XCTAssertNotNil(viewModel.fileSizeDescription)
    }

    @MainActor
    func testRawJSONInspectorInvalidJSONReturnsPreviewAndError() async throws {
        let root = try makeTemporaryDirectory()
        let jsonURL = root.appendingPathComponent("invalid-sidecar.json")
        try """
        {
          "sessionID": "broken",
          "takes":
        }
        """.write(to: jsonURL, atomically: true, encoding: .utf8)

        let viewModel = RawJSONInspectorViewModel(previewByteLimit: 512, previewLineLimit: 20)
        viewModel.openForCurrentSelection(jsonURL)
        try await waitForRawJSONInspector(viewModel)

        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected invalid JSON to fail validation")
        }
        XCTAssertTrue(message.contains("JSON validation failed"))
        XCTAssertTrue(viewModel.previewText.contains("\"sessionID\": \"broken\""))
        XCTAssertEqual(viewModel.errorMessage, message)
    }

    func testRawJSONInspectorSourceAvoidsBodyIOAndRecursiveScan() throws {
        let serviceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/StagingInspector.swift")
        let viewURL = projectRootURL().appendingPathComponent("ScratchLab/Views/StagingInspectorView.swift")
        let serviceSource = try String(contentsOf: serviceURL, encoding: .utf8)
        let viewSource = try String(contentsOf: viewURL, encoding: .utf8)

        let inspectorServiceSource = try sourceSlice(
            in: serviceSource,
            from: "enum InspectorState: Equatable, Sendable {",
            through: "struct StagingInspectorContext: Identifiable {"
        )
        let rawInspectorViewSource = try sourceSlice(
            in: viewSource,
            from: "struct RawJSONInspectorView: View {",
            through: "struct StagingInspectorView: View {"
        )

        XCTAssertTrue(inspectorServiceSource.contains("Task.detached"))
        XCTAssertTrue(inspectorServiceSource.contains("Preview truncated for performance."))
        XCTAssertTrue(inspectorServiceSource.contains("FileHandle(forReadingFrom: url)"))
        XCTAssertFalse(inspectorServiceSource.contains("contentsOfDirectory"))
        XCTAssertFalse(inspectorServiceSource.contains("enumerator("))
        XCTAssertFalse(rawInspectorViewSource.contains("Data(contentsOf:"))
        XCTAssertFalse(rawInspectorViewSource.contains("String(contentsOf:"))
        XCTAssertFalse(rawInspectorViewSource.contains("JSONDecoder().decode"))
    }

    func testRawJSONInspectorButtonUsesDedicatedInspectorInsteadOfStagingScan() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let buttonSource = try sourceSlice(
            in: source,
            from: "Button(\"Raw JSON/sidecar inspection\") {",
            through: ".controlSize(.small)"
        )

        XCTAssertTrue(buttonSource.contains("rawJSONInspector.openForCurrentSelection(selectedRawJSONURL)"))
        XCTAssertTrue(buttonSource.contains("isShowingRawJSONInspector = true"))
        XCTAssertFalse(buttonSource.contains("isShowingStagingInspector = true"))
        XCTAssertFalse(buttonSource.contains("shareLastRoutineSession()"))
    }

    func testMacCaptureSourceAutoCreatesSessionAndAppliesFallbackCaptureNames() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("guard ensureCaptureSessionForRecording() != nil else"))
        XCTAssertTrue(source.contains("config.performerName = \"Unknown Performer\""))
        XCTAssertTrue(source.contains("config.bpm = CaptureClickTrackDefaults.defaultTimedBPM"))
        XCTAssertTrue(source.contains("sessionName(defaultAppName: \"Untitled Session\")"))
        XCTAssertTrue(source.contains("\"Take \\(formatter.string(from: date))"))
    }

    func testMacCaptureSourceUsesTruthfulMixerStatus() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private var selectedMixerMIDIDeviceName: String?"))
        XCTAssertTrue(source.contains("return captureEngine.midiListeningState"))
        XCTAssertTrue(source.contains("return \"Mixer Optional\""))
        XCTAssertTrue(source.contains("selectedMixerMIDIDeviceName != nil ? .green : .secondary"))
        XCTAssertTrue(source.contains("Not Connected"))
        XCTAssertTrue(source.contains("MIDI Source"))
        XCTAssertTrue(source.contains("MIDI Monitor"))
    }

    func testMacCaptureSourceShowsSelectedAudioAndCameraDeviceNames() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("captureEngine.selectedAudioDeviceName"))
        XCTAssertTrue(source.contains("captureEngine.selectedVideoDeviceName"))
        XCTAssertTrue(source.contains("captureEngine.audioSignalStatusText"))
    }

    func testPracticeSourceKeepsDemoPathAppReviewSafe() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("Try the Baby Scratch demo, listen to the coach, and start a practice run."))
        XCTAssertTrue(source.contains("No hardware needed"))
        XCTAssertFalse(source.contains("dataset details"))
    }

    func testAdvancedDiagnosticsExplainCameraAndTickActivity() throws {
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let notationURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let coreURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let macSource = try String(contentsOf: macURL, encoding: .utf8)
        let notationSource = try String(contentsOf: notationURL, encoding: .utf8)
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)

        XCTAssertTrue(macSource.contains("true (Live Input)"))
        XCTAssertTrue(macSource.contains("live preview"))
        XCTAssertTrue(notationSource.contains("Baby Scratch Template"))
        XCTAssertTrue(notationSource.contains("Audio-only take"))
        XCTAssertTrue(notationSource.contains("No record movement detected."))
        XCTAssertFalse(notationSource.contains("Notation detected from audio — direction pending."))
        XCTAssertTrue(coreSource.contains("func markNotationIdle()"))
        XCTAssertTrue(notationSource.contains("ScratchLabRuntimeDiagnostics.shared.markNotationIdle()"))
    }

    func testSessionExportCoordinatorUsesAsyncAVAssetTrackLoading() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("tracks(withMediaType:"))
        XCTAssertTrue(source.contains("loadTracks(withMediaType: .audio)"))
        XCTAssertTrue(source.contains("loadTracks(withMediaType: .video)"))
    }

    func testSessionExportCoordinatorUsesAsyncAVAssetFormatDescriptionLoading() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let directPropertyPattern = #"\b[A-Za-z_][A-Za-z0-9_]*\.formatDescriptions\b"#

        XCTAssertNil(source.range(of: directPropertyPattern, options: .regularExpression))
        XCTAssertTrue(source.contains("load(.formatDescriptions)"))
    }

    func testAppSourcesAvoidDeprecatedSynchronousAVFoundationAssetLoading() throws {
        let sourceRoots = [
            projectRootURL().appendingPathComponent("ScratchLab"),
            projectRootURL().appendingPathComponent("ScratchLabDesktop")
        ]
        let directTrackPropertyPattern = #"\b[A-Za-z_][A-Za-z0-9_]*\.(formatDescriptions|naturalSize|preferredTransform|nominalFrameRate|timeRange)\b"#
        let directAssetPropertyPattern = #"\b[A-Za-z_][A-Za-z0-9_]*(Asset|asset|Track|track)\.(duration|commonMetadata|metadata)\b"#
        let fileManager = FileManager.default
        var failures: [String] = []

        for root in sourceRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Missing source root: \(root.path)")
                continue
            }

            for case let sourceURL as URL in enumerator where sourceURL.pathExtension == "swift" {
                let source = try String(contentsOf: sourceURL, encoding: .utf8)
                if source.contains("tracks(withMediaType:") {
                    failures.append(sourceURL.path)
                }
                if source.range(of: directTrackPropertyPattern, options: .regularExpression) != nil {
                    failures.append(sourceURL.path)
                }
                if source.range(of: directAssetPropertyPattern, options: .regularExpression) != nil {
                    failures.append(sourceURL.path)
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, "Deprecated synchronous AVFoundation loading in: \(failures.sorted().joined(separator: ", "))")
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

    // MARK: - Baby Scratch sync tests (notation coach + audio master clock)

    func testNotationVisualizerViewModelDrivesTimingFromAudioPlayer() throws {
        let notationViewURL = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let source = try String(contentsOf: notationViewURL, encoding: .utf8)

        // Shared coordinator must be the master clock source — no separate player owned by the VM.
        XCTAssertTrue(source.contains("BabyScratchDemoPlaybackCoordinator"))
        XCTAssertTrue(source.contains("demo.currentAudioTime"))
        XCTAssertTrue(source.contains("BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration"))
        XCTAssertTrue(source.contains("BabyScratchReferenceMotionTimeline.phraseEnd"))
        // Separate owned player must be gone.
        XCTAssertFalse(source.contains("let audioPlayer = ScratchCoachDemoAudioPlayer()"))
        // Old wall-clock approach must be gone.
        XCTAssertFalse(source.contains("playbackStartWall"))
        XCTAssertFalse(source.contains("rawElapsed.truncatingRemainder"))
    }

    func testBabyScratchDemoAudioDurationExceedsSingleNotationPhrase() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let phraseEnd = BabyScratchReferenceMotionTimeline.phraseEnd
        let cycleDuration = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration

        // Audio must be substantially longer than a single notation phrase.
        XCTAssertGreaterThan(audioDuration, phraseEnd * 2)
        // Each audio cycle must be longer than the notation phrase (silence gap must exist).
        XCTAssertGreaterThan(cycleDuration, phraseEnd)
        // Audio must contain at least 4 complete phrase cycles.
        XCTAssertGreaterThanOrEqual(Int(audioDuration / cycleDuration), 4)
    }

    func testBabyScratchPhraseTimeHoldsAtPhraseEndDuringSilence() {
        let phraseEnd = BabyScratchReferenceMotionTimeline.phraseEnd
        let cycleDuration = BabyScratchReferenceMotionTimeline.demoAudioPhraseCycleDuration
        // A time midway through the silence gap within the first cycle.
        let silenceTime = phraseEnd + (cycleDuration - phraseEnd) / 2
        let silencePose = BabyScratchReferenceMotionTimeline.pose(at: silenceTime)
        // A time at the very start of the second cycle.
        let secondCycleStart = cycleDuration + BabyScratchReferenceMotionTimeline.phraseStart
        let secondCycleStartPose = BabyScratchReferenceMotionTimeline.pose(at: secondCycleStart)
        let firstStroke = BabyScratchReferenceMotionTimeline.strokeSegments.first

        // During silence the coach must hold neutral, not continue scratching.
        XCTAssertFalse(ScratchLabBabyScratchDemoMotionPattern.isMovingStrokeWindow(playbackTime: silenceTime))
        XCTAssertEqual(silencePose.direction, .neutral)
        XCTAssertEqual(silencePose.isHold, true)
        // On the next cycle the first stroke should restart correctly.
        XCTAssertEqual(secondCycleStartPose.direction, firstStroke?.direction)
    }

    func testBabyScratchNotationStrokesAlternateForwardBackInsidePhrase() throws {
        let timeline = BabyScratchReferenceMotionTimeline.strokeSegments
        XCTAssertGreaterThanOrEqual(timeline.count, 2)
        for index in 0..<timeline.count {
            let expected: ScratchMotionDirection = index.isMultiple(of: 2) ? .forward : .backward
            XCTAssertEqual(timeline[index].direction, expected, "Stroke \(index) direction mismatch")
        }
        // All strokes must end at or before phraseEnd.
        let phraseEnd = BabyScratchReferenceMotionTimeline.phraseEnd
        XCTAssertTrue(timeline.allSatisfy { $0.endTime <= phraseEnd + 0.001 })
    }

    func testBabyScratchNotationCoachAndCoachRigSampleSameTimeline() throws {
        let notationViewURL = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let macViewURL = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let coreURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let notationSource = try String(contentsOf: notationViewURL, encoding: .utf8)
        let macSource = try String(contentsOf: macViewURL, encoding: .utf8)
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)

        // Notation coach references BabyScratchReferenceMotionTimeline (for cycle duration + phraseEnd).
        XCTAssertTrue(notationSource.contains("BabyScratchReferenceMotionTimeline"))
        // Notation coach uses the shared coordinator — not a separately owned audio player.
        XCTAssertTrue(notationSource.contains("BabyScratchDemoPlaybackCoordinator"))
        XCTAssertTrue(notationSource.contains("demo.currentAudioTime"))
        // The shared timeline definition and coach rig pose path live in CaptureCore.swift.
        XCTAssertTrue(coreSource.contains("struct BabyScratchReferenceMotionTimeline"))
        XCTAssertTrue(coreSource.contains("let timelineState = BabyScratchReferenceMotionTimeline.pose("))
        // The coordinator is also defined in CaptureCore.swift.
        XCTAssertTrue(coreSource.contains("final class BabyScratchDemoPlaybackCoordinator"))
        // The macOS Baby Scratch coach bypasses buffered audio analysis and samples the direct audio-time pose.
        XCTAssertTrue(macSource.contains("BabyScratchDemoPlaybackCoordinator.coachPose(for: audioTime)"))
        XCTAssertTrue(macSource.contains("BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)"))
        XCTAssertFalse(notationSource.contains("playbackStartWall"))
    }

    func testBabyScratchDemoPlaybackCoordinatorNotationPhraseTimeMapsCorrectly() {
        let phraseEnd = BabyScratchDemoPlaybackCoordinator.phraseDuration
        let cycleDur = BabyScratchDemoPlaybackCoordinator.phraseCycleDuration

        // At audioTime 0, phrase time is 0.
        XCTAssertEqual(BabyScratchDemoPlaybackCoordinator.notationPhraseTime(for: 0), 0, accuracy: 0.001)

        // Mid-phrase time maps 1:1.
        let midPhrase = phraseEnd / 2
        XCTAssertEqual(BabyScratchDemoPlaybackCoordinator.notationPhraseTime(for: midPhrase), midPhrase, accuracy: 0.001)

        // During the silence gap, phrase time clamps to phraseEnd.
        let silenceTime = phraseEnd + (cycleDur - phraseEnd) / 2
        XCTAssertEqual(BabyScratchDemoPlaybackCoordinator.notationPhraseTime(for: silenceTime), phraseEnd, accuracy: 0.001)

        // At the start of the second cycle, phrase time resets near 0.
        let secondCycleStart = cycleDur + 0.001
        XCTAssertLessThan(BabyScratchDemoPlaybackCoordinator.notationPhraseTime(for: secondCycleStart), phraseEnd)
        XCTAssertGreaterThanOrEqual(BabyScratchDemoPlaybackCoordinator.notationPhraseTime(for: secondCycleStart), 0)
    }

    func testBabyScratchDemoPlaybackCoordinatorCoachPoseFollowsNotation() {
        let phraseEnd = BabyScratchDemoPlaybackCoordinator.phraseDuration
        let cycleDur = BabyScratchDemoPlaybackCoordinator.phraseCycleDuration

        // During an active stroke window, the pose is not neutral/hold.
        let firstStroke = BabyScratchReferenceMotionTimeline.strokeSegments.first
        if let stroke = firstStroke {
            let startStroke = stroke.startTime + 0.001
            let midStroke = stroke.startTime + stroke.duration / 2
            let startPose = BabyScratchDemoPlaybackCoordinator.coachPose(for: startStroke)
            let activePose = BabyScratchDemoPlaybackCoordinator.coachPose(for: midStroke)
            XCTAssertFalse(activePose.isHold, "Pose during active stroke should not be hold")
            XCTAssertNotEqual(activePose.direction, .neutral)
            XCTAssertNotEqual(startPose.scratchProgress, activePose.scratchProgress)
        }

        // During silence, the coach holds neutral.
        let silenceTime = phraseEnd + (cycleDur - phraseEnd) / 2
        let silencePose = BabyScratchDemoPlaybackCoordinator.coachPose(for: silenceTime)
        let laterSilencePose = BabyScratchDemoPlaybackCoordinator.coachPose(for: silenceTime + 0.25)
        XCTAssertEqual(silencePose.direction, .neutral)
        XCTAssertEqual(silencePose.isHold, true)
        XCTAssertEqual(laterSilencePose.direction, .neutral)
        XCTAssertEqual(laterSilencePose.scratchProgress, silencePose.scratchProgress, accuracy: 0.0001)
    }

    func testBabyScratchDemoPlaybackCoordinatorSharesPlayerBetweenViewsAtSourceLevel() throws {
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let notationURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/NotationVisualizerView.swift")
        let coreURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let macSource = try String(contentsOf: macURL, encoding: .utf8)
        let notationSource = try String(contentsOf: notationURL, encoding: .utf8)
        let coreSource = try String(contentsOf: coreURL, encoding: .utf8)

        // Coordinator is defined in CaptureCore.swift.
        XCTAssertTrue(coreSource.contains("final class BabyScratchDemoPlaybackCoordinator"))
        XCTAssertTrue(coreSource.contains("let audioPlayer: ScratchCoachDemoAudioPlayer"))

        // MacAnalyzerView owns the single coordinator instance and passes it to NotationVisualizerView.
        XCTAssertTrue(macSource.contains("@StateObject private var babyScratchDemo = BabyScratchDemoPlaybackCoordinator()"))
        XCTAssertTrue(macSource.contains("NotationVisualizerView(demo: babyScratchDemo"))

        // NotationVisualizerView accepts the coordinator — no separate owned player.
        XCTAssertTrue(notationSource.contains("init(demo: BabyScratchDemoPlaybackCoordinator"))
        XCTAssertFalse(notationSource.contains("ScratchCoachDemoAudioPlayer()"))
    }

    func testMacCoachButtonsUseCoordinatorPlaybackAPI() throws {
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let macSource = try String(contentsOf: macURL, encoding: .utf8)

        XCTAssertTrue(macSource.contains("action: babyScratchDemo.playBabyScratch"))
        XCTAssertTrue(macSource.contains("action: babyScratchDemo.pause"))
        XCTAssertTrue(macSource.contains("action: babyScratchDemo.replayBabyScratch"))
        XCTAssertTrue(macSource.contains("isPlayingProvider: { babyScratchDemo.isPlaying }"))
        XCTAssertFalse(macSource.contains("action: babyScratchDemo.audioPlayer.play"))
        XCTAssertFalse(macSource.contains("action: babyScratchDemo.audioPlayer.replay"))
        XCTAssertFalse(macSource.contains("babyScratchDemo.audioPlayer.configure(with: coachInstruction)"))
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
        XCTAssertTrue(report?.issues.contains(where: {
            $0.contains("Take 002") && $0.localizedCaseInsensitiveContains("failed")
        }) == true)
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
        XCTAssertTrue(report.issues.contains(where: {
            $0.contains("Take 001") && $0.localizedCaseInsensitiveContains("audio")
        }))
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

    func testArtifactPreflightMarksStableFileReady() throws {
        let root = try self.makeTemporaryDirectory()
        let url = root.appendingPathComponent("stable.wav")
        try self.writePlaceholderFile(at: url, contents: Data("ready".utf8))

        let result = ArtifactPreflight.checkFileReady(
            url: url,
            configuration: .init(timeout: 0.2, pollInterval: 0.02, stabilityInterval: 0.05)
        )

        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isStable)
        XCTAssertGreaterThan(result.bytes, 0)
    }

    func testArtifactPreflightKeepsChangingFileFinalizing() throws {
        let root = try self.makeTemporaryDirectory()
        let url = root.appendingPathComponent("changing.wav")
        try self.writePlaceholderFile(at: url, contents: Data("a".utf8))

        let writer = DispatchQueue(label: "artifact-preflight-writer")
        writer.asyncAfter(deadline: .now() + 0.03) {
            try? Data("ab".utf8).write(to: url, options: .atomic)
        }
        writer.asyncAfter(deadline: .now() + 0.11) {
            try? Data("abc".utf8).write(to: url, options: .atomic)
        }

        let result = ArtifactPreflight.checkFileReady(
            url: url,
            configuration: .init(timeout: 0.12, pollInterval: 0.02, stabilityInterval: 0.05)
        )

        XCTAssertTrue(result.exists)
        XCTAssertFalse(result.isStable)
        XCTAssertGreaterThan(result.bytes, 0)
    }

    func testLocalRecordingArtifactStatusMarksMissingAudioNotReady() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "missing-audio-status",
            takeNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_001_500)
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try FileManager.default.removeItem(at: audioURL)

        let statuses = SessionArchiveBuilder().localRecordingArtifactStatuses(
            lastRecordingURL: videoURL,
            preflightConfiguration: .init(timeout: 0.15, pollInterval: 0.02, stabilityInterval: 0.04)
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .missingAudio)
    }

    func testLocalRecordingArtifactStatusMarksZeroByteAudioNotReady() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "zero-byte-audio-status",
            takeNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_001_510),
            useRealMedia: true
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try Data().write(to: audioURL, options: .atomic)

        let statuses = SessionArchiveBuilder().localRecordingArtifactStatuses(
            lastRecordingURL: videoURL,
            preflightConfiguration: .init(timeout: 0.15, pollInterval: 0.02, stabilityInterval: 0.04)
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .missingAudio)
    }

    func testLocalRecordingArtifactStatusWaitsForFinalizingAudioThenBecomesReady() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "finalizing-audio-ready",
            takeNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_001_520)
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try Data().write(to: audioURL, options: .atomic)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? Data("audio-ready".utf8).write(to: audioURL, options: .atomic)
        }

        let statuses = SessionArchiveBuilder().localRecordingArtifactStatuses(
            lastRecordingURL: videoURL,
            preflightConfiguration: .init(timeout: 0.5, pollInterval: 0.02, stabilityInterval: 0.05)
        )

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.readiness, .ready)
    }

    func testLocalRecordingValidationNamesExactTakeWhenAudioMissing() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "validation-missing-audio",
            takeNumber: 3,
            createdAt: Date(timeIntervalSince1970: 1_710_001_530)
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try FileManager.default.removeItem(at: audioURL)

        let report = SessionArchiveBuilder().validationReport(
            for: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Broken Export",
                config: nil
            )
        )

        XCTAssertEqual(report?.issues.first, "Take 003 audio is missing. Retake it before export.")
    }

    func testPreparePackageDoesNotProceedWhenAudioIsMissing() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "prepare-package-missing-audio",
            takeNumber: 3,
            createdAt: Date(timeIntervalSince1970: 1_710_001_540)
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try FileManager.default.removeItem(at: audioURL)

        XCTAssertThrowsError(
            try SessionArchiveBuilder().preparePackage(
                from: .localRecordingSession(
                    lastRecordingURL: videoURL,
                    sessionName: "Broken Export",
                    config: nil
                )
            )
        ) { error in
            XCTAssertEqual(error as? SessionExportError, .invalidSessionMetadata)
        }
    }

    func testRepeatedLocalRecordingValidationIsDeterministicForMissingAudio() throws {
        let root = try self.makeTemporaryDirectory()
        let videoURL = try self.makeLocalRecordingTake(
            in: root,
            sessionID: "repeat-validation-missing-audio",
            takeNumber: 2,
            createdAt: Date(timeIntervalSince1970: 1_710_001_550)
        )
        let audioURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try FileManager.default.removeItem(at: audioURL)

        let builder = SessionArchiveBuilder()
        let source = SessionExportSource.localRecordingSession(
            lastRecordingURL: videoURL,
            sessionName: "Repeat Validation",
            config: nil
        )

        let first = builder.validationReport(for: source)
        let second = builder.validationReport(for: source)

        XCTAssertEqual(first?.issues, second?.issues)
    }
}

extension CaptureReliabilityPhase1CoreTests {
    func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func sourceSlice(in source: String, from startToken: String, through endToken: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken), "Missing start token \(startToken)")
        let end = try XCTUnwrap(
            source[start.lowerBound...].range(of: endToken),
            "Missing end token \(endToken)"
        )
        return String(source[start.lowerBound..<end.upperBound])
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

    func makeDetectedNotationSnapshot() -> CaptureCore.DetectedNotationSnapshot {
        CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: 0.79,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 57,
            detectionSources: ["audio", "video"],
            recordMovementEvents: [
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: 0.10,
                    endTime: 0.28,
                    startPosition: 0.02,
                    endPosition: 0.96,
                    direction: "forward",
                    movementKind: .normalPush,
                    speed: 5.2,
                    confidence: 0.82,
                    source: "detected"
                ),
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: 0.34,
                    endTime: 0.56,
                    startPosition: 0.94,
                    endPosition: 0.08,
                    direction: "backward",
                    movementKind: .normalPull,
                    speed: 3.9,
                    confidence: 0.76,
                    source: "detected"
                )
            ],
            audioEvents: [
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.10,
                    endTime: 0.28,
                    duration: 0.18,
                    peakLevel: 0.42,
                    rmsLevel: 0.18,
                    confidence: 0.71,
                    eventKind: "scratchBurst",
                    source: "audio"
                ),
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.34,
                    endTime: 0.56,
                    duration: 0.22,
                    peakLevel: 0.37,
                    rmsLevel: 0.15,
                    confidence: 0.67,
                    eventKind: "possibleDrag",
                    source: "audio"
                )
            ],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Date(timeIntervalSince1970: 1_715_000_000)
        )
    }

    func makeAudioOnlyDetectedNotationSnapshot() -> CaptureCore.DetectedNotationSnapshot {
        CaptureCore.DetectedNotationSnapshot(
            notationSource: "partial",
            notationConfidence: 0.63,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 57,
            detectionSources: ["audio"],
            recordMovementEvents: [],
            audioEvents: [
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.12,
                    endTime: 0.24,
                    duration: 0.12,
                    peakLevel: 0.31,
                    rmsLevel: 0.12,
                    confidence: 0.64,
                    eventKind: "scratchBurst",
                    source: "audio"
                ),
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.29,
                    endTime: 0.37,
                    duration: 0.08,
                    peakLevel: 0,
                    rmsLevel: 0,
                    confidence: 0.62,
                    eventKind: "possibleCut",
                    source: "audio"
                )
            ],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Date(timeIntervalSince1970: 1_715_000_010)
        )
    }

    func makeMovementEvent(
        startTime: TimeInterval,
        endTime: TimeInterval,
        startPosition: Double,
        endPosition: Double,
        direction: String,
        confidence: Double,
        source: String = "detected"
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime,
            endTime: endTime,
            startPosition: startPosition,
            endPosition: endPosition,
            direction: direction,
            movementKind: .hold,
            speed: 0,
            confidence: confidence,
            source: source
        )
    }

    func makeAudioNotationEventCandidate(
        startTime: TimeInterval,
        endTime: TimeInterval,
        peakLevel: Float,
        rmsLevel: Float,
        confidence: Double,
        eventKind: ScratchAudioNotationEventKind
    ) -> ScratchAudioNotationEventCandidate {
        ScratchAudioNotationEventCandidate(
            startTime: startTime,
            endTime: endTime,
            duration: endTime - startTime,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel,
            confidence: confidence,
            eventKind: eventKind,
            source: "audio"
        )
    }

    func repeatingWave(
        amplitude: Float,
        frequency: Double,
        sampleRate: Double,
        duration: Double
    ) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { index in
            let phase = (Double(index) / sampleRate) * frequency * 2 * Double.pi
            return amplitude * Float(sin(phase))
        }
    }

    func makeCanonicalValidationBuilder() -> SessionArchiveBuilder {
        SessionArchiveBuilder { source, _, generatedData in
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
            case "serato", "scratch_only", "beat_only", "scratch_with_beat":
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

    @MainActor
    func waitForRawJSONInspector(
        _ viewModel: RawJSONInspectorViewModel,
        iterations: Int = 80
    ) async throws {
        for _ in 0..<iterations {
            switch viewModel.state {
            case .loading, .idle:
                try await Task.sleep(nanoseconds: 25_000_000)
            case .empty, .loaded, .failed:
                return
            }
        }
        XCTFail("Timed out waiting for Raw JSON inspector state to settle")
    }

    // MARK: - Mixer MIDI capture tests

    func testMIDICCDecodesToNormalizedValue() {
        let event = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1000.0,
            takeRelativeTime: 0.5,
            deviceName: "IAC Driver Bus 1",
            channel: 0,
            controller: 7,
            value: 64,
            normalizedValue: Double(64) / 127.0,
            mappedControl: nil
        )
        XCTAssertEqual(event.value, 64)
        XCTAssertEqual(event.normalizedValue, Double(64) / 127.0, accuracy: 0.001)
        XCTAssertNil(event.mappedControl)
        XCTAssertEqual(event.deviceName, "IAC Driver Bus 1")
        XCTAssertEqual(event.channel, 0)
        XCTAssertEqual(event.controller, 7)

        let fullScale = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1000.0, takeRelativeTime: 1.0,
            deviceName: "TestDevice", channel: 1, controller: 11,
            value: 127, normalizedValue: Double(127) / 127.0, mappedControl: nil
        )
        XCTAssertEqual(fullScale.normalizedValue, 1.0, accuracy: 0.001)

        let zero = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1000.0, takeRelativeTime: 2.0,
            deviceName: "TestDevice", channel: 1, controller: 11,
            value: 0, normalizedValue: Double(0) / 127.0, mappedControl: nil
        )
        XCTAssertEqual(zero.normalizedValue, 0.0, accuracy: 0.001)
    }

    func testNoMIDIExportsEmptyMixerMidiEvents() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)
        let snapshot = makeDetectedNotationSnapshot()
        XCTAssertTrue(snapshot.mixerMidiEvents.isEmpty)
        sidecar = sidecar.withDetectedNotation(snapshot)
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let notationDocument = try JSONDecoder().decode(SessionExportNotationDocument.self, from: data)

        XCTAssertTrue(notationDocument.mixerMidiEvents.isEmpty)
        XCTAssertTrue(notationDocument.faderEvents.isEmpty)
    }

    func testRawMIDIExportsMixerMidiEventsWithoutFakeFaderEvents() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)

        let midiEvent = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1001.0,
            takeRelativeTime: 0.42,
            deviceName: "MixEmergency",
            channel: 0,
            controller: 7,
            value: 100,
            normalizedValue: Double(100) / 127.0,
            mappedControl: nil
        )
        let snapshot = makeDetectedNotationSnapshot().withMixerMidiEvents([midiEvent])
        sidecar = sidecar.withDetectedNotation(snapshot)
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let notationDocument = try JSONDecoder().decode(SessionExportNotationDocument.self, from: data)

        XCTAssertEqual(notationDocument.mixerMidiEvents.count, 1)
        XCTAssertEqual(notationDocument.mixerMidiEvents.first?.controller, 7)
        XCTAssertEqual(notationDocument.mixerMidiEvents.first?.value, 100)
        XCTAssertEqual(notationDocument.mixerMidiEvents.first?.deviceName, "MixEmergency")
        XCTAssertNil(notationDocument.mixerMidiEvents.first?.mappedControl)
        XCTAssertTrue(notationDocument.faderEvents.isEmpty, "faderEvents must stay empty when no fader mapping exists")
    }

    func testUnmappedMIDIDoesNotCreateDerivedFaderEvents() {
        let events = [
            CaptureCore.RawMixerMIDIEvent(
                timestamp: 1000.0,
                takeRelativeTime: 0.10,
                deviceName: "MixEmergency",
                channel: 0,
                controller: 7,
                value: 0,
                normalizedValue: 0.0,
                mappedControl: nil
            ),
            CaptureCore.RawMixerMIDIEvent(
                timestamp: 1000.1,
                takeRelativeTime: 0.18,
                deviceName: "MixEmergency",
                channel: 0,
                controller: 7,
                value: 127,
                normalizedValue: 1.0,
                mappedControl: nil
            )
        ]

        XCTAssertTrue(CaptureCore.deriveDetectedNotationFaderEvents(from: events).isEmpty)
    }

    func testMappedCrossfaderMIDICreatesCutFaderEvent() {
        let events = [
            CaptureCore.RawMixerMIDIEvent(
                timestamp: 1000.0,
                takeRelativeTime: 0.10,
                deviceName: "MixEmergency",
                channel: 0,
                controller: 7,
                value: 5,
                normalizedValue: 0.04,
                mappedControl: "crossfader"
            ),
            CaptureCore.RawMixerMIDIEvent(
                timestamp: 1000.1,
                takeRelativeTime: 0.18,
                deviceName: "MixEmergency",
                channel: 0,
                controller: 7,
                value: 120,
                normalizedValue: 0.94,
                mappedControl: "crossfader"
            )
        ]

        let derived = CaptureCore.deriveDetectedNotationFaderEvents(from: events)
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.eventKind, .cut)
        XCTAssertEqual(derived.first?.control, "crossfader")
        XCTAssertEqual(derived.first?.source, "midi")
    }

    func testQuickCrossfaderReversalCreatesPulseEvent() {
        let events = [
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.0, takeRelativeTime: 0.10, deviceName: "MixEmergency", channel: 0, controller: 7, value: 0, normalizedValue: 0.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.1, takeRelativeTime: 0.16, deviceName: "MixEmergency", channel: 0, controller: 7, value: 127, normalizedValue: 1.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.2, takeRelativeTime: 0.23, deviceName: "MixEmergency", channel: 0, controller: 7, value: 0, normalizedValue: 0.0, mappedControl: "crossfader")
        ]

        let derived = CaptureCore.deriveDetectedNotationFaderEvents(from: events)
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.eventKind, .pulse)
    }

    func testRepeatedCrossfaderPulsesCanCreateTransformPulseEvent() {
        let events = [
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.0, takeRelativeTime: 0.10, deviceName: "MixEmergency", channel: 0, controller: 7, value: 0, normalizedValue: 0.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.1, takeRelativeTime: 0.16, deviceName: "MixEmergency", channel: 0, controller: 7, value: 127, normalizedValue: 1.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.2, takeRelativeTime: 0.22, deviceName: "MixEmergency", channel: 0, controller: 7, value: 0, normalizedValue: 0.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1000.3, takeRelativeTime: 0.28, deviceName: "MixEmergency", channel: 0, controller: 7, value: 127, normalizedValue: 1.0, mappedControl: "crossfader")
        ]

        let derived = CaptureCore.deriveDetectedNotationFaderEvents(from: events)
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived.first?.eventKind, .transformPulse)
    }

    func testDetectedNotationJSONIncludesMixerMidiEventsArray() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)
        sidecar = sidecar.withDetectedNotation(makeDetectedNotationSnapshot())
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let rawJSON = try String(contentsOf: notationURL, encoding: .utf8)

        XCTAssertTrue(rawJSON.contains("\"mixerMidiEvents\""), "detected_notation.json must contain mixerMidiEvents key")
        XCTAssertTrue(rawJSON.contains("\"faderEvents\""), "detected_notation.json must contain faderEvents key")
    }

    // MARK: - MIDI Learn and crossfader mapping tests

    func testCrossfaderCCMappingDisplayName() {
        let mapping = MacCaptureEngine.CrossfaderCCMapping(channel: 0, controller: 7)
        XCTAssertEqual(mapping.displayName, "CC7 Ch1")

        let ch2 = MacCaptureEngine.CrossfaderCCMapping(channel: 1, controller: 11)
        XCTAssertEqual(ch2.displayName, "CC11 Ch2")
    }

    func testMIDILearnStateTransitionsToListening() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertEqual(engine.midiLearnState, .idle)
        engine.startMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.midiLearnState, .listening)
        XCTAssertEqual(engine.midiLearnFeedback, "Listening...")
    }

    func testCancelMIDILearnReturnsToIdle() {
        UserDefaults.standard.removeObject(forKey: "scratchlab.mac.crossfaderMIDIMapping")
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.startMIDILearn()
        engine.cancelMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.midiLearnState, .idle)
        XCTAssertNil(engine.crossfaderCCMapping)
    }

    func testMIDISourceSelectionPrefersIACWhenCurrentSelectionMissing() {
        let sources = [
            MacCaptureEngine.MIDIInputSourceChoice(id: "midi_2", name: "Hardware Mixer"),
            MacCaptureEngine.MIDIInputSourceChoice(id: "midi_1", name: "IAC Driver Bus 1")
        ]

        let resolved = MacCaptureEngine.resolveMIDISourceSelectionID(
            currentSelectionID: "missing",
            availableSources: sources
        )

        XCTAssertEqual(resolved, "midi_1")
    }

    func testSelectedMIDISourceIsPersisted() {
        let defaults = UserDefaults.standard
        let key = "scratchlab.mac.selectedMIDIInputSourceID"
        defaults.removeObject(forKey: key)

        let firstEngine = MacCaptureEngine(autoRefreshDevices: false)
        firstEngine.selectedMIDIInputSourceID = "midi_1"

        let secondEngine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertEqual(secondEngine.selectedMIDIInputSourceID, "midi_1")

        defaults.removeObject(forKey: key)
    }

    func testReceivingMIDICCUpdatesLastMIDIEventSummary() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)

        engine.recordReceivedMIDICCEvent(
            sourceName: "IAC Driver Bus 1",
            channel: 0,
            controller: 7,
            value: 96
        )

        XCTAssertEqual(engine.midiEventsReceivedCount, 1)
        XCTAssertEqual(engine.lastMIDICCMessage, "CC7 Ch1 Value96")
        XCTAssertEqual(engine.lastMIDIEventSummary, "Received CC7 Ch1 Value96")
        XCTAssertEqual(engine.midiListeningState, "Listening")
    }

    func testMIDILearnUpdatesFromListeningToLearnedStateWhenCCArrives() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.startMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.recordReceivedMIDICCEvent(
            sourceName: "IAC Driver Bus 1",
            channel: 1,
            controller: 11,
            value: 64,
            mappedControl: "crossfader"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 1, controller: 11))
        XCTAssertEqual(engine.midiLearnState, .learned(MacCaptureEngine.CrossfaderCCMapping(channel: 1, controller: 11)))
        XCTAssertEqual(engine.midiLearnFeedback, "Learned Xfader: CC11 Ch2")
        XCTAssertEqual(engine.lastMIDIEventSummary, "Received CC11 Ch2 Value64")
    }

    func testClearCrossfaderMappingRemovesMapping() {
        let defaults = UserDefaults.standard
        let key = "scratchlab.mac.crossfaderMIDIMapping"
        let mapping = MacCaptureEngine.CrossfaderCCMapping(channel: 0, controller: 7)
        if let data = try? JSONEncoder().encode(mapping) {
            defaults.set(data, forKey: key)
        }

        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertNotNil(engine.crossfaderCCMapping)

        engine.clearCrossfaderMapping()

        XCTAssertNil(defaults.data(forKey: key), "UserDefaults key should be removed after clear")
    }

    func testMappedControlCrossfaderTagRoundTripsExport() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)

        let crossfaderEvent = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1002.0,
            takeRelativeTime: 0.75,
            deviceName: "IAC Driver Bus 1",
            channel: 0,
            controller: 7,
            value: 127,
            normalizedValue: 1.0,
            mappedControl: "crossfader"
        )
        let snapshot = makeDetectedNotationSnapshot().withMixerMidiEvents([crossfaderEvent])
        sidecar = sidecar.withDetectedNotation(snapshot)
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let notationDocument = try JSONDecoder().decode(SessionExportNotationDocument.self, from: data)

        let exported = try XCTUnwrap(notationDocument.mixerMidiEvents.first)
        XCTAssertEqual(notationDocument.mixerMidiEvents.count, 1)
        XCTAssertEqual(exported.mappedControl, "crossfader")
        XCTAssertEqual(exported.normalizedValue, 1.0, accuracy: 0.001)
        XCTAssertTrue(notationDocument.faderEvents.isEmpty, "A single mapped MIDI event must not fake a fader event")
    }

    func testMappedCrossfaderMIDIRoundTripsExportWithFaderEvents() throws {
        let root = try makeTemporaryDirectory()
        var package = try makeCanonicalPackage(rootURL: root)
        let take = try XCTUnwrap(package.takes.first)
        let sidecarData = try Data(contentsOf: take.sidecarURL)
        var sidecar = try JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: sidecarData)

        let midiEvents = [
            CaptureCore.RawMixerMIDIEvent(timestamp: 1002.0, takeRelativeTime: 0.10, deviceName: "IAC Driver Bus 1", channel: 0, controller: 7, value: 0, normalizedValue: 0.0, mappedControl: "crossfader"),
            CaptureCore.RawMixerMIDIEvent(timestamp: 1002.1, takeRelativeTime: 0.18, deviceName: "IAC Driver Bus 1", channel: 0, controller: 7, value: 127, normalizedValue: 1.0, mappedControl: "crossfader")
        ]
        let snapshot = makeDetectedNotationSnapshot().withMixerMidiEvents(midiEvents)
        sidecar = sidecar.withDetectedNotation(snapshot)
        try sidecar.encodedData().write(to: take.sidecarURL, options: .atomic)

        let builder = makeCanonicalValidationBuilder()
        let archive = try builder.createArchive(from: try builder.preparePackage(from: .package(package)))
        let unzipRoot = try makeTemporaryDirectory()
        let archiveRoot = try unzipArchive(archive.archiveURL, to: unzipRoot)
        let notationURL = archiveRoot.appendingPathComponent("notation/take-001_detected_notation.json")
        let data = try Data(contentsOf: notationURL)
        let notationDocument = try JSONDecoder().decode(SessionExportNotationDocument.self, from: data)

        XCTAssertEqual(notationDocument.mixerMidiEvents.count, 2)
        XCTAssertEqual(notationDocument.faderEvents.count, 1)
        XCTAssertEqual(notationDocument.faderEvents.first?.eventKind, "cut")
        XCTAssertEqual(notationDocument.faderEvents.first?.control, "crossfader")
        XCTAssertEqual(notationDocument.faderEvents.first?.source, "midi")
        XCTAssertTrue(notationDocument.detectionSources.contains("midi"))
    }

    func testMIDILearnSourceCodePresence() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("struct CrossfaderCCMapping"))
        XCTAssertTrue(source.contains("struct MIDIInputSourceChoice"))
        XCTAssertTrue(source.contains("enum MIDILearnState"))
        XCTAssertTrue(source.contains("func startMIDILearn()"))
        XCTAssertTrue(source.contains("func cancelMIDILearn()"))
        XCTAssertTrue(source.contains("func clearCrossfaderMapping()"))
        XCTAssertTrue(source.contains("selectedMIDIInputSourceID"))
        XCTAssertTrue(source.contains("midiEventsReceivedCount"))
        XCTAssertTrue(source.contains("lastMIDIEventSummary"))
        XCTAssertTrue(source.contains("refreshMIDISources()"))
        XCTAssertTrue(source.contains("crossfaderMIDIMapping"))
        XCTAssertTrue(source.contains("mappedControl: mappedControl"))
    }

    func testMIDILearnUISourcePresence() throws {
        let projectRoot = projectRootURL()
        let viewSourceURL = projectRoot.appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let engineSourceURL = projectRoot.appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let viewSource = try String(contentsOf: viewSourceURL, encoding: .utf8)
        let engineSource = try String(contentsOf: engineSourceURL, encoding: .utf8)

        XCTAssertTrue(viewSource.contains("midiLearnRow"))
        XCTAssertTrue(viewSource.contains("midiSourcePickerRow"))
        XCTAssertTrue(viewSource.contains("midiMonitorCard"))
        XCTAssertTrue(viewSource.contains("Learn Crossfader"))
        XCTAssertTrue(viewSource.contains("startMIDILearn()"))
        XCTAssertTrue(viewSource.contains("cancelMIDILearn()"))
        XCTAssertTrue(viewSource.contains("clearCrossfaderMapping()"))
        XCTAssertTrue(viewSource.contains("Listening..."))
        XCTAssertTrue(viewSource.contains("captureEngine.midiLearnFeedback"))
        XCTAssertTrue(viewSource.contains("Last MIDI message"))
        XCTAssertTrue(viewSource.contains("Events received"))
        XCTAssertTrue(engineSource.contains("No MIDI received. Check IAC Driver / MixEmergency MIDI Out."))
    }

}

extension CaptureRecoveryPhase2CoreTests {
    func writePlaceholderFile(at url: URL, contents: Data) throws {
        try contents.write(to: url, options: .atomic)
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
        try writePlaceholderFile(at: videoURL, contents: Data("mov-\(takeNumber)".utf8))
        try writePlaceholderFile(at: audioURL, contents: Data("wav-\(takeNumber)".utf8))
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

// MARK: - New notation model, export sandbox, and UI tests

final class ScratchLabNotationAndExportTests: XCTestCase {

    // MARK: - ScratchMovementKind

    func testScratchMovementKindCodable() throws {
        let allCases: [ScratchMovementKind] = [
            .fastPush, .normalPush, .slowDrag,
            .fastPull, .normalPull, .slowPullDrag,
            .hold, .releaseNormalPlayback
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in allCases {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(ScratchMovementKind.self, from: data)
            XCTAssertEqual(decoded, kind, "Round-trip failed for \(kind)")
        }
    }

    func testReleaseNormalPlaybackDistinctFromNormalPush() {
        XCTAssertNotEqual(ScratchMovementKind.releaseNormalPlayback, .normalPush)
        XCTAssertNotEqual(ScratchMovementKind.releaseNormalPlayback.rawValue, ScratchMovementKind.normalPush.rawValue)
    }

    func testHoldDistinctFromReleaseNormalPlayback() {
        XCTAssertNotEqual(ScratchMovementKind.hold, .releaseNormalPlayback)
        XCTAssertNotEqual(ScratchMovementKind.hold.rawValue, ScratchMovementKind.releaseNormalPlayback.rawValue)
    }

    func testScratchMovementKindDerivedFromStroke() throws {
        // Encode a minimal ScratchNotation with known direction + speed and verify movementKind
        let json = """
        {"version":1,"scratchID":"test","demoStart":0,"demoEnd":2,"timingBasis":"phrase",
         "strokes":[
           {"startTime":0.0,"endTime":0.25,"direction":"forward","speedClassification":"fast","faderState":"open"},
           {"startTime":0.3,"endTime":0.55,"direction":"forward","speedClassification":"medium","faderState":"open"},
           {"startTime":0.6,"endTime":0.85,"direction":"forward","speedClassification":"slow","faderState":"open"},
           {"startTime":0.9,"endTime":1.15,"direction":"backward","speedClassification":"fast","faderState":"closed"},
           {"startTime":1.2,"endTime":1.45,"direction":"backward","speedClassification":"medium","faderState":"closed"},
           {"startTime":1.5,"endTime":1.75,"direction":"backward","speedClassification":"slow","faderState":"closed"}
         ]}
        """
        let notation = try JSONDecoder().decode(ScratchNotation.self, from: Data(json.utf8))
        let kinds = notation.strokes.map(\.movementKind)
        XCTAssertEqual(kinds[0], .fastPush)
        XCTAssertEqual(kinds[1], .normalPush)
        XCTAssertEqual(kinds[2], .slowDrag)
        XCTAssertEqual(kinds[3], .fastPull)
        XCTAssertEqual(kinds[4], .normalPull)
        XCTAssertEqual(kinds[5], .slowPullDrag)
    }

    // MARK: - ScratchFaderEventKind

    func testScratchFaderEventKindCodable() throws {
        let allCases: [ScratchFaderEventKind] = [
            .open, .closed, .cut, .pulse, .transformPulse, .flareClick, .unknown
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in allCases {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(ScratchFaderEventKind.self, from: data)
            XCTAssertEqual(decoded, kind, "Round-trip failed for \(kind)")
        }
    }

    // MARK: - Export sandbox

    func testExportBuildsInTempFirst() throws {
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("temporaryDirectory"),
            "Export should build the ZIP in a temp location before moving to user destination"
        )
    }

    func testExportSaveUsesNSSavePanel() throws {
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(source.contains("NSSavePanel"), "macOS export must use NSSavePanel for user-selected destination")
    }

    func testFailedSaveSurfacesError() throws {
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("unableToSaveArchive"),
            "A failed save must surface SessionExportError.unableToSaveArchive"
        )
        XCTAssertTrue(
            source.contains("ScratchLab couldn't save to the selected location"),
            "Error message must tell user to try another location"
        )
    }

    func testExportEntitlementIncludesUserSelectedReadWrite() throws {
        let entURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/ScratchLabDesktop.entitlements")
        let source = try String(contentsOf: entURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("com.apple.security.files.user-selected.read-write"),
            "Entitlements must include user-selected.read-write for save panel destinations"
        )
    }

    func testSecurityScopedAccessURLDoesNotStandardize() throws {
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: exportURL, encoding: .utf8)
        // The fix removes standardizedFileURL from securityScopedAccessURL to preserve cloud paths
        let funcRange = try XCTUnwrap(source.range(of: "func securityScopedAccessURL"))
        let closingRange = try XCTUnwrap(source[funcRange.lowerBound...].range(of: "}\n"))
        let funcBody = String(source[funcRange.lowerBound..<closingRange.upperBound])
        XCTAssertFalse(
            funcBody.contains("standardizedFileURL"),
            "securityScopedAccessURL must not standardize the URL — iCloud/Drive paths lose their scope token"
        )
    }

    func testExportCopyFallbackPresent() throws {
        let exportURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("Fallback: try a direct copy without file coordination"),
            "Export must include a direct-copy fallback for cloud filesystems that fail NSFileCoordinator"
        )
    }

    // MARK: - Primary nav

    func testPrimaryNavWorkspaceTabValues() throws {
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macURL, encoding: .utf8)
        for id in ["practice", "capture", "review", "advanced"] {
            XCTAssertTrue(source.contains("case \(id)"), "Primary nav must include \(id)")
        }
    }

    func testNoTTMOrSXRATCHInPrimaryNavLabels() throws {
        let macURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: macURL, encoding: .utf8)
        XCTAssertFalse(source.contains("\"TTM\""), "Primary nav must not expose TTM branding")
        XCTAssertFalse(source.contains("\"SXRATCH\""), "Primary nav must not expose SXRATCH branding")

        let formulaURL = projectRootURL().appendingPathComponent("ScratchLab/Views/FormulaPlaygroundView.swift")
        let formulaSource = try String(contentsOf: formulaURL, encoding: .utf8)
        XCTAssertFalse(formulaSource.contains("\"TTM GRAPH\""), "TTM GRAPH label must be replaced")
        XCTAssertFalse(formulaSource.contains("TTM-style aliases"), "TTM-style alias label must be replaced")
    }

    // Slice U.1 — Battle Mode user-facing copy must not contain "AI" wording.
    // Internal type names (AICharacter) and enum case identifiers (aiChallenge)
    // are allowed because they are not surfaced to users; only the literal UI
    // strings are guarded here.
    func testBattleModeUserFacingCopyHasNoAIWording() throws {
        let battleURL = projectRootURL().appendingPathComponent("ScratchLab/Views/AIBattleModeView.swift")
        let battleSource = try String(contentsOf: battleURL, encoding: .utf8)
        XCTAssertFalse(
            battleSource.contains("\"AI BATTLE\""),
            "Battle mode header must not display 'AI BATTLE'"
        )
        XCTAssertFalse(
            battleSource.contains("\"Challenge an AI opponent\""),
            "Battle mode subtitle must not display 'Challenge an AI opponent'"
        )

        let gameStateURL = projectRootURL().appendingPathComponent("ScratchLab/Models/GameState.swift")
        let gameStateSource = try String(contentsOf: gameStateURL, encoding: .utf8)
        XCTAssertFalse(
            gameStateSource.contains("= \"AI Challenge\""),
            "GameMode.aiChallenge raw value must not display 'AI Challenge'"
        )
    }

    // Slice U.2 - internal dev/handoff/planning docs must not be bundled.
    // Scans the PBXResourcesBuildPhase section of project.pbxproj and fails
    // if any forbidden file or directory appears as a resource entry. The
    // test only inspects entries inside Copy Bundle Resources phases; the
    // files may exist in the repo, they simply must not ship.
    func testShippingTargetsDoNotBundleInternalDevDocs() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: projectURL, encoding: .utf8)

        let beginMarker = "/* Begin PBXResourcesBuildPhase section */"
        let endMarker = "/* End PBXResourcesBuildPhase section */"
        guard
            let beginRange = source.range(of: beginMarker),
            let endRange = source.range(of: endMarker, range: beginRange.upperBound..<source.endIndex)
        else {
            XCTFail("Could not locate PBXResourcesBuildPhase section in project.pbxproj")
            return
        }
        let resourcesSection = source[beginRange.upperBound..<endRange.lowerBound]

        let forbiddenNames: [String] = [
            "TASKS.md",
            "DEV_LOG.md",
            "AI_HANDOFF.md",
            "AI_HANDOFF",
            "SOUL.md",
            "PROFILE.md",
            "CLAUDE.md",
            "docs/training_dataset_plan.md",
            "AI_CONTEXT.md",
        ]

        let inResourcesSuffix = " in Resources */"
        let openComment = "/* "

        for line in resourcesSection.split(separator: "\n") {
            guard let suffixRange = line.range(of: inResourcesSuffix) else { continue }
            guard let openRange = line.range(of: openComment, range: line.startIndex..<suffixRange.lowerBound) else { continue }
            let path = String(line[openRange.upperBound..<suffixRange.lowerBound])

            for forbidden in forbiddenNames {
                let exactMatch = path == forbidden
                let folderChild = path.hasPrefix(forbidden + "/")
                let fileSuffix = path.hasSuffix("/" + forbidden)
                if exactMatch || folderChild || fileSuffix {
                    XCTFail(
                        "Forbidden internal doc '\(forbidden)' must not appear in any Copy Bundle Resources phase. Found resource entry path '\(path)'."
                    )
                }
            }
        }
    }

    // MARK: - Notation canvas

    func testScratchNotationCanvasViewEmptyModel() {
        // Verify the view accepts nil notation without crashing
        let view = ScratchNotationCanvasView(notation: nil, playbackTime: 0, loopDuration: 2.0)
        XCTAssertNotNil(view) // if init doesn't crash, we're good
    }

    func testScratchNotationCanvasViewBabyScratchModel() throws {
        let canvasURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/ScratchNotationCanvasView.swift")
        let source = try String(contentsOf: canvasURL, encoding: .utf8)
        XCTAssertTrue(source.contains("ScratchNotation"), "Canvas must accept ScratchNotation model")
        XCTAssertTrue(source.contains("movementKind"), "Canvas must use movementKind for slope differentiation")
        XCTAssertTrue(source.contains("releaseNormalPlayback"), "Canvas must handle releaseNormalPlayback distinctly")
        XCTAssertTrue(source.contains("faderState"), "Canvas must render the fader lane")
        XCTAssertFalse(
            source.contains("loadBabyScratchFromBundle") || source.contains("Data(contentsOf"),
            "Canvas body must not perform file reads"
        )
    }

    func testScratchNotationCanvasViewNoFileReadsInBody() throws {
        let canvasURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/ScratchNotationCanvasView.swift")
        let source = try String(contentsOf: canvasURL, encoding: .utf8)
        XCTAssertFalse(source.contains("Data(contentsOf"), "No synchronous file reads in canvas")
        XCTAssertFalse(source.contains("JSONDecoder().decode"), "No JSON decoding in canvas")
        XCTAssertFalse(source.contains("contentsOfDirectory"), "No directory enumeration in canvas")
    }

    func testBrandMarkExistsAndHasNoExternalAssets() throws {
        let brandURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/ScratchLabBrandMark.swift")
        let source = try String(contentsOf: brandURL, encoding: .utf8)
        XCTAssertTrue(source.contains("struct ScratchLabBrandMark"), "Brand mark view must exist")
        XCTAssertFalse(source.contains("Image(\""), "Brand mark must not reference external image assets")
        XCTAssertFalse(source.contains("TTM"), "Brand mark must not copy TTM branding")
        XCTAssertFalse(source.contains("SXRATCH"), "Brand mark must not copy SXRATCH branding")
    }

    // MARK: - Dataset probe regression tests

    func testProbeVideoUsesNaturalSizeNotTransformedSize() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // Dimensions must come from naturalSize directly; applying preferredTransform
        // rotates portrait iPhone video to display orientation, which disagrees with
        // the codec dimensions that ffprobe reports. Both sides must use codec dimensions.
        XCTAssertFalse(
            source.contains("naturalSize.applying(preferredTransform)"),
            "probeVideo must not apply preferredTransform — use naturalSize directly to match ffprobe codec dimensions"
        )
    }

    func testProbeAudioUsesFileFormatForBitDepth() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // processingFormat converts to float32 (4 bytes) regardless of on-disk bit depth;
        // fileFormat reflects actual stored depth (e.g. 2 bytes for 16-bit WAV).
        XCTAssertTrue(
            source.contains("audioFile.fileFormat.streamDescription.pointee.mBitsPerChannel"),
            "probeAudio must use fileFormat (not processingFormat) to get on-disk bit depth"
        )
        XCTAssertFalse(
            source.contains("format.streamDescription.pointee.mBitsPerChannel"),
            "probeAudio must not derive sample_width_bytes from processingFormat"
        )
    }

    func testProbeVideoFrameRateRoundedToFourDecimalPlaces() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // Python validator rounds to 4dp via round(fps, 4). Swift must use the same
        // precision to avoid 1-ULP mismatches from Float32→Double conversion of nominalFrameRate.
        XCTAssertTrue(
            source.contains("Double(frameRateValue) * 10_000") || source.contains("Double(frameRateValue) * 10000"),
            "probeVideo must round frame_rate_fps to 4 decimal places (multiply by 10_000)"
        )
        XCTAssertFalse(
            source.contains("Double(frameRateValue) * 1_000_000") || source.contains("Double(frameRateValue) * 1000000"),
            "probeVideo must not use 6-decimal rounding for frame_rate_fps — causes Python validator mismatch"
        )
    }

    func testCanonicalManifestContainsCaptureSpecV1Fields() throws {
        // The spec_version literal lives in CaptureCanonicalRules; the coordinator uses that constant.
        let rulesURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureReliability.swift")
        let rulesSource = try String(contentsOf: rulesURL, encoding: .utf8)
        XCTAssertTrue(rulesSource.contains("\"capture_spec_v1\""), "CaptureCanonicalRules must define spec_version = capture_spec_v1")

        let coordURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: coordURL, encoding: .utf8)
        // Coordinator must emit all keys required by validate_session.py.
        XCTAssertTrue(source.contains("CaptureCanonicalRules.specVersion"), "coordinator must stamp spec_version from CaptureCanonicalRules")
        XCTAssertTrue(source.contains("case scratchType = \"scratch_type\""), "manifest must include scratch_type key")
        XCTAssertTrue(source.contains("case segmentCount = \"segment_count\""), "manifest must include segment_count key")
        XCTAssertTrue(source.contains("case djToken = \"dj_token\""), "manifest must include dj_token key")
        XCTAssertTrue(source.contains("case allowedBPMs = \"allowed_bpms\""), "manifest must include allowed_bpms key")
        XCTAssertTrue(source.contains("let takes: [CanonicalTakeManifestRecord]"), "manifest must include takes array")
    }

    func testCanonicalManifestStorageTypesAreStringsNotURLs() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // CanonicalSessionManifest and CanonicalTakeManifestRecord must store paths as String,
        // not URL, so the encoded JSON contains portable relative paths.
        let manifestStructPattern = #"struct CanonicalSessionManifest: Codable \{[^}]+\}"#
        if let range = source.range(of: manifestStructPattern, options: .regularExpression) {
            let structBody = String(source[range])
            XCTAssertFalse(structBody.contains(": URL"), "CanonicalSessionManifest must not store URL properties")
            XCTAssertFalse(structBody.contains(": [URL]"), "CanonicalSessionManifest must not store URL array properties")
        }
        // The files dict in take manifest must be [String: String] (relative paths), not [String: URL].
        XCTAssertTrue(
            source.contains("let files: [String: String]"),
            "CanonicalTakeManifestRecord.files must be [String: String] (relative paths)"
        )
    }

    func testRoutineCaptureSourceWritesDedicatedRawAudioStemDuringRecording() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private final class RoutineAudioCaptureWriter"))
        XCTAssertTrue(source.contains("appendRoutineAudioSampleBufferIfNeeded(sampleBuffer)"))
        XCTAssertTrue(source.contains("activeRoutineAudioCaptureWriter = RoutineAudioCaptureWriter"))
        XCTAssertTrue(source.contains("let audioURL = directory"))
    }

    func testStemExportScratchOnlyFileIsPhysicallyNamed() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        // Primary audio must use scratch_only source token so the file is named _scratch_only.wav
        XCTAssertTrue(source.contains("source: \"scratch_only\""))
        // serato and scratch_only must share the same physical artifact (alias)
        XCTAssertTrue(source.contains("artifacts[\"serato\"] = scratchArtifact"))
        XCTAssertTrue(source.contains("artifacts[\"scratch_only\"] = scratchArtifact"))
        // both files.serato and files.scratch_only must point to scratchOnlyRelativePath
        XCTAssertTrue(source.contains("\"serato\": context.scratchOnlyRelativePath"))
        XCTAssertTrue(source.contains("\"scratch_only\": context.scratchOnlyRelativePath"))
    }

    func testCanonicalExportAddsScratchAndBeatStemKeys() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("\"scratch_only\":"))
        XCTAssertTrue(source.contains("\"beat_only\":"))
        XCTAssertTrue(source.contains("\"scratch_with_beat\":"))
        XCTAssertTrue(source.contains("case stemAvailability = \"stem_availability\""))
        XCTAssertTrue(source.contains("artifacts[\"scratch_only\"] = scratchArtifact"))
        XCTAssertTrue(source.contains("artifacts[\"serato\"] = scratchArtifact"))
    }

    private func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension JSONDecoder {
    static var captureCoreDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Baby Scratch bundle resource invariants
//
// Audio-agnostic checks that must always hold for the bundled Baby Scratch
// demo audio + notation: the resource is present, decodes cleanly, the
// notation never overruns the audio, alternation is preserved, and no
// source/provenance tokens leak into shipping resources or the consuming
// Swift code.

extension CaptureReliabilityPhase1CoreTests {

    private static let bundleForbiddenTokens: [String] = [
        "/Users",
        "MakeMKV",
        "sourceMKV",
        "processed_makemkv",
        "QBERT",
        "Qbert",
        "SXRATCH",
        "SOURCE_ID",
        "rightsStatus",
        "reviewStatus"
    ]

    private static let bundleForbiddenJSONFieldNames: [String] = [
        "sourcePath",
        "sourceMKV",
        "sourceCollection",
        "sourceRoot",
        "outputRoot",
        "rightsStatus",
        "reviewStatus",
        "datasetClipID",
        "datasetTakeID",
        "originalAudioPath",
        "originalVideoPath"
    ]

    func testBabyDemoAudioBundleResourceIsPresentAndDecodable() throws {
        let url = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(audioFile.length, 0)
        XCTAssertGreaterThan(audioFile.processingFormat.sampleRate, 0)
        XCTAssertGreaterThan(audioFile.processingFormat.channelCount, 0)
    }

    func testBabyNotationJSONBundleLoadsSuccessfully() throws {
        let url = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json")
        let notation = try JSONDecoder().decode(ScratchNotation.self, from: Data(contentsOf: url))
        XCTAssertEqual(notation.scratchID, "baby")
        XCTAssertFalse(notation.strokes.isEmpty)
        XCTAssertNotNil(ScratchNotation.loadBabyScratchFromBundle())
    }

    func testBabyNotationDurationDoesNotExceedBundledAudioDuration() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let notationURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json")
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let notation = try JSONDecoder().decode(
            ScratchNotation.self,
            from: Data(contentsOf: notationURL)
        )

        XCTAssertGreaterThanOrEqual(notation.demoStart, 0)
        XCTAssertLessThanOrEqual(notation.demoEnd, audioDuration + 0.01)
        XCTAssertLessThanOrEqual(notation.timelineDuration, audioDuration + 0.01)
        for stroke in notation.strokes {
            XCTAssertGreaterThanOrEqual(stroke.startTime, 0)
            XCTAssertLessThanOrEqual(stroke.endTime, audioDuration + 0.01)
            XCTAssertLessThanOrEqual(stroke.startTime, stroke.endTime)
        }
    }

    func testBabyNotationHasAtLeastOneForwardAndOneBackwardStroke() throws {
        let url = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json")
        let notation = try JSONDecoder().decode(ScratchNotation.self, from: Data(contentsOf: url))
        XCTAssertTrue(notation.strokes.contains { $0.direction == .forward })
        XCTAssertTrue(notation.strokes.contains { $0.direction == .backward })
    }

    func testBabyNotationContainsNoForbiddenProvenanceFieldNames() throws {
        let urls = [
            projectRootURL().appendingPathComponent("ScratchLab/Resources/Notation/baby_scratch.json"),
            projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachDemoMotion/baby_scratch_strokes.json")
        ]
        for url in urls {
            let raw = try String(contentsOf: url, encoding: .utf8)
            for field in Self.bundleForbiddenJSONFieldNames {
                XCTAssertFalse(
                    raw.contains("\"\(field)\""),
                    "\(url.lastPathComponent) contains forbidden provenance field '\(field)'"
                )
            }
        }
    }

    func testBundledBabyAudioContainsNoForbiddenLeakTokens() throws {
        let audioURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let data = try Data(contentsOf: audioURL)
        for token in Self.bundleForbiddenTokens {
            guard let needle = token.data(using: .utf8) else { continue }
            XCTAssertNil(
                data.range(of: needle),
                "baby_noBeat.wav contains forbidden token '\(token)'"
            )
        }
    }

    func testCoachDemoAudioAndNotationDirectoriesContainNoForbiddenLeakTokensInTextResources() throws {
        let scanRoots: [URL] = [
            projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachDemoAudio"),
            projectRootURL().appendingPathComponent("ScratchLab/Resources/Notation"),
            projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachDemoMotion")
        ]
        let textExtensions: Set<String> = ["json", "md", "txt", "plist"]

        for root in scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let raw = try String(contentsOf: url, encoding: .utf8)
                for token in Self.bundleForbiddenTokens {
                    XCTAssertFalse(
                        raw.contains(token),
                        "\(url.path) contains forbidden token '\(token)'"
                    )
                }
            }
        }
    }

    func testCaptureCoreSourceContainsNoForbiddenLeakTokens() throws {
        let coreURL = projectRootURL()
            .appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let source = try String(contentsOf: coreURL, encoding: .utf8)
        for token in Self.bundleForbiddenTokens {
            XCTAssertFalse(
                source.contains(token),
                "CaptureCore.swift contains forbidden token '\(token)'"
            )
        }
    }

    func testScratchLabDesktopServicesContainNoForbiddenLeakTokens() throws {
        let servicesRoot = projectRootURL()
            .appendingPathComponent("ScratchLabDesktop/Services")
        // ScratchTypeMetadataSafety.swift is the blocklist itself — its job is
        // to detect these tokens at runtime, so the literals appear there by
        // design. Skip it; the file's own purpose is the safety check.
        let blocklistFiles: Set<String> = ["ScratchTypeMetadataSafety.swift"]
        guard let enumerator = FileManager.default.enumerator(
            at: servicesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("ScratchLabDesktop/Services directory missing")
            return
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            if blocklistFiles.contains(url.lastPathComponent) { continue }
            let raw = try String(contentsOf: url, encoding: .utf8)
            for token in Self.bundleForbiddenTokens {
                XCTAssertFalse(
                    raw.contains(token),
                    "\(url.lastPathComponent) contains forbidden token '\(token)'"
                )
            }
        }
    }
}
