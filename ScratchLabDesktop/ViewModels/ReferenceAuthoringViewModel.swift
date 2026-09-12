// ReferenceAuthoringViewModel.swift
// ScratchLabDesktop
//
// Main-actor UI state over one serial, non-main worker. The worker is the
// sole owner of ReferenceAuthoringSession and the capture bridge hooks.

import Combine
import Foundation

struct ReferenceAuthoringViewState: Equatable, Sendable {
    let session: ReferenceAuthoringSession
    let latestCalibrationRawValue: Int?
    var savedDrafts: [ReferenceSavedDraftSummary] = []
    var draftSaveError: String? = nil
    var draftLibraryError: String? = nil
    var reviewingSavedDraft: Bool = false
    var finalizedMediaURL: URL? = nil
    var savedReviewNotes: String = ""
}

struct ReferenceAuthoringWorkerUpdate: Equatable, Sendable {
    let state: ReferenceAuthoringViewState
    let errorMessage: String?
}

struct ReferenceAuthoringRawExportSnapshot: Sendable {
    let source: SessionExportSource
    /// Preserved takes outside the seed capture's existing archive group.
    let excludedReferenceTakeIDs: [String]
}

struct ReferenceAuthoringNavigationRequest: Equatable {
    enum Destination: String { case setup, capture, review }
    let id = UUID()
    let destination: Destination
}

/// Owns the non-Sendable hook closures behind one serial queue. The queue is
/// the only caller, so the bridge's blocking hooks can never run on main.
final class ReferenceAuthoringWorkerDriver: @unchecked Sendable {
    let hooks: ReferenceAuthoringRecordingHooks

    private let pendingConfigurationHandler: (ReferenceAuthoringBridgeTakeConfiguration) -> Void
    private let calibrationCommittedHandler: () -> Void
    private let finalizationWaitCancellationHandler: () -> Void
    /// The raw capture this session most recently finalized. Read-only
    /// provenance for the RAW export action; it starts, stops, approves and
    /// publishes nothing.
    private let lastFinalizedRecordingURLProvider: () -> URL?
    private let prepareBeatHandler: (BeatEngineMode, Int, ReferenceBeatSpecBinding?) throws -> ReferencePreparedBeat?
    private let recordingHasStoppedProvider: () -> Bool

    init(bridge: ReferenceAuthoringCaptureBridge, engine: MacCaptureEngine) {
        hooks = bridge.hooks
        recordingHasStoppedProvider = { bridge.activeRecordingHasStopped }
        prepareBeatHandler = { mode, bpm, binding in
            if let binding {
                let prepared = try ReferenceBeatAssetStore.resolve(binding: binding)
                guard prepared.mode == mode, binding.bpm == bpm else {
                    throw ReferenceAuthoringError.recordingFailed("The backing sound no longer matches this setup.")
                }
                return prepared
            }
            return try ReferenceBeatAssetStore.prepare(mode: mode, bpm: bpm)
        }
        lastFinalizedRecordingURLProvider = { bridge.lastFinalizedRecordingURL }
        pendingConfigurationHandler = { configuration in
            bridge.setPendingConfiguration(configuration)
        }
        calibrationCommittedHandler = {
            DispatchQueue.main.sync {
                engine.reloadCrossfaderCalibrations()
            }
        }
        finalizationWaitCancellationHandler = {
            // Leaving the screen abandons BOTH bounded waits. The start
            // handshake's own task still releases any Watch capture it may
            // have left running, so this cannot orphan a recording wrist.
            bridge.cancelPendingStartHandshake()
            bridge.cancelPendingFinalizationWait()
        }
    }

    init(
        hooks: ReferenceAuthoringRecordingHooks,
        pendingConfigurationHandler: @escaping (ReferenceAuthoringBridgeTakeConfiguration) -> Void = { _ in },
        calibrationCommittedHandler: @escaping () -> Void = {},
        finalizationWaitCancellationHandler: @escaping () -> Void = {},
        lastFinalizedRecordingURLProvider: @escaping () -> URL? = { nil },
        prepareBeatHandler: @escaping (BeatEngineMode, Int, ReferenceBeatSpecBinding?) throws -> ReferencePreparedBeat? = { _, _, _ in nil },
        recordingHasStoppedProvider: @escaping () -> Bool = { false }
    ) {
        self.hooks = hooks
        self.pendingConfigurationHandler = pendingConfigurationHandler
        self.calibrationCommittedHandler = calibrationCommittedHandler
        self.finalizationWaitCancellationHandler = finalizationWaitCancellationHandler
        self.lastFinalizedRecordingURLProvider = lastFinalizedRecordingURLProvider
        self.prepareBeatHandler = prepareBeatHandler
        self.recordingHasStoppedProvider = recordingHasStoppedProvider
    }

    var lastFinalizedRecordingURL: URL? { lastFinalizedRecordingURLProvider() }
    var recordingHasStopped: Bool { recordingHasStoppedProvider() }

    func prepareBeat(mode: BeatEngineMode, bpm: Int, binding: ReferenceBeatSpecBinding?) throws -> ReferencePreparedBeat? {
        try prepareBeatHandler(mode, bpm, binding)
    }

    func setPendingConfiguration(_ configuration: ReferenceAuthoringBridgeTakeConfiguration) {
        pendingConfigurationHandler(configuration)
    }

    func calibrationDidCommit() {
        calibrationCommittedHandler()
    }

    func cancelPendingFinalizationWait() {
        finalizationWaitCancellationHandler()
    }
}

