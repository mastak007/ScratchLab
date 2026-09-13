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
}

struct ReferenceAuthoringWorkerUpdate: Equatable, Sendable {
    let state: ReferenceAuthoringViewState
    let errorMessage: String?
}

/// Owns the non-Sendable hook closures behind one serial queue. The queue is
/// the only caller, so the bridge's blocking hooks can never run on main.
final class ReferenceAuthoringWorkerDriver: @unchecked Sendable {
    let hooks: ReferenceAuthoringRecordingHooks

    private let pendingConfigurationHandler: (ReferenceAuthoringBridgeTakeConfiguration) -> Void
    private let calibrationCommittedHandler: () -> Void
    private let finalizationWaitCancellationHandler: () -> Void

    init(bridge: ReferenceAuthoringCaptureBridge, engine: MacCaptureEngine) {
        hooks = bridge.hooks
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
        finalizationWaitCancellationHandler: @escaping () -> Void = {}
    ) {
        self.hooks = hooks
        self.pendingConfigurationHandler = pendingConfigurationHandler
        self.calibrationCommittedHandler = calibrationCommittedHandler
        self.finalizationWaitCancellationHandler = finalizationWaitCancellationHandler
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

    init(
        session: ReferenceAuthoringSession,
        driver: ReferenceAuthoringWorkerDriver,
        calibrationStore: CrossfaderCalibrationStore,
        queueLabel: String = "com.machelpnz.scratchlab.reference-authoring"
    ) {
        self.session = session
        self.driver = driver
        self.calibrationStore = calibrationStore
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    func snapshot() async -> ReferenceAuthoringViewState {
        await enqueue { worker in worker.makeState() }
    }

    func configure(
        technique: ReferenceTechnique,
        pattern: ReferencePatternIdentity,
        bpm: Int,
        startingDirection: ReferenceStartingPlatterDirection,
        faderVariant: ReferenceFaderVariant,
        handedness: CaptureSessionHandedness,
        notes: String
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
            return worker.makeUpdate()
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
            guard let technique = worker.session.selectedTechnique,
                  let bpm = worker.session.selectedBPM else {
                return worker.makeUpdate(errorMessage: "Select and apply a complete authoring setup before recording.")
            }
            worker.driver.setPendingConfiguration(
                ReferenceAuthoringBridgeTakeConfiguration(
                    technique: technique,
                    bpm: bpm,
                    handedness: worker.session.selectedHandedness,
                    notes: worker.session.notes
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
                try worker.session.rejectTakeInReview(notes: notes)
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    func retake() async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            worker.session.retake()
            return worker.makeUpdate()
        }
    }

    func approveCanonical(notes: String) async -> ReferenceAuthoringWorkerUpdate {
        await enqueue { worker in
            do {
                // `approveTakeInReview` revalidates and re-checks every gate
                // itself; the caller does not get to pre-authorise it.
                try worker.session.approveTakeInReview(notes: notes)
                return worker.makeUpdate()
            } catch {
                return worker.makeUpdate(errorMessage: Self.message(for: error))
            }
        }
    }

    /// Poll the finalized take's Watch evidence once and attach it if it has
    /// moved. Returns the resulting state so the caller can stop when terminal.
    func refreshWatchEvidenceOnce() async -> (update: ReferenceAuthoringWorkerUpdate, isTerminal: Bool) {
        await enqueue { worker in
            guard let evidence = worker.driver.hooks.refreshWatchEvidence() else {
                return (worker.makeUpdate(), true)
            }
            worker.session.updateWatchEvidenceForTakeInReview(evidence)
            return (worker.makeUpdate(), evidence.isTerminal)
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
        ReferenceAuthoringViewState(
            session: session,
            latestCalibrationRawValue: latestCalibrationRawValue
        )
    }

    private func makeUpdate(errorMessage: String? = nil) -> ReferenceAuthoringWorkerUpdate {
        ReferenceAuthoringWorkerUpdate(state: makeState(), errorMessage: errorMessage)
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
    @Published private(set) var state: ReferenceAuthoringViewState
    @Published private(set) var visibleMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isPreflightPolling = false
    @Published private(set) var isCalibrationPolling = false

    /// Identifies the one transient operation whose wording must be distinct
    /// from the session's persistent `.configuring` workflow phase. Mutated
    /// immediately before `isWorking`, so that property's publication also
    /// refreshes `workflowStatusText` without a second published source.
    private var isApplyingSetup = false

    @Published var selectedTechnique: ReferenceTechnique?
    @Published var patternID = ""
    @Published var patternName = ""
    @Published var phraseBars = 1
    @Published var bpm = 95
    @Published var startingDirectionRawValue = ""
    @Published var faderVariantRawValue = ""
    @Published var handednessRawValue = CaptureSessionHandedness.right.rawValue
    @Published var crossfaderOpenEndRawValue = CrossfaderOpenEnd.left.rawValue
    @Published var activeDeckRawValue = CrossfaderActiveDeck.rightDeck.rawValue
    @Published var notes = ""
    @Published var reviewNotes = ""

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
        if isWorking { return "An operation is still running." }
        if isWaitingForWatchTransfer { return "Waiting for the Apple Watch motion transfer to complete." }
        return session.approvalBlockReason()
    }

    var canApprove: Bool { approvalBlockReason == nil }

    init(
        engine: MacCaptureEngine,
        companionReceiver: CompanionCameraReceiver?,
        operatorName: String
    ) {
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
            calibrationStore: engine.crossfaderCalibrationStore
        )
        self.state = ReferenceAuthoringViewState(
            session: session,
            latestCalibrationRawValue: nil
        )
    }

    init(worker: ReferenceAuthoringWorker, initialState: ReferenceAuthoringViewState) {
        self.worker = worker
        self.state = initialState
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
                notes: notes
            )
            apply(update)
            visibleMessage = update.errorMessage ?? "Authoring setup applied."
            isApplyingSetup = false
            isWorking = false
        }
    }

    func refreshPreflightOnce() async {
        let update = await worker.refreshPreflight()
        apply(update)
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
        visibleMessage = nil
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.startRecording()
            apply(update)
            visibleMessage = update.errorMessage ?? "Recording started. Perform the same phrase four times."
            isWorking = false
        }
    }