/// Equivalent to a non-main actor, but backed by a dedicated serial queue so
/// the bridge's thread-level `!Thread.isMainThread` contract is guaranteed.
final class ReferenceAuthoringWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let driver: ReferenceAuthoringWorkerDriver
    private let calibrationStore: CrossfaderCalibrationStore
    private var session: ReferenceAuthoringSession
    private var latestCalibrationRawValue: Int?
    private let draftStore: ReferenceDraftStore?
    private var draftSaveError: String?
    private var draftLibraryError: String?
    private var lastPersistedTake: ReferenceAuthoringTake?
    private var lastPersistedNotes: String?
    private var reviewingSavedDraft = false
    private var savedReviewNotes = ""

    init(
        session: ReferenceAuthoringSession,
        driver: ReferenceAuthoringWorkerDriver,
        calibrationStore: CrossfaderCalibrationStore,
        queueLabel: String = "com.machelpnz.scratchlab.reference-authoring",
        draftStore: ReferenceDraftStore? = nil
    ) {
        self.session = session
        self.driver = driver
        self.calibrationStore = calibrationStore
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.draftStore = draftStore
    }

    func snapshot() async -> ReferenceAuthoringViewState {
        await enqueue { worker in worker.makeState() }
    }

    func refreshSavedDrafts() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do { _ = try worker.draftStore?.refresh(); worker.draftLibraryError = nil }
            catch { worker.draftLibraryError = Self.message(for: error) }
            return worker.makeUpdate()
        }
    }

    func saveDraft(reviewNotes: String, expectedTakeID: String? = nil) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            if let expectedTakeID,
               (worker.session.takeInReview ?? (worker.session.phase == .complete ? worker.session.takes.last : nil))?.id != expectedTakeID {
                return worker.makeUpdate()
            }
            worker.savedReviewNotes = reviewNotes
            worker.lastPersistedTake = nil
            return worker.makeUpdate()
        }
    }

    func reopenDraft(id: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                guard worker.session.phase != .recording, let store = worker.draftStore else {
                    throw ReferenceDraftStoreError.invalid("finish recording before reopening a draft")
                }
                try worker.persistCurrentDraft()
                let draft = try store.load(id: id)
                var restored = try ReferenceAuthoringSession(reviewing: draft, operatorName: worker.session.operatorName)
                try worker.verifyDraftFiles(in: &restored, draft: draft)
                worker.session = restored
                worker.reviewingSavedDraft = true
                worker.savedReviewNotes = draft.reviewNotes
                worker.draftSaveError = nil
                return worker.makeUpdate()
            } catch { return worker.makeUpdate(errorMessage: Self.message(for: error)) }
        }
    }

    /// Check immutable media plus the existing narrowly allowed late Watch
    /// additions. Current hardware/preflight is never substituted for a take.
    private func verifyDraftFiles(in target: inout ReferenceAuthoringSession, draft: ReferenceSavedDraft) throws {
        let binding = draft.sourceBinding
        let data = try Data(contentsOf: draft.sidecarURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)
        let refreshed = try ReferenceTearEvidenceCodec.exportBinding(from: binding, currentSidecarData: data,
            linkedWatchData: ReferenceAuthoringCaptureBridge.verifiedWatchData(sidecar: sidecar,
                takeDirectory: draft.mediaURL.deletingLastPathComponent()))
        let identity = TakeIdentity(sessionID: binding.capturedSessionID, takeID: binding.capturedTakeID,
                                    takeNumber: binding.capturedTakeNumber)
        if let watch = ReferenceAuthoringCaptureBridge.refreshWatchEvidence(mediaURL: draft.mediaURL,
                expectedIdentity: identity) {
            if draft.evidence.watchEvidence.isLinked && !watch.evidence.isLinked {
                throw ReferenceDraftStoreError.invalid("the linked Watch recording is missing or no longer matches")
            }
            if case .linked(let oldIdentity, let oldName, let oldHash) = draft.evidence.metadata.sourceState {
                guard case .linked(let newIdentity, let newName, let newHash) = watch.sourceState,
                      oldIdentity == newIdentity, oldName == newName,
                      oldHash == nil || oldHash == newHash else {
                    throw ReferenceDraftStoreError.invalid("the linked Watch recording changed after saving")
                }
            }
            target.updateWatchEvidenceForTakeInReview(watch.evidence,
                refreshedSourceBinding: refreshed, sourceState: watch.sourceState)
        }
        target.revalidateTakeInReview()
    }

    private func persistCurrentDraft() throws {
        guard let store = draftStore,
              let take = session.takeInReview ?? (session.phase == .complete ? session.takes.last : nil),
              let mediaURL = currentReviewMediaURL else { return }
        if take == lastPersistedTake, savedReviewNotes == lastPersistedNotes, draftSaveError == nil { return }
        _ = try store.save(take: take, mediaURL: mediaURL, reviewNotes: savedReviewNotes)
        lastPersistedTake = take
        lastPersistedNotes = savedReviewNotes
        draftSaveError = nil
    }

    func verifiedTakeForExport() async throws -> ReferenceAuthoringTake {
        let result: Result<ReferenceAuthoringTake, Error> = await enqueue { worker in Result {
            try worker.persistCurrentDraft()
            guard let take = worker.session.takes.last else { throw ReferenceAuthoringError.noActiveRecording }
            if let store = worker.draftStore {
                let draft = try store.load(id: take.id)
                var checked = worker.session
                try worker.verifyDraftFiles(in: &checked, draft: draft)
            }
            return take
        } }
        return try result.get()
    }

    private var currentReviewMediaURL: URL? {
        if let take = session.takeInReview ?? (session.phase == .complete ? session.takes.last : nil),
           let sidecarURL = take.rawSidecarURL, let name = take.evidence.actualMediaFileName {
            return sidecarURL.deletingLastPathComponent().appendingPathComponent(name)
        }
        return driver.lastFinalizedRecordingURL
    }

    func currentRecordingHasStopped() async -> Bool {
        await enqueue { worker in worker.driver.recordingHasStopped }
    }

    func configure(
        technique: ReferenceTechnique,
        pattern: ReferencePatternIdentity,
        bpm: Int,
        startingDirection: ReferenceStartingPlatterDirection,
        faderVariant: ReferenceFaderVariant,
        handedness: CaptureSessionHandedness,
        notes: String,
        beatEngineMode: BeatEngineMode = .boomBapTrainer,
        capturePurpose: ReferenceCapturePurpose = .canonicalReference
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.selectTechnique(technique)
            worker.session.selectPattern(pattern, bpm: bpm)
            worker.session.declareVariant(
                startingDirection: startingDirection,
                faderVariant: faderVariant,
                handedness: handedness
            )
            worker.session.notes = notes
            worker.session.selectCapturePurpose(capturePurpose)
            worker.session.selectBeatEngineMode(beatEngineMode)
            do {
                let beat = worker.session.selectedCapturePurpose == .movementCheck ? nil
                    : try worker.driver.prepareBeat(mode: beatEngineMode, bpm: bpm,
                        binding: worker.session.captureIntent?.beatSpec)
                worker.session.bindBeatSpec(beat?.binding)
                return worker.makeUpdate()
            } catch {
                worker.session.bindBeatSpec(nil)
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func refreshPreflight() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.refreshPreflight(using: worker.driver.hooks)
            return worker.makeUpdate()
        }
    }

    func beginCalibration(
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let liveSnapshot = worker.driver.hooks.currentPreflightSnapshot()
            worker.session.refreshPreflight(using: worker.driver.hooks)
            guard let address = liveSnapshot.observedCrossfaderAddress else {
                return worker.makeUpdate(errorMessage: "Crossfader calibration cannot start until live crossfader traffic identifies its MIDI address.")
            }
            worker.session.beginCalibration(
                address: address,
                openEnd: openEnd,
                activeDeck: activeDeck
            )
            return worker.makeUpdate()
        }
    }

    func ingestLatestCalibrationSample() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            guard let observation = worker.driver.hooks.latestCalibrationObservation() else {
                worker.latestCalibrationRawValue = nil
                return worker.makeUpdate()
            }
            worker.latestCalibrationRawValue = observation.rawValue
            worker.session.ingestCalibrationObservation(observation)
            return worker.makeUpdate()
        }
    }

    /// Arm the current calibration stage. The operator has read the
    /// instruction and presented the position.
    func armCalibrationCapture() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.armCalibrationCapture(using: worker.driver.hooks)
            return worker.makeUpdate()
        }
    }

    func retryCalibrationStep() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.retryCalibrationStep()
            return worker.makeUpdate()
        }
    }

    /// Adopt an exactly-matching stored reference calibration, if one exists,
    /// instead of asking for another sweep.
    ///
    /// The live crossfader address comes from the SAME preflight snapshot the
    /// panel already shows, so the calibration adopted is the one belonging to
    /// the fader the operator is actually pointed at. Nothing is fabricated:
    /// only a stored `CrossfaderCalibration` that passes its own validation
    /// and matches device, channel, CC, deck and open end is ever adopted.
    func adoptPersistedCalibration(
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck
    ) async -> (update: ReferenceAuthoringWorkerUpdate, outcome: ReferenceCalibrationReuseOutcome) {
        await enqueue { worker in
            let snapshot = worker.driver.hooks.currentPreflightSnapshot()
            worker.session.refreshPreflight(using: worker.driver.hooks)
            let outcome = worker.session.adoptPersistedCalibrationIfExact(
                store: worker.calibrationStore,
                openEnd: openEnd,
                activeDeck: activeDeck,
                address: snapshot.observedCrossfaderAddress
            )
            return (worker.makeUpdate(), outcome)
        }
    }

    var lastFinalizedRecordingURL: URL? { driver.lastFinalizedRecordingURL }

    /// File reads and encoding share the same serial owner as review mutations.
    func rawCaptureExportSnapshot(config: CaptureSessionConfig?) async throws -> ReferenceAuthoringRawExportSnapshot? {
        let result: Result<ReferenceAuthoringRawExportSnapshot?, Error> = await enqueue { worker in
            Result {
                guard worker.session.rawCaptureExportBlockReason() == nil,
                      let url = worker.currentReviewMediaURL else { return nil }
                let boundTakes = worker.session.takes.filter { $0.tearEvidenceSourceBinding != nil }
                var companions: [String: Data] = [:]
                var excluded: [String] = []
                if !boundTakes.isEmpty {
                    let group = try SessionArchiveBuilder().localRecordingExportGroup(lastRecordingURL: url)
                    for take in boundTakes {
                        guard var binding = take.tearEvidenceSourceBinding, let sourceURL = take.rawSidecarURL else {
                            throw ReferenceAuthoringError.recordingFailed("Bound tear evidence has no original sidecar location.")
                        }
                        let canonicalURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                        if canonicalURL == group.seedSidecarURL || group.sidecarURLsByTakeID.values.contains(canonicalURL) {
                            let currentData = try Data(contentsOf: sourceURL)
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .iso8601
                            let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: currentData)
                            binding = try ReferenceTearEvidenceCodec.exportBinding(from: binding,
                                currentSidecarData: currentData,
                                linkedWatchData: ReferenceAuthoringCaptureBridge.verifiedWatchData(
                                    sidecar: sidecar, takeDirectory: sourceURL.deletingLastPathComponent()))
                        }
                        guard try group.includes(sourceBinding: binding, sourceSidecarURL: sourceURL) else {
                            excluded.append(take.id)
                            continue
                        }
                        guard companions[binding.capturedTakeID] == nil else {
                            throw ReferenceAuthoringError.recordingFailed("Two authoring takes claim the same captured tear evidence.")
                        }
                        companions[binding.capturedTakeID] = try ReferenceTearEvidenceCodec.encode(
                            sourceBinding: binding, review: take.tearReview, projection: take.tearProjection,
                            performedLimitations: take.tearPerformedLimitations
                        )
                    }
                }
                return ReferenceAuthoringRawExportSnapshot(
                    source: .localRecordingSession(lastRecordingURL: url,
                        sessionName: "Reference Authoring Capture", config: worker.reviewingSavedDraft ? nil : config,
                        referenceTearEvidenceByTakeID: companions),
                    excludedReferenceTakeIDs: excluded
                )
            }
        }
        return try result.get()
    }

    func restoreTearEvidence(_ data: Data?) async -> (
        update: ReferenceAuthoringWorkerUpdate, result: ReferenceTearEvidenceCodec.ReadResult?
    ) {
        await enqueue { worker in
            do {
                let result = try worker.session.restoreTearEvidence(data)
                return (worker.makeUpdate(), result)
            } catch {
                return (worker.makeUpdate(errorMessage: Self.message(for: error)), nil)
            }
        }
    }

    func commitCalibration() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                try worker.session.commitCalibration(store: worker.calibrationStore)
                worker.driver.calibrationDidCommit()
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func startRecording() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            guard !worker.reviewingSavedDraft else {
                return worker.makeUpdate(errorMessage: "Choose New scratch before recording after a saved draft.")
            }
            guard let technique = worker.session.selectedTechnique,
                  let bpm = worker.session.selectedBPM else {
                return worker.makeUpdate(errorMessage: "Select and apply a complete authoring setup before recording.")
            }
            let captureIntent: ReferenceCaptureIntent
            let preparedBeat: ReferencePreparedBeat?
            do {
                preparedBeat = worker.session.selectedCapturePurpose == .movementCheck ? nil
                    : try worker.driver.prepareBeat(mode: worker.session.selectedBeatEngineMode,
                        bpm: bpm, binding: worker.session.selectedBeatSpec)
                worker.session.bindBeatSpec(preparedBeat?.binding)
                captureIntent = try worker.session.prepareCaptureIntentForRecording()
                if let preparedBeat, captureIntent.beatSpec != preparedBeat.binding {
                    throw ReferenceAuthoringError.recordingFailed("Use Retake to prepare a new take with the selected backing sound.")
                }
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
            worker.driver.setPendingConfiguration(
                ReferenceAuthoringBridgeTakeConfiguration(
                    technique: technique,
                    bpm: bpm,
                    beatEngineMode: worker.session.selectedBeatEngineMode,
                    handedness: worker.session.selectedHandedness,
                    notes: worker.session.notes,
                    captureIntent: captureIntent,
                    preparedBeat: preparedBeat
                )
            )
            switch worker.session.beginRecording(using: worker.driver.hooks) {
            case .success:
                return worker.makeUpdate()
            case .failure(let error):
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func stopRecording() async -> ReferenceAuthoringWorkerUpdate {
        await withTaskCancellationHandler {
            await enqueue { worker in
                switch worker.session.finishRecording(using: worker.driver.hooks) {
                case .success:
                    return worker.makeUpdate()
                case .failure(let error):
                    return worker.makeUpdate(errorMessage: Self.message(for: error))
                }
            }
        } onCancel: {
            driver.cancelPendingFinalizationWait()
        }
    }

    func adjustRepetitionBoundary(
        repetitionIndex: Int,
        startBeat: Double,
        endBeat: Double
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.adjustRepetitionBoundary(
                repetitionIndex: repetitionIndex,
                startBeat: startBeat,
                endBeat: endBeat
            )
            worker.session.revalidateTakeInReview()
            return worker.makeUpdate()
        }
    }

    func selectRepetitionForApproval(_ repetitionIndex: Int) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.selectRepetitionForApproval(repetitionIndex)
            worker.session.revalidateTakeInReview()
            return worker.makeUpdate()
        }
    }

    func rejectTake(notes: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                var rejected = worker.session
                try rejected.rejectTakeInReview(notes: notes)
                if let store = worker.draftStore, let take = rejected.takes.last,
                   let sidecar = take.rawSidecarURL, let media = take.evidence.actualMediaFileName {
                    _ = try store.save(take: take, mediaURL: sidecar.deletingLastPathComponent()
                        .appendingPathComponent(media), reviewNotes: notes)
                }
                worker.session = rejected
                worker.savedReviewNotes = ""
                worker.draftSaveError = nil
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func retake(afterTakeID: String? = nil) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                guard !worker.reviewingSavedDraft else {
                    throw ReferenceDraftStoreError.invalid("choose New scratch to return to recording")
                }
                try worker.persistCurrentDraft()
                guard let id = afterTakeID ?? worker.session.latestRecordedTake?.id else {
                    throw ReferenceAuthoringError.noActiveRecording
                }
                try worker.session.retake(afterTakeID: id)
                worker.savedReviewNotes = ""
                return worker.makeUpdate()
            } catch { return worker.makeUpdate(errorMessage: Self.message(for: error)) }
        }
    }

    func prepareNewScratchSetup(afterTakeID: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                try worker.persistCurrentDraft()
                if worker.reviewingSavedDraft {
                    guard worker.session.latestRecordedTake?.id == afterTakeID,
                          worker.session.phase != .recording else { throw ReferenceAuthoringError.noActiveRecording }
                    worker.session = ReferenceAuthoringSession(
                        authoringSessionID: "reference-\(UUID().uuidString.lowercased())",
                        operatorName: worker.session.operatorName)
                    worker.reviewingSavedDraft = false
                } else {
                    try worker.session.prepareNewScratchSetup(afterTakeID: afterTakeID)
                }
                worker.savedReviewNotes = ""
                return worker.makeUpdate()
            } catch { return worker.makeUpdate(errorMessage: Self.message(for: error)) }
        }
    }

    func approveCanonical(notes: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                worker.savedReviewNotes = notes
                try worker.persistCurrentDraft()
                if let store = worker.draftStore, let take = worker.session.takeInReview {
                    let draft = try store.load(id: take.id)
                    var checked = worker.session
                    try worker.verifyDraftFiles(in: &checked, draft: draft)
                    if let beat = take.evidence.metadata.captureIntent?.beatSpec {
                        _ = try ReferenceBeatAssetStore.resolve(binding: beat,
                            rootURL: draft.mediaURL.deletingLastPathComponent().appendingPathComponent("beat_assets"))
                    }
                    worker.session = checked
                }
                // `approveTakeInReview` revalidates and re-checks every gate
                // itself; the caller does not get to pre-authorise it.
                try worker.session.approveTakeInReview(notes: notes)
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func prepareNextTake(afterApprovedTakeID expectedTakeID: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                guard !worker.reviewingSavedDraft else {
                    throw ReferenceDraftStoreError.invalid("choose New scratch to return to recording")
                }
                try worker.persistCurrentDraft()
                try worker.session.prepareNextTake(afterApprovedTakeID: expectedTakeID)
                worker.savedReviewNotes = ""
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    // MARK: - Tear segmentation review
    //
    // Every entry point below runs the correction on the SERIAL WORKER, the
    // sole owner of the session, exactly like every other mutation on this
    // type. None of them approves, validates, publishes or installs anything.

    func classifyTearCandidate(
        _ candidateID: String,
        as classification: ReferenceTearClassification,
        notes: String
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.classifyTearCandidate(
                candidateID,
                as: classification,
                notes: notes
            )
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    func addTearBoundary(
        candidateID: String,
        startTime: Double,
        endTime: Double,
        kind: ReferenceTearBoundaryKind,
        evidenceQuality: ReferenceTearEvidenceQuality,
        notes: String,
        now: Date = Date()
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.addTearBoundary(
                toCandidate: candidateID,
                startTime: startTime,
                endTime: endTime,
                kind: kind,
                evidenceQuality: evidenceQuality,
                notes: notes,
                now: now
            )
            return worker.makeUpdate(
                errorMessage: applied
                    ? nil
                    : "That tear boundary could not be added: a boundary must be a bounded interval inside a take under review."
            )
        }
    }

    func moveTearBoundary(
        candidateID: String,
        boundaryID: String,
        startTime: Double,
        endTime: Double,
        notes: String,
        now: Date = Date()
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.moveTearBoundary(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                startTime: startTime,
                endTime: endTime,
                notes: notes,
                now: now
            )
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    func setTearBoundaryKind(
        candidateID: String,
        boundaryID: String,
        kind: ReferenceTearBoundaryKind,
        notes: String
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.setTearBoundaryKind(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: kind,
                notes: notes
            )
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    func setTearBoundaryEvidenceQuality(
        candidateID: String,
        boundaryID: String,
        quality: ReferenceTearEvidenceQuality,
        notes: String
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.setTearBoundaryEvidenceQuality(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: quality,
                notes: notes
            )
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    func setTearBoundaryRemoved(
        candidateID: String,
        boundaryID: String,
        removed: Bool,
        notes: String,
        now: Date = Date()
    ) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.setTearBoundaryRemoved(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                removed: removed,
                notes: notes,
                now: now
            )
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    func setTearReviewNotes(_ notes: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            let applied = worker.session.setTearReviewNotes(notes)
            return worker.makeUpdate(errorMessage: applied ? nil : Self.tearCorrectionRefused)
        }
    }

    static let tearCorrectionRefused =
        "That tear correction was not applied: no matching candidate or boundary in the take under review."

    /// Poll the finalized take's Watch evidence once and attach it if it has
    /// moved. Returns the resulting state so the caller can stop when terminal.
    func refreshWatchEvidenceOnce() async -> (update: ReferenceAuthoringWorkerUpdate, isTerminal: Bool) {
        await enqueue { worker in
            if worker.reviewingSavedDraft, let store = worker.draftStore, let take = worker.session.takeInReview {
                do {
                    let draft = try store.load(id: take.id)
                    var checked = worker.session
                    try worker.verifyDraftFiles(in: &checked, draft: draft)
                    worker.session = checked
                    return (worker.makeUpdate(), checked.takeInReview?.evidence.watchEvidence.isTerminal ?? true)
                } catch { return (worker.makeUpdate(errorMessage: Self.message(for: error)), true) }
            }
            guard let refresh = worker.driver.hooks.refreshWatchEvidence() else {
                return (worker.makeUpdate(), true)
            }
            worker.session.updateWatchEvidenceForTakeInReview(
                refresh.evidence,
                refreshedSourceBinding: refresh.sourceBinding,
                sourceState: refresh.sourceState
            )
            return (worker.makeUpdate(), refresh.evidence.isTerminal)
        }
    }

    private func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable (ReferenceAuthoringWorker) -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: operation(self))
            }
        }
    }

    private func makeState() -> ReferenceAuthoringViewState {
        var state = ReferenceAuthoringViewState(
            session: session,
            latestCalibrationRawValue: latestCalibrationRawValue
        )
        state.savedDrafts = draftStore?.summaries ?? []
        state.draftSaveError = draftSaveError
        state.draftLibraryError = draftLibraryError
        state.reviewingSavedDraft = reviewingSavedDraft
        state.finalizedMediaURL = currentReviewMediaURL
        state.savedReviewNotes = savedReviewNotes
        return state
    }

    private func makeUpdate(errorMessage: String? = nil) -> ReferenceAuthoringWorkerUpdate {
        do { try persistCurrentDraft() }
        catch { draftSaveError = "Draft was not saved: \(Self.message(for: error))" }
        return ReferenceAuthoringWorkerUpdate(state: makeState(), errorMessage: errorMessage ?? draftSaveError)
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

@MainActor
final class ReferenceAuthoringViewModel: ObservableObject {
    let mediaReview: ReferenceFinalizedMediaReviewController
    private let beatPreviewEngine: any PracticeBeatPlaybackEngine
    private var mediaReviewObservation: AnyCancellable?
    @Published private(set) var isPreviewingBeat = false
    @Published private(set) var state: ReferenceAuthoringViewState
    @Published private(set) var visibleMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isPreflightPolling = false
    @Published private(set) var isCalibrationPolling = false
    @Published private(set) var approvedPackageURL: URL?
    @Published private(set) var isExportingApprovedPackage = false
    @Published private(set) var navigationRequest: ReferenceAuthoringNavigationRequest?

    /// Identifies the one transient operation whose wording must be distinct
    /// from the session's persistent `.configuring` workflow phase. Mutated
    /// immediately before `isWorking`, so that property's publication also
    /// refreshes `workflowStatusText` without a second published source.
    private var isApplyingSetup = false

    @Published var selectedTechnique: ReferenceTechnique?
    @Published var patternID = ""
    @Published var patternName = ""
    @Published var phraseBars = 1
    @Published var capturePurpose: ReferenceCapturePurpose = .canonicalReference {
        didSet { if capturePurpose != oldValue { stopBeatPreview() } }
    }
    @Published var bpm = 95 {
        didSet { if bpm != oldValue { stopBeatPreview() } }
    }
    @Published var beatEngineMode: BeatEngineMode = .boomBapTrainer {
        didSet { if beatEngineMode != oldValue { stopBeatPreview() } }
    }
    @Published var startingDirectionRawValue = ""
    @Published var faderVariantRawValue = ""
    @Published var handednessRawValue = CaptureSessionHandedness.right.rawValue
    /// Normal RANE right-deck orientation: left rail silent, rightward throw audible.
    @Published var crossfaderOpenEndRawValue = CrossfaderOpenEnd.right.rawValue
    @Published var activeDeckRawValue = CrossfaderActiveDeck.rightDeck.rawValue
    @Published var notes = ""
    @Published var reviewNotes = "" {
        didSet { if reviewNotes != oldValue { scheduleReviewNotesSave() } }
    }
    private var reviewNotesSaveTask: Task<Void, Never>?

    /// The last values `refreshAutofilledPatternIdentity()` wrote.
    ///
    /// Autofill replaces a field only when it is empty or still holds the
    /// value autofill itself put there. Once CXL types their own pattern
    /// identity it is never overwritten by a later technique or phrase-length
    /// change — the identity is meant to be stable and operator-owned.
    private var lastAutofilledPatternID = ""
    private var lastAutofilledPatternName = ""

    private let worker: ReferenceAuthoringWorker
    private var preflightPollingTask: Task<Void, Never>?
    private var calibrationPollingTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var watchEvidenceTask: Task<Void, Never>?

    /// How long to keep waiting for a Watch motion transfer that acknowledged
    /// and stopped cleanly. Bounded: a transfer that never lands must become a
    /// visible failed state, not an indefinite spinner.
    static let watchTransferWaitTimeout: TimeInterval = 90
    static let watchTransferPollInterval: UInt64 = 2_000_000_000

    /// `true` while a bounded wait for the Watch motion transfer is running.
    @Published private(set) var isWaitingForWatchTransfer = false

    /// Why `Approve Canonical Draft` is unavailable, or `nil` when it is.
    ///
    /// Reads the session's own `approvalBlockReason` — the same predicate the
    /// domain method enforces — plus this screen's transient-work state. The
    /// button being disabled is a courtesy; the domain method is the boundary.
    var approvalBlockReason: String? {
        if draftSaveError != nil { return "Save the current review successfully before approving." }
        if isWorking { return "An operation is still running." }
        if isWaitingForWatchTransfer { return "Waiting for the Apple Watch motion transfer to complete." }
        switch mediaReview.state {
        case .loading: return "Finalized media is still loading."
        case .missingAudio: return "The finalized WAV is missing."
        case .unreadableMedia(let file): return "Finalized media is unreadable: \(file)."
        case .durationMismatch: return "The finalized WAV and MOV durations do not match."
        case .synchronizationUnavailable(let detail): return detail
        case .ready, .playing, .stopped, .missingVideo: break
        case .playingTake: break
        }
        if let issue = mediaReview.beatBindingIssue { return issue }
        return session.approvalBlockReason()
    }

    /// Keep partial validation and the playback/beat gate visible together.
    var approvalBlockReasons: [String] {
        var seen = Set<String>()
        return [session.approvalBlockReason(), approvalBlockReason, mediaReview.beatBindingIssue]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    var canEditReviewedTake: Bool { session.takeInReview != nil && !isWorking }

    var canApprove: Bool { approvalBlockReason == nil }

    var savedDrafts: [ReferenceSavedDraftSummary] { state.savedDrafts }
    var draftSaveError: String? { state.draftSaveError }
    var draftLibraryError: String? { state.draftLibraryError }
    var isReviewingSavedDraft: Bool { state.reviewingSavedDraft }
    var canOpenSavedDraft: Bool {
        !isWorking && !isExportingApprovedPackage && !isPreparingRawCaptureExport
            && !isWaitingForWatchTransfer && session.phase != .recording
    }

    func refreshSavedDrafts() async { apply(await worker.refreshSavedDrafts()) }

    private func scheduleReviewNotesSave() {
        guard !isWorking, let takeID = reviewedTake?.id else { return }
        reviewNotesSaveTask?.cancel()
        let notes = reviewNotes
        reviewNotesSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            let update = await worker.saveDraft(reviewNotes: notes, expectedTakeID: takeID)
            guard !Task.isCancelled else { return }
            apply(update)
        }
    }

    func saveDraftForLater() {
        guard canOpenSavedDraft, reviewedTake != nil else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.saveDraft(reviewNotes: reviewNotes)
            apply(update)
            visibleMessage = update.errorMessage ?? "Draft saved on this Mac. Reopen it from Saved drafts to continue reviewing."
            isWorking = false
        }
    }

    func reopenDraft(_ id: String) {
        guard canOpenSavedDraft else { return }
        isWorking = true
        stopBeatPreview()
        mediaReview.stop()
        cancelWatchTransferWait()
        Task { [weak self] in
            guard let self else { return }
            _ = await worker.saveDraft(reviewNotes: reviewNotes)
            let update = await worker.reopenDraft(id: id)
            apply(update)
            if update.errorMessage == nil, let take = reviewedTake {
                reviewNotes = state.savedReviewNotes
                tearReviewNotes = take.tearReview.notes
                approvedPackageURL = nil
                mediaReview.load(take: take, mediaURL: lastFinalizedRecordingURL, beatRootURL: nil)
                visibleMessage = "Saved draft reopened. Review it and select a repetition when ready."
                navigationRequest = .init(destination: .review)
            }
            isWorking = false
            startWatchTransferWaitIfPending()
        }
    }

    func continuationBlockReason(newScratch: Bool, isExportPreparing: Bool = false) -> String? {
        if isWorking || isExportingApprovedPackage || isExportPreparing {
            return "Wait for the current operation to finish."
        }
        if isWaitingForWatchTransfer { return "Wait for the Watch motion transfer to finish." }
        if draftSaveError != nil { return "Save the current draft successfully before moving on." }
        if isReviewingSavedDraft {
            return newScratch ? nil : "Choose New scratch to return to recording."
        }
        return newScratch ? session.newScratchSetupBlockReason() : session.retakeBlockReason()
    }

    var canRejectReviewedTake: Bool {
        canEditReviewedTake && !isWaitingForWatchTransfer
            && reviewedTake?.evidence.watchEvidence.isTransferPending != true
            && reviewedTake?.evidence.metadata.sourceState?.isTerminal != false
    }

    var approvedPackageExportBlockReason: String? {
        if isWorking || isExportingApprovedPackage { return "Wait for the current operation to finish." }
        guard let take = reviewedTake else { return "No finalized take is available." }
        guard take.evidence.metadata.lifecycleState == .approvedCanonical,
              take.evidence.metadata.reviewDecision?.outcome == .approved else {
            return "Approve one selected repetition before exporting a reference package."
        }
        guard take.latestValidation.passes else { return "The approved take no longer passes validation." }
        guard lastFinalizedRecordingURL != nil else { return "The finalized capture file is unavailable." }
        return nil
    }

    func nextTakeBlockReason(isExportPreparing: Bool) -> String? {
        if isReviewingSavedDraft { return "Choose New scratch to return to recording." }
        if draftSaveError != nil { return "Save the current draft successfully before moving on." }
        if isWorking { return "Wait for the current operation to finish." }
        if isWaitingForWatchTransfer {
            return "Wait for the Apple Watch motion transfer to complete."
        }
        if isExportPreparing { return "Wait for the capture export to finish." }
        guard session.canPrepareNextTake else {
            return "Approve the current draft before preparing another take."
        }
        return nil
    }

    init(
        engine: MacCaptureEngine,
        companionReceiver: CompanionCameraReceiver?,
        operatorName: String,
        beatPreviewEngine: any PracticeBeatPlaybackEngine = ScratchLabBeatEngine()
    ) {
        self.mediaReview = ReferenceFinalizedMediaReviewController()
        self.beatPreviewEngine = beatPreviewEngine
        let session = ReferenceAuthoringSession(
            authoringSessionID: "reference-\(UUID().uuidString.lowercased())",
            operatorName: operatorName
        )
        let bridge = ReferenceAuthoringCaptureBridge(
            engine: engine,
            companionReceiver: companionReceiver
        )
        self.worker = ReferenceAuthoringWorker(
            session: session,
            driver: ReferenceAuthoringWorkerDriver(bridge: bridge, engine: engine),
            calibrationStore: engine.crossfaderCalibrationStore,
            draftStore: ReferenceDraftStore(directory: ReferenceDraftStore.defaultDirectory)
        )
        self.state = ReferenceAuthoringViewState(
            session: session,
            latestCalibrationRawValue: nil
        )
        observeMediaReview()
    }

    init(worker: ReferenceAuthoringWorker, initialState: ReferenceAuthoringViewState,
         beatPreviewEngine: any PracticeBeatPlaybackEngine = ScratchLabBeatEngine()) {
        self.mediaReview = ReferenceFinalizedMediaReviewController()
        self.beatPreviewEngine = beatPreviewEngine
        self.worker = worker
        self.state = initialState
        let applied = initialState.session
        selectedTechnique = applied.selectedTechnique
        patternID = applied.selectedPattern?.id ?? ""
        patternName = applied.selectedPattern?.name ?? ""
        phraseBars = applied.selectedPattern?.phraseBars ?? 1
        bpm = applied.selectedBPM ?? 95
        beatEngineMode = applied.selectedBeatEngineMode
        capturePurpose = applied.selectedCapturePurpose
        startingDirectionRawValue = applied.selectedStartingDirection?.rawValue ?? ""
        faderVariantRawValue = applied.selectedFaderVariant?.rawValue ?? ""
        handednessRawValue = applied.selectedHandedness.rawValue
        notes = applied.notes
        observeMediaReview()
    }

    private func observeMediaReview() {
        mediaReviewObservation = mediaReview.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var session: ReferenceAuthoringSession { state.session }

    var reviewedTake: ReferenceAuthoringTake? {
        session.takeInReview ?? session.takes.last
    }

    var workflowStatusText: String {
        Self.workflowStatusText(
            phase: session.phase,
            configurationIsComplete: session.configurationIsComplete,
            isApplyingSetup: isApplyingSetup && isWorking
        )
    }

    /// Pure presentation mapping. `.configuring` is a persistent workflow
    /// phase, not evidence that Apply Setup is still running.
    static func workflowStatusText(
        phase: ReferenceAuthoringPhase,
        configurationIsComplete: Bool,
        isApplyingSetup: Bool
    ) -> String {
        if isApplyingSetup {
            return "Applying setup…"
        }
        switch phase {
        case .configuring:
            return configurationIsComplete
                ? "Setup applied — calibrate crossfader"
                : "Setup required"
        case .calibrating:
            return "Calibrating"
        case .readyToRecord:
            return "Ready to record"
        case .recording:
            return "Recording"
        case .reviewing:
            return "Reviewing"
        case .complete:
            return "Approved draft"
        }
    }

    // MARK: - Pattern identity autofill

    /// Stable pattern token derived from the technique and phrase length.
    ///
    /// `ReferenceTechnique.id` is the persisted scratch-type token (e.g.
    /// `baby_scratch`), not a display string, so this stays stable across
    /// releases and localisations. BPM is deliberately NOT part of it: the
    /// same pattern performed at a different tempo is the same pattern.
    static func autofilledPatternID(technique: ReferenceTechnique, phraseBars: Int) -> String {
        "\(technique.id)_\(max(1, phraseBars))bar"
    }

    /// Human-facing name for the same pattern.
    static func autofilledPatternName(technique: ReferenceTechnique, phraseBars: Int) -> String {
        let bars = max(1, phraseBars)
        return "\(technique.displayName) · \(bars) bar\(bars == 1 ? "" : "s")"
    }

    /// Fill the pattern identity from the current technique and phrase length,
    /// without ever clobbering an operator-authored value.
    func refreshAutofilledPatternIdentity() {
        guard let technique = selectedTechnique else { return }
        let id = Self.autofilledPatternID(technique: technique, phraseBars: phraseBars)
        let name = Self.autofilledPatternName(technique: technique, phraseBars: phraseBars)
        if patternID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || patternID == lastAutofilledPatternID {
            patternID = id
        }
        if patternName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || patternName == lastAutofilledPatternName {
            patternName = name
        }
        // Tracked whether or not the fields were replaced, so a field CXL has
        // taken ownership of stays theirs on every later change.
        lastAutofilledPatternID = id
        lastAutofilledPatternName = name
    }

    func applySetup() {
        stopBeatPreview()
        visibleMessage = nil
        guard let technique = selectedTechnique else {
            visibleMessage = "Select an authorable technique. Flare references must name an explicit click count."
            return
        }
        let trimmedPatternID = patternID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPatternName = patternName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPatternID.isEmpty, !trimmedPatternName.isEmpty else {
            visibleMessage = "Enter both a stable pattern ID and a pattern name."
            return
        }
        guard CaptureClickTrackDefaults.supportedBPMRange.contains(bpm) else {
            visibleMessage = "BPM must be inside ScratchLab's supported click-track range."
            return
        }
        guard let startingDirection = ReferenceStartingPlatterDirection(rawValue: startingDirectionRawValue),
              let faderVariant = ReferenceFaderVariant(rawValue: faderVariantRawValue),
              let handedness = CaptureSessionHandedness(rawValue: handednessRawValue) else {
            visibleMessage = "Select direction, handedness and fader variant before continuing."
            return
        }

        isApplyingSetup = true
        isWorking = true
        let pattern = ReferencePatternIdentity(
            id: trimmedPatternID,
            name: trimmedPatternName,
            phraseBars: phraseBars
        )
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.configure(
                technique: technique,
                pattern: pattern,
                bpm: bpm,
                startingDirection: startingDirection,
                faderVariant: faderVariant,
                handedness: handedness,
                notes: notes,
                beatEngineMode: beatEngineMode,
                capturePurpose: capturePurpose
            )
            apply(update)
            visibleMessage = update.errorMessage ?? "Authoring setup applied."
            isApplyingSetup = false
            isWorking = false
            // A valid stored calibration for exactly this fader is already the
            // answer. Adopting it here is what stops the operator being asked
            // to re-sweep Ch16 CC8 every time this screen is opened.
            adoptPersistedCalibrationIfAvailable()
        }
    }

    func refreshPreflightOnce() async {
        let update = await worker.refreshPreflight()
        apply(update)
    }

    // MARK: - Crossfader setup reuse

    /// `true` while the session is holding a calibration it adopted from disk
    /// rather than one swept in this session.
    var isReusingPersistedCalibration: Bool {
        session.confirmedCalibrationSource?.isReused ?? false
    }

    var calibrationSourceSummary: String? {
        session.confirmedCalibrationSource?.displayName
    }

    /// Adopt an exactly-matching stored calibration for the currently selected
    /// device/address/deck/open-end, so the operator is not asked to re-sweep
    /// a fader ScratchLab has already measured.
    ///
    /// Called automatically once setup is applied and whenever the screen
    /// appears. It is a no-op when a calibration is already held, when a sweep
    /// is running, or when nothing on disk matches exactly. The explicit
    /// `Recalibrate Crossfader` action remains the way to measure again.
    func adoptPersistedCalibrationIfAvailable(announce: Bool = false) {
        guard session.confirmedCalibration == nil else { return }
        guard let openEnd = CrossfaderOpenEnd(rawValue: crossfaderOpenEndRawValue),
              let activeDeck = CrossfaderActiveDeck(rawValue: activeDeckRawValue) else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await worker.adoptPersistedCalibration(
                openEnd: openEnd,
                activeDeck: activeDeck
            )
            apply(result.update)
            if case .adopted = result.outcome {
                visibleMessage = result.outcome.operatorSummary
                    + " No new sweep is needed. Use Recalibrate Crossfader to measure it again."
            } else if announce {
                visibleMessage = result.outcome.operatorSummary
            }
        }
    }

    /// Explicit operator-initiated re-measurement. Discards the adopted
    /// calibration and starts a fresh sweep.
    func recalibrateCrossfader() {
        beginCalibration()
    }

    // MARK: - Raw diagnostic export

    /// Why the raw capture cannot be exported right now, or `nil`.
    ///
    /// Deliberately independent of `approvalBlockReason`: repetition
    /// selection, crossfader calibration, tear-review corrections and
    /// canonical approval have no bearing on whether the recorded files can be
    /// copied off this machine.
    var rawCaptureExportBlockReason: String? {
        if isWorking { return "An operation is still running." }
        if let reason = session.rawCaptureExportBlockReason() { return reason }
        guard lastFinalizedRecordingURL != nil else {
            return "This session has not finalized a capture on disk yet."
        }
        return nil
    }

    var canExportRawCapture: Bool { rawCaptureExportBlockReason == nil }

    @Published private(set) var rawCaptureExportError: String?
    @Published private(set) var isPreparingRawCaptureExport = false

    /// The finalized media URL of the raw capture this session produced.
    var lastFinalizedRecordingURL: URL? { state.finalizedMediaURL }

    /// The export source for the raw diagnostic capture, or `nil` when there
    /// is nothing stable to export. Reuses the existing session-archive
    /// pipeline; this screen builds no second archive format.
    func rawCaptureExportSource(config: CaptureSessionConfig?) async -> SessionExportSource? {
        rawCaptureExportError = nil
        guard canExportRawCapture else {
            rawCaptureExportError = rawCaptureExportBlockReason
            return nil
        }
        isWorking = true
        isPreparingRawCaptureExport = true
        defer {
            isWorking = false
            isPreparingRawCaptureExport = false
        }
        do {
            guard let snapshot = try await worker.rawCaptureExportSnapshot(config: config) else {
                rawCaptureExportError = "The finalized capture is no longer available for export."
                return nil
            }
            if !snapshot.excludedReferenceTakeIDs.isEmpty {
                visibleMessage = "Earlier authoring takes belong to another capture export group and remain in the session: "
                    + snapshot.excludedReferenceTakeIDs.joined(separator: ", ")
            }
            return snapshot.source
        } catch {
            rawCaptureExportError = SessionExportFailureText.issue(for: error, while: "preparing the capture")
            visibleMessage = rawCaptureExportError
            return nil
        }
    }

    /// Existing-take restore seam; no import flow or lifecycle transition.
    func restoreTearEvidence(_ data: Data?) async -> ReferenceTearEvidenceCodec.ReadResult? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        let restored = await worker.restoreTearEvidence(data)
        apply(restored.update)
        visibleMessage = restored.update.errorMessage
        return restored.result
    }

    static let rawCaptureExportSessionName = "Reference Authoring Capture"

    /// Stated wherever export is offered. Exporting is not approval,
    /// publication, installation or training eligibility.
    static let rawCaptureExportDisclaimer =
        "Saving the capture copies recorded files and available tear review evidence. It does not approve, publish, "
            + "install, or make any reference eligible for training."

    // MARK: - Canonical tear notation

    /// Stored canonical output remains authoritative after restore. A later
    /// semantic correction resumes the current projector used by live review.
    var reviewTearProjection: ReferenceTearCanonicalProjection? {
        reviewedTake?.tearProjection
    }

    #if DEBUG
    // Selection and alignment belong to this preview, never to capture or approval.
    @Published private(set) var tearComparisonTargetID: String?
    @Published private(set) var tearComparisonStartID: String?
    @Published private(set) var tearComparisonEndID: String?
    @Published private(set) var tearComparisonOriginSeconds: Double?

    var tearComparisonTargets: [ScratchNotation.TearTemplate] {
        ScratchNotation.internalCanonicalTearTemplates
    }

    var tearComparisonCandidates: [ReferenceTearCandidate] { tearReview?.candidates ?? [] }

    /// Captured tempo, independent of the editable setup for a later take.
    var tearComparisonBPM: Double? { reviewedTake.map { Double($0.evidence.metadata.bpm) } }

    var tearComparisonEndCandidates: [ReferenceTearCandidate] {
        guard let start = tearComparisonCandidates.firstIndex(where: { $0.id == tearComparisonStartID }) else {
            return []
        }
        return Array(tearComparisonCandidates[start...])
    }

    var tearComparisonSelectedCandidates: [ReferenceTearCandidate] {
        let candidates = tearComparisonCandidates
        guard let start = candidates.firstIndex(where: { $0.id == tearComparisonStartID }),
              let end = candidates.firstIndex(where: { $0.id == tearComparisonEndID }), end >= start else {
            return []
        }
        // Keep every intervening gesture, including a contrary direction or unknown evidence.
        return Array(candidates[start...end])
    }

    var tearComparisonBlockReason: String? {
        guard !isWorking else { return "Wait for the current operation to finish." }
        guard case .reviewing = session.phase, reviewedTake != nil else { return "Choose a finalized take under review." }
        guard tearComparisonTargets.contains(where: { $0.id == tearComparisonTargetID }) else {
            return "Choose an authored target explicitly."
        }
        guard !tearComparisonSelectedCandidates.isEmpty else { return "Choose a performed gesture or consecutive gesture range." }
        return nil
    }

    func selectTearComparisonTarget(_ id: String?) {
        tearComparisonTargetID = tearComparisonTargets.contains { $0.id == id } ? id : nil
        tearComparisonOriginSeconds = nil
    }

    func selectTearComparisonStart(_ id: String?) {
        tearComparisonStartID = tearComparisonCandidates.contains { $0.id == id } ? id : nil
        // Selecting a start explicitly selects that single gesture; extending it is a separate choice.
        tearComparisonEndID = tearComparisonStartID
        tearComparisonOriginSeconds = nil
    }

    func selectTearComparisonEnd(_ id: String?) {
        tearComparisonEndID = tearComparisonEndCandidates.contains { $0.id == id } ? id : nil
        tearComparisonOriginSeconds = nil
    }

    func compareSelectedTear() {
        guard tearComparisonBlockReason == nil else { return }
        tearComparisonOriginSeconds = tearComparisonSelectedCandidates.first?.span.startTime
    }

    /// Recomputed from the current immutable review. No cached capture or corrected record can survive a refresh.
    var tearComparisonResult: CanonicalTearComparison.Result? {
        guard tearComparisonBlockReason == nil,
              let origin = tearComparisonOriginSeconds,
              let targetID = tearComparisonTargetID,
              let targets = ScratchNotation.internalCanonicalGestureRecords(forTemplateID: targetID),
              let projection = reviewTearProjection, let review = tearReview,
              let capturedBPM = tearComparisonBPM else { return nil }
        let candidates = tearComparisonSelectedCandidates
        let records = candidates.compactMap { candidate in projection.records.first { $0.id == candidate.id } }
        guard records.count == candidates.count else { return nil }
        let intrinsic = reviewedTake?.tearPerformedLimitations ?? [:]
        let limitations = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { index, candidate in
            var reasons = intrinsic[candidate.id] ?? []
            // Include both adjacent inter-gesture intervals. They are not separate projected
            // records, but packet loss or a clock break must not disappear when selecting a phrase.
            let lower = index > 0 ? candidates[index - 1].span.endTime : candidate.span.startTime
            let upper = index + 1 < candidates.count ? candidates[index + 1].span.startTime : candidate.span.endTime
            if review.hasInterruptedEvidence(
                in: ReferenceTearTimeSpan(startTime: lower, endTime: upper)
            ), !reasons.contains(.unknownEvidence) {
                reasons.append(.unknownEvidence)
            }
            return (candidate.id, reasons)
        })
        return CanonicalTearComparison.compare(
            target: targets, performed: records, bpm: capturedBPM,
            performedOriginSeconds: origin, performedLimitations: limitations
        )
    }

    static func tearComparisonTargetTitle(_ target: ScratchNotation.TearTemplate) -> String {
        let ratio = target.subdivisionRatio.map { String(format: "%g", $0) }.joined(separator: ":")
        return "\(target.holdCount)-tear · \(target.form.rawValue) · \(ratio)"
    }

    static var tearComparisonToleranceText: String {
        let configuration = CanonicalTearComparison.Configuration.internalReview
        return String(format: "Provisional tolerances: hold/fader timing ±%.0f ms; moving-duration share ±%.0f percentage points. Minimum motion confidence: %.2f.",
                      configuration.timingToleranceMilliseconds, configuration.ratioShareTolerance * 100,
                      configuration.minimumMotionConfidence)
    }

    static func tearComparisonCandidateTitle(_ candidate: ReferenceTearCandidate) -> String {
        String(format: "Gesture %d · %@ · %.3f–%.3f s", candidate.gestureIndex + 1,
               candidate.direction.rawValue, candidate.span.startTime, candidate.span.endTime)
    }

    private func resetTearComparison() {
        tearComparisonTargetID = nil
        tearComparisonStartID = nil
        tearComparisonEndID = nil
        tearComparisonOriginSeconds = nil
    }
    #endif

    /// Shared time/position frame for a canonical chart.
    ///
    /// Returns `nil` when the projection placed nothing — the chart then shows
    /// its explicit empty state rather than an invented axis.
    static func canonicalFrame(
        for projection: ReferenceTearCanonicalProjection,
        bpm: Double
    ) -> ScratchStrokeGeometry.CanonicalFrame? {
        guard let timeRange = projection.timeRange else { return nil }
        // A single flat gesture has no vertical extent of its own. Padding the
        // AXIS is presentation framing and changes no measured value; the
        // curve points and hold positions are drawn exactly as measured.
        let positionRange = projection.positionRange ?? -0.5...0.5
        return ScratchStrokeGeometry.CanonicalFrame(
            timeRange: timeRange,
            positionRange: positionRange,
            coordinateSpace: projection.coordinateSpace,
            beatsPerMinute: bpm > 0 ? bpm : 90
        )
    }

    func startPreflightPolling(intervalNanoseconds: UInt64 = 250_000_000) {
        cancelPreflightPolling()
        isPreflightPolling = true
        preflightPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let update = await worker.refreshPreflight()
                guard !Task.isCancelled else { break }
                apply(update)
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func cancelPreflightPolling() {
        preflightPollingTask?.cancel()
        preflightPollingTask = nil
        isPreflightPolling = false
    }

    func beginCalibration() {
        visibleMessage = nil
        guard let openEnd = CrossfaderOpenEnd(rawValue: crossfaderOpenEndRawValue),
              let activeDeck = CrossfaderActiveDeck(rawValue: activeDeckRawValue) else {
            visibleMessage = "Select the active deck and the crossfader's open end."
            return
        }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.beginCalibration(openEnd: openEnd, activeDeck: activeDeck)
            apply(update)
            isWorking = false
            if let error = update.errorMessage {
                visibleMessage = error
            } else {
                visibleMessage = "Calibration sweep started. Hold each requested position until it settles."
                startCalibrationPolling()
            }
        }
    }

    func startCalibrationPolling(intervalNanoseconds: UInt64 = 20_000_000) {
        cancelCalibrationPolling()
        isCalibrationPolling = true
        calibrationPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let update = await worker.ingestLatestCalibrationSample()
                guard !Task.isCancelled else { break }
                apply(update)
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func cancelCalibrationPolling() {
        calibrationPollingTask?.cancel()
        calibrationPollingTask = nil
        isCalibrationPolling = false
    }

    func retryCalibrationStep() {
        Task { [weak self] in
            guard let self else { return }
            apply(await worker.retryCalibrationStep())
            visibleMessage = "Position discarded. Present that position again, then press its Capture button."
        }
    }

    /// The operator's explicit capture boundary for the current stage.
    func armCalibrationCapture() {
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.armCalibrationCapture()
            apply(update)
            if let step = state.session.calibrationSweep?.state.currentStep {
                visibleMessage = "Capturing \(step.displayName). Hold the fader still."
            }
        }
    }

    func commitCalibration() {
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.commitCalibration()
            apply(update)
            isWorking = false
            if let error = update.errorMessage {
                visibleMessage = error
            } else {
                cancelCalibrationPolling()
                visibleMessage = "Crossfader calibration saved."
            }
        }
    }

    func startRecording() {
        guard !isWorking else { return }
        stopBeatPreview()
        mediaReview.stop()
        guard session.selectedTechnique == selectedTechnique,
              session.selectedPattern?.id == patternID.trimmingCharacters(in: .whitespacesAndNewlines),
              session.selectedPattern?.name == patternName.trimmingCharacters(in: .whitespacesAndNewlines),
              session.selectedPattern?.phraseBars == phraseBars,
              session.selectedBPM == bpm,
              session.selectedBeatEngineMode == beatEngineMode,
              session.selectedCapturePurpose == capturePurpose,
              session.selectedStartingDirection?.rawValue == startingDirectionRawValue,
              session.selectedFaderVariant?.rawValue == faderVariantRawValue,
              session.selectedHandedness.rawValue == handednessRawValue,
              session.notes == notes else {
            visibleMessage = "Apply Authoring Setup after changing the capture settings."
            return
        }
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.startRecording()
            apply(update)
            visibleMessage = update.errorMessage ?? (session.selectedCapturePurpose == .movementCheck
                ? "Recording started. Perform one slow movement, then press Stop and Finalize."
                : "Recording started. Perform the same phrase four times.")
            isWorking = false
            // An engine stop can arrive before the async start update reaches
            // this view model. Reconcile the bridge's exact active token so a
            // dropped UI edge cannot leave a completed take stuck recording.
            if update.errorMessage == nil, await worker.currentRecordingHasStopped() {
                captureRecordingDidStop()
            }
        }
    }

    func stopRecording() {
        guard session.phase == .recording, !isWorking else { return }
        visibleMessage = nil
        isWorking = true
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            let update = await worker.stopRecording()
            guard !Task.isCancelled else { return }
            apply(update)
            if let take = reviewedTake {
                let beatRoot = ProcessInfo.processInfo.environment["CXL_BEAT_PILOT_ROOT"]
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                mediaReview.load(
                    take: take,
                    mediaURL: lastFinalizedRecordingURL,
                    beatRootURL: beatRoot
                )
            }
            visibleMessage = update.errorMessage ?? "Take finalized. Review all evidence and validation findings."
            isWorking = false
            finalizationTask = nil
            startWatchTransferWaitIfPending()
        }
    }

    /// The capture engine owns the timed stop. This only brings its completed
    /// take through the same serial finalization/review path as manual Stop.
    func captureRecordingDidStop() {
        guard session.phase == .recording, !isWorking else { return }
        stopRecording()
    }

    /// Wait, bounded and cancellably, for this take's Watch motion transfer.
    ///
    /// Only starts when the finalized take actually says the transfer is
    /// pending — an acknowledged Watch whose file has not arrived yet. Every
    /// other state is terminal and needs no wait. The poll itself runs on the
    /// serial worker (never the main actor); only the resulting state is
    /// published here.
    func startWatchTransferWaitIfPending() {
        cancelWatchTransferWait()
        guard reviewedTake?.evidence.watchEvidence.isTransferPending == true else { return }
        isWaitingForWatchTransfer = true
        watchEvidenceTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.watchTransferWaitTimeout)
            while !Task.isCancelled, Date() < deadline {
                let result = await worker.refreshWatchEvidenceOnce()
                guard !Task.isCancelled else { break }
                apply(result.update)
                if result.isTerminal {
                    isWaitingForWatchTransfer = false
                    watchEvidenceTask = nil
                    if reviewedTake?.evidence.watchEvidence.isLinked == true {
                        visibleMessage = "Apple Watch motion linked to this take."
                    }
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: Self.watchTransferPollInterval)
                } catch {
                    break
                }
            }
            guard !Task.isCancelled else { return }
            isWaitingForWatchTransfer = false
            watchEvidenceTask = nil
            // Timed out. The take keeps its truthful pending state and stays
            // un-approvable; nothing is marked linked.
            if reviewedTake?.evidence.watchEvidence.isTransferPending == true {
                visibleMessage = "Apple Watch motion did not finish transferring within "
                    + "\(Int(Self.watchTransferWaitTimeout))s. This take cannot be approved without it."
            }
        }
    }

    func cancelWatchTransferWait() {
        watchEvidenceTask?.cancel()
        watchEvidenceTask = nil
        isWaitingForWatchTransfer = false
    }

    func adjustRepetitionBoundary(index: Int, startBeat: Double, endBeat: Double) {
        Task { [weak self] in
            guard let self else { return }
            apply(await worker.adjustRepetitionBoundary(
                repetitionIndex: index,
                startBeat: startBeat,
                endBeat: endBeat
            ))
        }
    }

    func selectRepetitionForApproval(_ index: Int) {
        Task { [weak self] in
            guard let self else { return }
            apply(await worker.selectRepetitionForApproval(index))
        }
    }

    func rejectTake() {
        guard canRejectReviewedTake else { return }
        isWorking = true
        mediaReview.stop()
        visibleMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.rejectTake(notes: reviewNotes)
            apply(update)
            if update.errorMessage == nil {
                reviewNotes = ""
                tearReviewNotes = ""
            }
            visibleMessage = update.errorMessage ?? (isReviewingSavedDraft
                ? "Take rejected. Choose New scratch to return to recording."
                : "Take rejected. Ready to record a new take.")
            isWorking = false
        }
    }

    func retake(isExportPreparing: Bool = false) {
        if let reason = continuationBlockReason(newScratch: false, isExportPreparing: isExportPreparing) {
            visibleMessage = reason
            return
        }
        guard let takeID = session.latestRecordedTake?.id else { return }
        stopBeatPreview()
        mediaReview.stop()
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            _ = await worker.saveDraft(reviewNotes: reviewNotes, expectedTakeID: takeID)
            let update = await worker.retake(afterTakeID: takeID)
            apply(update)
            visibleMessage = update.errorMessage ?? "Ready for a retake. The prior draft evidence remains retained."
            if update.errorMessage == nil {
                reviewNotes = ""
                tearReviewNotes = ""
                navigationRequest = .init(destination: .capture)
            }
            isWorking = false
        }
    }

    func prepareNewScratch(isExportPreparing: Bool = false) {
        if let reason = continuationBlockReason(newScratch: true, isExportPreparing: isExportPreparing) {
            visibleMessage = reason
            return
        }
        guard let takeID = session.latestRecordedTake?.id else { return }
        stopBeatPreview()
        mediaReview.stop()
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            _ = await worker.saveDraft(reviewNotes: reviewNotes, expectedTakeID: takeID)
            let update = await worker.prepareNewScratchSetup(afterTakeID: takeID)
            apply(update)
            if update.errorMessage == nil {
                selectedTechnique = nil
                patternID = ""
                patternName = ""
                lastAutofilledPatternID = ""
                lastAutofilledPatternName = ""
                startingDirectionRawValue = ""
                faderVariantRawValue = ""
                notes = ""
                reviewNotes = ""
                tearReviewNotes = ""
                visibleMessage = "Previous takes retained. Choose the next scratch and apply its setup."
                navigationRequest = .init(destination: .setup)
            } else { visibleMessage = update.errorMessage }
            isWorking = false
        }
    }

    func approveCanonical() {
        if let reason = approvalBlockReason {
            visibleMessage = reason
            return
        }
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.approveCanonical(notes: reviewNotes)
            apply(update)
            visibleMessage = update.errorMessage ?? "Approved canonical draft. Not installed for training."
            isWorking = false
        }
    }

    func exportApprovedPackage(to parentDirectory: URL) {
        visibleMessage = nil
        if let reason = approvedPackageExportBlockReason {
            visibleMessage = reason
            return
        }
        guard let take = reviewedTake, let mediaURL = lastFinalizedRecordingURL else { return }
        isExportingApprovedPackage = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let verified = try await worker.verifiedTakeForExport()
                guard verified.id == take.id else { throw ReferenceAuthoringError.noActiveRecording }
                let packageURL = try await Task.detached(priority: .userInitiated) {
                    try ReferenceApprovedPackageCoordinator.export(
                        take: verified, finalizedMediaURL: mediaURL, parentDirectory: parentDirectory
                    )
                }.value
                approvedPackageURL = packageURL
                visibleMessage = "Approved package exported: \(packageURL.lastPathComponent)."
            } catch {
                visibleMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isExportingApprovedPackage = false
        }
    }

    func reopenLastApprovedPackage() {
        visibleMessage = nil
        guard let packageURL = approvedPackageURL else {
            visibleMessage = "Export an approved package before reopening it."
            return
        }
        isExportingApprovedPackage = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await Task.detached(priority: .userInitiated) {
                    let secondRoot = FileManager.default.temporaryDirectory
                        .appendingPathComponent("reference-package-reopen-\(UUID().uuidString)", isDirectory: true)
                    return try ReferenceApprovedPackageCoordinator.copyAndReopen(
                        packageURL: packageURL, secondRoot: secondRoot
                    )
                }.value
                visibleMessage = "Reopened and rehashed \(manifest.artifacts.count) package artifacts."
            } catch {
                visibleMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isExportingApprovedPackage = false
        }
    }

    /// Preserve the approved draft and return to ready. Recording remains a
    /// separate explicit action through `startRecording()`.
    func prepareNextTake(isExportPreparing: Bool) {
        mediaReview.stop()
        visibleMessage = nil
        if let reason = nextTakeBlockReason(isExportPreparing: isExportPreparing) {
            visibleMessage = reason
            return
        }
        guard let expectedTakeID = session.latestRecordedTake?.id else {
            visibleMessage = "Approve the current draft before preparing another take."
            return
        }

        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.prepareNextTake(afterApprovedTakeID: expectedTakeID)
            apply(update)
            if update.errorMessage == nil {
                reviewNotes = ""
                tearReviewNotes = ""
                visibleMessage = "Approved take \(expectedTakeID) retained. Ready for the next take; press Record Draft when ready."
            } else {
                visibleMessage = update.errorMessage
            }
            isWorking = false
        }
    }

    // MARK: - Tear segmentation review

    /// Notes carried on the NEXT tear correction, and committed as the
    /// review's own notes by `commitTearReviewNotes()`.
    @Published var tearReviewNotes = ""

    /// The tear review for the take on screen, or `nil` when there is none.
    /// Read-only: every change goes through the worker.
    var tearReview: ReferenceTearSegmentationReview? { reviewedTake?.tearReview }

    /// Why the tear review cannot be corrected right now, or `nil`.
    ///
    /// Deliberately says nothing about approval: correcting a tear review has
    /// never been able to approve a take, and this screen must not imply that
    /// finishing it will.
    var tearReviewBlockReason: String? {
        if isWorking { return "An operation is still running." }
        guard reviewedTake != nil else { return "No take is under review." }
        guard case .reviewing = session.phase else {
            return "This take is no longer under review, so its tear segmentation is read-only."
        }
        return nil
    }

    var canCorrectTearReview: Bool { tearReviewBlockReason == nil }

    func classifyTearCandidate(_ candidateID: String, as classification: ReferenceTearClassification) {
        runTearCorrection { worker, notes in
            await worker.classifyTearCandidate(candidateID, as: classification, notes: notes)
        }
    }

    func addTearBoundary(
        toCandidate candidateID: String,
        startTime: Double,
        endTime: Double,
        kind: ReferenceTearBoundaryKind = .hold,
        evidenceQuality: ReferenceTearEvidenceQuality = .clear
    ) {
        runTearCorrection { worker, notes in
            await worker.addTearBoundary(
                candidateID: candidateID,
                startTime: startTime,
                endTime: endTime,
                kind: kind,
                evidenceQuality: evidenceQuality,
                notes: notes
            )
        }
    }

    func moveTearBoundary(
        inCandidate candidateID: String,
        boundaryID: String,
        startTime: Double,
        endTime: Double
    ) {
        runTearCorrection { worker, notes in
            await worker.moveTearBoundary(
                candidateID: candidateID,
                boundaryID: boundaryID,
                startTime: startTime,
                endTime: endTime,
                notes: notes
            )
        }
    }

    func setTearBoundaryKind(
        inCandidate candidateID: String,
        boundaryID: String,
        to kind: ReferenceTearBoundaryKind
    ) {
        runTearCorrection { worker, notes in
            await worker.setTearBoundaryKind(
                candidateID: candidateID,
                boundaryID: boundaryID,
                kind: kind,
                notes: notes
            )
        }
    }

    func setTearBoundaryEvidenceQuality(
        inCandidate candidateID: String,
        boundaryID: String,
        to quality: ReferenceTearEvidenceQuality
    ) {
        runTearCorrection { worker, notes in
            await worker.setTearBoundaryEvidenceQuality(
                candidateID: candidateID,
                boundaryID: boundaryID,
                quality: quality,
                notes: notes
            )
        }
    }

    func setTearBoundaryRemoved(
        inCandidate candidateID: String,
        boundaryID: String,
        removed: Bool
    ) {
        runTearCorrection { worker, notes in
            await worker.setTearBoundaryRemoved(
                candidateID: candidateID,
                boundaryID: boundaryID,
                removed: removed,
                notes: notes
            )
        }
    }

    func commitTearReviewNotes() {
        runTearCorrection { worker, notes in
            await worker.setTearReviewNotes(notes)
        }
    }

    /// The ONE path every tear correction takes. Runs on the worker, applies
    /// the published state on the main actor, and never touches approval.
    private func runTearCorrection(
        _ operation: @escaping @Sendable (ReferenceAuthoringWorker, String) async -> ReferenceAuthoringWorkerUpdate
    ) {
        guard canCorrectTearReview else {
            visibleMessage = tearReviewBlockReason
            return
        }
        visibleMessage = nil
        let notes = tearReviewNotes
        Task { [weak self] in
            guard let self else { return }
            let update = await operation(worker, notes)
            apply(update)
            if update.errorMessage == nil {
                visibleMessage = "Tear correction recorded. This does not approve or install anything."
            }
        }
    }

    // MARK: Tear review presentation

    /// ISO-8601 so a recorded correction instant is unambiguous in the UI and
    /// in a test, independent of locale and time zone.
    static let tearCorrectionTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func tearReviewStatusText(_ review: ReferenceTearSegmentationReview?) -> String {
        guard let review else { return "No take is under review." }
        guard review.hasMotionEvidence else {
            return "No platter motion was recorded for this take, so there is nothing to segment."
        }
        guard !review.candidates.isEmpty else {
            return "No same-direction gesture was found in this take's recorded motion."
        }
        var parts = [
            "\(review.candidates.count) gesture\(review.candidates.count == 1 ? "" : "s")",
            "\(review.totalCountedTearHoldCount) counted platter hold\(review.totalCountedTearHoldCount == 1 ? "" : "s")",
            "\(review.correctedCandidateCount) corrected"
        ]
        if review.ambiguousCandidateCount > 0 {
            parts.append("\(review.ambiguousCandidateCount) with ambiguous evidence")
        }
        // Stated on every render. Reviewing tear segmentation is inspection,
        // not sign-off, and the screen must never imply otherwise.
        parts.append("approves nothing")
        return parts.joined(separator: " · ")
    }

    // MARK: Scalable tear review presentation

    /// One bucket of gesture candidates in the review list.
    ///
    /// Grouping is PRESENTATION ONLY. It reorders nothing inside a bucket,
    /// deletes no candidate, merges no evidence, and asserts no classification:
    /// each bucket carries the candidate IDs it contains, and
    /// `tearCandidateGroups` is a strict partition of `review.candidates`, so a
    /// 52-gesture take stays fully inspectable without 52 open cards.
    struct TearCandidateGroup: Equatable, Sendable, Identifiable {
        enum Kind: String, Equatable, Sendable, CaseIterable {
            /// The reading in force contradicts the surviving hold count.
            case disagreeing
            /// At least one surviving boundary is marked ambiguous evidence.
            case ambiguousEvidence
            /// The reading in force is `unknown` — nothing is asserted.
            case unknownReading
            /// Proposed automatically, still awaiting an operator reading.
            case awaitingOperatorReading
            /// The operator has given this gesture a reading.
            case operatorReviewed

            var title: String {
                switch self {
                case .disagreeing: return "Reading disagrees with boundaries"
                case .ambiguousEvidence: return "Ambiguous evidence"
                case .unknownReading: return "Unknown — nothing asserted"
                case .awaitingOperatorReading: return "Awaiting an operator reading"
                case .operatorReviewed: return "Operator reviewed"
                }
            }

            /// Whether this bucket is expanded by default. Only the buckets
            /// that need a decision open themselves; everything else stays one
            /// click away and nothing is hidden.
            var isExpandedByDefault: Bool {
                switch self {
                case .disagreeing, .ambiguousEvidence: return true
                case .unknownReading, .awaitingOperatorReading, .operatorReviewed: return false
                }
            }
        }

        let kind: Kind
        /// In review order. Never deduplicated across groups: a candidate
        /// appears in exactly one.
        let candidateIDs: [String]

        var id: String { kind.rawValue }
        var count: Int { candidateIDs.count }
        var headline: String { "\(kind.title) · \(count)" }
    }

    /// A strict partition of `review.candidates`, in bucket order, omitting
    /// empty buckets.
    ///
    /// First matching rule wins, so the most decision-worthy statement about a
    /// gesture is the one that files it. Every candidate is filed exactly once
    /// and none is dropped — `tearCandidateGroups(review).flatMap(\.candidateIDs)`
    /// is a permutation of `review.candidates.map(\.id)`.
    static func tearCandidateGroups(
        _ review: ReferenceTearSegmentationReview
    ) -> [TearCandidateGroup] {
        var buckets: [TearCandidateGroup.Kind: [String]] = [:]
        for candidate in review.candidates {
            let kind: TearCandidateGroup.Kind
            if candidate.classificationDisagreesWithBoundaryCount {
                kind = .disagreeing
            } else if candidate.hasAmbiguousEvidence {
                kind = .ambiguousEvidence
            } else if candidate.effectiveClassification == .unknown {
                kind = .unknownReading
            } else if !candidate.isManuallyClassified {
                kind = .awaitingOperatorReading
            } else {
                kind = .operatorReviewed
            }
            buckets[kind, default: []].append(candidate.id)
        }
        return TearCandidateGroup.Kind.allCases.compactMap { kind in
            guard let ids = buckets[kind], !ids.isEmpty else { return nil }
            return TearCandidateGroup(kind: kind, candidateIDs: ids)
        }
    }

    /// The group IDs a freshly-opened review expands, so a long take does not
    /// render every gesture card at once. Disclosure only: collapsed groups
    /// keep their full candidate lists and one click restores them.
    static func defaultExpandedTearGroupIDs(
        _ review: ReferenceTearSegmentationReview
    ) -> Set<String> {
        Set(
            tearCandidateGroups(review)
                .filter(\.kind.isExpandedByDefault)
                .map(\.id)
        )
    }

    /// One line naming the unit the review's platter positions are in, so the
    /// operator is never left to guess whether a number is a revolution.
    static func tearCoordinateContractText(
        _ review: ReferenceTearSegmentationReview
    ) -> String {
        "Platter coordinates: \(review.platterCoordinates.detail)."
    }

    // MARK: Advisory auto-detection

    /// What the take's automatic audio detection may be read as, and whether
    /// it is a genuine disagreement with the operator's selected technique.
    ///
    /// The detector is limited to Baby Scratch
    /// (`ReferenceAuthoringCaptureBridge.advisoryDetectorVocabulary`). Showing
    /// "Baby Scratch (does not match CXL selection)" on a Tear take reads as
    /// the operator being contradicted, when in fact the detector has no Tear
    /// vocabulary and cannot speak to the take at all. It never writes into
    /// `evidence.metadata.technique` in either case: `autoDetectedTechnique`
    /// is a `let` on `ReferenceAuthoringTake` with no writer anywhere.
    struct AdvisoryDetectionStatement: Equatable, Sendable {
        let text: String
        /// `true` ONLY when the detector could have expressed the selected
        /// technique and said something else. A limited detector is never a
        /// disagreement.
        let isDisagreement: Bool
        /// `true` when the detector cannot express the selected technique, so
        /// its result is uninformative about this take.
        let isOutsideDetectorVocabulary: Bool
    }

    static func advisoryDetectionStatement(
        for take: ReferenceAuthoringTake
    ) -> AdvisoryDetectionStatement {
        let selected = take.evidence.metadata.technique
        let canExpressSelection = ReferenceAuthoringCaptureBridge
            .advisoryDetectorCanExpress(selected)
        let vocabulary = ReferenceAuthoringCaptureBridge.advisoryDetectorVocabulary
            .map(\.displayName)
            .sorted()
            .joined(separator: ", ")

        guard let detected = take.autoDetectedTechnique else {
            let limit = canExpressSelection
                ? ""
                : " The automatic audio detector recognises \(vocabulary) only, so it "
                    + "cannot confirm or contradict \(selected.displayName)."
            return AdvisoryDetectionStatement(
                text: "Advisory auto-detection: no result." + limit,
                isDisagreement: false,
                isOutsideDetectorVocabulary: !canExpressSelection
            )
        }

        if detected == selected {
            return AdvisoryDetectionStatement(
                text: "Advisory auto-detection: \(detected.displayName) — agrees with the "
                    + "selected technique. Advisory only; the selected technique stands.",
                isDisagreement: false,
                isOutsideDetectorVocabulary: false
            )
        }

        if !canExpressSelection {
            return AdvisoryDetectionStatement(
                text: "Advisory auto-detection: \(detected.displayName) — LIMITED. The "
                    + "automatic audio detector recognises \(vocabulary) only, so it cannot "
                    + "confirm or contradict \(selected.displayName). This is not a "
                    + "disagreement, and it never overwrites the selected technique.",
                isDisagreement: false,
                isOutsideDetectorVocabulary: true
            )
        }

        return AdvisoryDetectionStatement(
            text: "Advisory auto-detection: \(detected.displayName) — does not match the "
                + "selected \(selected.displayName). Advisory only; the selected technique "
                + "stands and is never overwritten.",
            isDisagreement: true,
            isOutsideDetectorVocabulary: false
        )
    }

    static func tearCandidateHeadline(_ candidate: ReferenceTearCandidate) -> String {
        var text = "Gesture \(candidate.gestureIndex + 1) · \(candidate.direction.rawValue)"
        text += " · proposed \(candidate.proposedClassification.displayName)"
        if let confidence = candidate.proposedConfidence {
            text += String(format: " (confidence %.2f)", confidence)
        } else {
            text += " (confidence unknown)"
        }
        if let manual = candidate.manualClassification {
            text += " · operator \(manual.displayName)"
        }
        return text
    }

    static func tearBoundaryHeadline(_ boundary: ReferenceTearBoundary) -> String {
        var text = String(
            format: "%.3f–%.3f s · %@ · %@",
            boundary.span.startTime,
            boundary.span.endTime,
            boundary.kind.displayName,
            boundary.evidenceQuality.displayName
        )
        text += " · \(boundary.origin.displayName)"
        if boundary.isRemoved { text += " · struck out (retained)" }
        if !boundary.countsAsTearHold && !boundary.isRemoved { text += " · not counted" }
        return text
    }

    static func tearCorrectionSummary(_ correction: ReferenceTearCorrection) -> String {
        var text = "Corrected by \(correction.correctedBy)"
        text += " at \(tearCorrectionTimestampFormatter.string(from: correction.correctedAt))"
        let notes = correction.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += " — \(notes)" }
        return text
    }

    /// Says when the reading in force and the surviving boundaries disagree.
    /// Reported, never reconciled: the two are separate operator assertions.
    static func tearDisagreementText(_ candidate: ReferenceTearCandidate) -> String? {
        guard candidate.classificationDisagreesWithBoundaryCount else { return nil }
        return "\(candidate.effectiveClassification.displayName) does not match the "
            + "\(candidate.countedTearHoldCount) counted platter hold"
            + "\(candidate.countedTearHoldCount == 1 ? "" : "s")"
            + " (\(candidate.boundarySupportedClassification.displayName))."
    }

    func stopPolling() {
        cancelPreflightPolling()
        cancelCalibrationPolling()
    }

    /// View-lifecycle cancellation only. This does not issue a capture stop or
    /// persist/approve a reference; it merely abandons any wait begun by an
    /// explicit Stop action while the engine finishes that take on its own.
    func cancelTransientWorkForViewDisappearance() {
        stopBeatPreview()
        mediaReview.stop()
        stopPolling()
        finalizationTask?.cancel()
        finalizationTask = nil
        // The Watch wait is transient presentation work too. Cancelling it
        // abandons only the poll — the take keeps whatever truthful evidence
        // state it already had, and no capture, approval or publication side
        // effect occurs.
        cancelWatchTransferWait()
        isWorking = false
    }

    func toggleBeatPreview() {
        if isPreviewingBeat { stopBeatPreview(); return }
        guard !isWorking, session.phase != .recording else { return }
        mediaReview.stop()
        do {
            try beatPreviewEngine.start(mode: beatEngineMode, bpm: bpm)
            isPreviewingBeat = true
            visibleMessage = "Previewing \(beatEngineMode.title) at \(bpm) BPM. Nothing is being recorded."
        } catch {
            beatPreviewEngine.stop()
            isPreviewingBeat = false
            visibleMessage = "Could not play the backing preview: \(error.localizedDescription)"
        }
    }

    func stopBeatPreview() {
        beatPreviewEngine.stop()
        isPreviewingBeat = false
    }

    private func apply(_ update: ReferenceAuthoringWorkerUpdate) {
        #if DEBUG
        let nextTake = update.state.session.takeInReview ?? update.state.session.takes.last
        if reviewedTake?.id != nextTake?.id || tearReview != nextTake?.tearReview
            || reviewedTake?.restoredTearProjection != nextTake?.restoredTearProjection
            || reviewedTake?.restoredTearPerformedLimitations != nextTake?.restoredTearPerformedLimitations
            || reviewedTake?.evidence.metadata.bpm != nextTake?.evidence.metadata.bpm
            || session.phase != update.state.session.phase {
            resetTearComparison()
        }
        #endif
        state = update.state
        if let error = update.errorMessage {
            visibleMessage = error
        }
    }
}