    func stopRecording() {
        visibleMessage = nil
        isWorking = true
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            let update = await worker.stopRecording()
            guard !Task.isCancelled else { return }
            apply(update)
            visibleMessage = update.errorMessage ?? "Take finalized. Review all evidence and validation findings."
            isWorking = false
            finalizationTask = nil
            startWatchTransferWaitIfPending()
        }
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
        visibleMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.rejectTake(notes: reviewNotes)
            apply(update)
            visibleMessage = update.errorMessage ?? "Take rejected. Ready to record a new take."
        }
    }

    func retake() {
        visibleMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.retake()
            apply(update)
            visibleMessage = update.errorMessage ?? "Ready for a retake. The prior draft evidence remains retained."
        }
    }

    func approveCanonical() {
        visibleMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let update = await worker.approveCanonical(notes: reviewNotes)
            apply(update)
            visibleMessage = update.errorMessage ?? "Approved canonical draft. Not installed for training."
        }
    }

    func stopPolling() {
        cancelPreflightPolling()
        cancelCalibrationPolling()
    }

    /// View-lifecycle cancellation only. This does not issue a capture stop or
    /// persist/approve a reference; it merely abandons any wait begun by an
    /// explicit Stop action while the engine finishes that take on its own.
    func cancelTransientWorkForViewDisappearance() {
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

    private func apply(_ update: ReferenceAuthoringWorkerUpdate) {
        state = update.state
        if let error = update.errorMessage {
            visibleMessage = error
        }
    }
}
