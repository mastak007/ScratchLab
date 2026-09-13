// ReferenceAuthoringCaptureBridge — the ONLY place that connects
// `ReferenceAuthoringSession` (pure, hardware-free, shared) to one live
// `MacCaptureEngine`.
//
// Nothing here decides whether a take is a valid reference. That is still
// `ReferenceValidator`'s job, run by `ReferenceAuthoringSession.finishRecording`
// on whatever this bridge hands back. This file's only responsibility is:
// drive the real routine-capture pipeline, wait for its real (asynchronous)
// outcome, and translate what it produced into the plain data
// `ReferenceAuthoringSession` already knows how to validate.
//
// IMPORTANT — no capture recorded through this bridge is reference data by
// itself. A take recorded here starts life at `.draft` and stays diagnostic
// evidence until CXL explicitly reviews and approves it — the same rule that
// applies to every take recorded before this bridge existed, including the
// diagnostic ZIP this feature was built to fix. See
// `ScratchLab/Models/Reference/ReferenceAuthoringSession.swift`'s header.
//
// Concurrency contract — READ THIS BEFORE CALLING ANYTHING HERE:
// `ReferenceAuthoringRecordingHooks.startRecording`/`stopRecording` are
// SYNCHRONOUS by the type `ReferenceAuthoringSession` already declares, but
// `MacCaptureEngine`'s start/stop/finalize sequence is genuinely asynchronous
// and publishes UI state via `Task { @MainActor in ... }` blocks running on
// the main thread. The engine now also owns a durable, lock-protected boundary
// record for each exact recording generation. This bridge BLOCKS THE CALLING
// THREAD on a bounded poll of that record — which means
// `startRecording`/`stopRecording` MUST NEVER be called from the main
// thread. Doing so would deadlock: the calling thread would be blocked
// waiting for a main-actor Task that itself needs the main thread free to
// run. Both methods detect this and fail loudly with a specific error
// instead of hanging — see `Self.mainThreadMisuseError`.
//
// `ReferenceAuthoringViewModel` invokes the session's recording-triggering
// methods on its dedicated serial worker, never directly from a SwiftUI action
// closure.

import Foundation
import AVFoundation

// MARK: - Per-take configuration

/// What the caller must supply immediately before asking the bridge to start
/// a take — the fields `ReferenceAuthoringSession` has already collected in
/// steps 1–3 but has no way to hand to a parameterless `startRecording()`
/// closure.
struct ReferenceAuthoringBridgeTakeConfiguration: Equatable {
    let technique: ReferenceTechnique
    let bpm: Int
    let beatEngineMode: BeatEngineMode
    let handedness: CaptureSessionHandedness
    let notes: String
    let captureIntent: ReferenceCaptureIntent?
    let preparedBeat: ReferencePreparedBeat?

    var isMovementCheck: Bool { captureIntent?.isMovementCheck == true }

    init(
        technique: ReferenceTechnique,
        bpm: Int,
        beatEngineMode: BeatEngineMode = .boomBapTrainer,
        handedness: CaptureSessionHandedness = .right,
        notes: String = "",
        captureIntent: ReferenceCaptureIntent? = nil,
        preparedBeat: ReferencePreparedBeat? = nil
    ) {
        self.technique = technique
        self.bpm = bpm
        self.beatEngineMode = beatEngineMode
        self.handedness = handedness
        self.notes = notes
        self.captureIntent = captureIntent
        self.preparedBeat = preparedBeat
    }

    func recordingSessionConfig(existing: CaptureSessionConfig?, now: Date) -> CaptureSessionConfig {
        // A different scratch setup starts a different recording group. Its
        // old sidecars/configuration remain attached to the previous group.
        let sameSetup = existing?.referenceCaptureIntent?.id == captureIntent?.id
        return CaptureSessionConfig(
            performerName: ReferenceTakeMetadata.defaultPerformerName,
            bpm: bpm,
            scratchType: technique.scratchType,
            drillMode: .fullCapture,
            captureMode: isMovementCheck ? .movementCheck : .timedClick,
            beatEngineMode: isMovementCheck ? .silent : beatEngineMode,
            swingAmount: isMovementCheck ? 0 : beatEngineMode.defaultSwingAmount,
            plannedTakeDurationSeconds: plannedRecordingDurationSeconds,
            handedness: handedness,
            notes: notes,
            referenceCaptureIntent: captureIntent,
            sessionID: sameSetup ? (existing?.sessionID ?? CaptureCore.LocalRecordingNaming.sessionID())
                : CaptureCore.LocalRecordingNaming.sessionID(),
            createdAt: sameSetup ? (existing?.createdAt ?? now) : now,
            updatedAt: now
        )
    }

    var plannedRecordingDurationSeconds: Double? {
        guard !isMovementCheck else { return nil }
        guard let intent = captureIntent, let beat = intent.beatSpec,
              beat.sampleRate > 0, intent.bpm > 0 else { return nil }
        let beatFrames = (60.0 / Double(intent.bpm) * Double(beat.sampleRate)).rounded()
        let performanceBeats = intent.beatsPerCycle * intent.plan.repetitionCount
            + intent.plan.tailBars * CaptureClickTrackDefaults.beatsPerBar
        return Double(performanceBeats) * beatFrames / Double(beat.sampleRate)
    }
}

// MARK: - Bridge

/// Production `ReferenceAuthoringRecordingHooks` over one `MacCaptureEngine`.
///
/// Not `@MainActor` — deliberately. Its two blocking methods must run OFF the
/// main thread (see the file header), so the type itself carries no actor
/// affinity; it only touches `engine`'s `@Published` properties through
/// `DispatchQueue.main.sync` reads/writes, exactly the way `MacCaptureEngine`
/// itself publishes them.
final class ReferenceAuthoringCaptureBridge {

    /// How long to wait for the engine to confirm a take has genuinely
    /// started (`didStartRecordingTo`, not the optimistic pre-validation
    /// flag) before failing loudly.
    static let startTimeout: TimeInterval = 10
    /// How long to wait for asynchronous finalize (mux + notation fusion +
    /// sidecar write) after `stopRoutineRecording` before failing loudly.
    static let finalizeTimeout: TimeInterval = 30
    /// Poll granularity for both waits above.
    static let pollInterval: TimeInterval = 0.02
    /// How long to wait for the paired Watch to acknowledge a start before
    /// giving up. Wider than `CompanionCameraReceiver`'s own 3 s
    /// acknowledgement timeout so this wait observes that call's real answer
    /// rather than pre-empting it with a second, competing deadline.
    static let watchHandshakeTimeout: TimeInterval = 8
    /// A live MIDI observation older than this is not "moving" — used only
    /// for the platter preflight row.
    static let recentActivityWindow: CFTimeInterval = 1.5
    /// Fixed by the existing platter-decode convention this file reuses
    /// (`MacCaptureEngine.resolvedControllerMovementEvents`): right-platter
    /// telemetry is channel 1 / CC6. Not invented here.
    static let platterChannel = 1
    static let platterController = 6

    private let engine: MacCaptureEngine
    /// The same click/beat engine used by the normal desktop Capture route.
    /// CXL declares every reference take as `timed_click`, so starting the
    /// camera immediately without this engine made the sidecar claim an
    /// audible count-in that the operator never heard.
    private let beatEngine: ScratchLabBeatEngine
    /// The SAME transport Capture uses for the paired Watch. Not a second
    /// protocol: this bridge calls `requestWatchCaptureStart` exactly as
    /// `MacAnalyzerView`'s record action does, and never sends a stop —
    /// `MacCaptureEngine.watchStopRequestHandler` remains the single stop
    /// authority for every terminal path of a take (commit d3ecf2a6).
    ///
    /// Optional so the bridge stays constructible in tests with no
    /// Multipeer stack. `nil` records explicit unavailable Watch evidence;
    /// raw diagnostic media may still be recorded and saved.
    private let companionReceiver: CompanionCameraReceiver?
    /// Session/take identity reserved for the in-flight start, shared by the
    /// Watch command, the macOS media, the sidecar and the ReferenceTake.
    private var reservedTakeIdentity: TakeIdentity?
    /// Identity and media URL of the take this bridge most recently finalized,
    /// retained so `refreshWatchEvidence` can re-read exactly that take's
    /// sidecar as its Watch motion transfer completes. Never used to start or
    /// stop anything.
    private var lastFinalizedIdentity: TakeIdentity?
    private var lastFinalizedMediaURL: URL?
    private var pendingConfiguration: ReferenceAuthoringBridgeTakeConfiguration?
    /// The exact engine generation confirmed by this bridge's most recent
    /// successful start. Only this token may be stopped/finalized here.
    private var activeRecordingToken: RoutineRecordingRequestToken?
    private let cancellationLock = NSLock()
    private var finalizationWaitCancellationGeneration: UInt64 = 0
    /// Separate generation for the Watch start handshake. Kept apart from the
    /// finalization generation so cancelling one wait can never be mistaken
    /// for cancelling the other; the view-disappearance path bumps both.
    private var startHandshakeCancellationGeneration: UInt64 = 0

    init(
        engine: MacCaptureEngine,
        companionReceiver: CompanionCameraReceiver? = nil,
        beatEngine: ScratchLabBeatEngine? = nil
    ) {
        self.engine = engine
        self.companionReceiver = companionReceiver
        self.beatEngine = beatEngine ?? engine.makeReferenceBeatEngine()
    }

    /// Set immediately before calling
    /// `ReferenceAuthoringSession.beginRecording(using:)`. `startRecording()`
    /// fails loudly if this was never set.
    func setPendingConfiguration(_ configuration: ReferenceAuthoringBridgeTakeConfiguration) {
        pendingConfiguration = configuration
    }

    /// The `ReferenceAuthoringRecordingHooks` to hand to
    /// `ReferenceAuthoringSession`. A fresh value each time it's read; all
    /// four closures close over `self` weakly so the bridge can be released
    /// without leaking the session.
    var hooks: ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { [weak self] in
                self?.startRecording() ?? .failure(.recordingFailed("The capture bridge was deallocated."))
            },
            stopRecording: { [weak self] in
                self?.stopRecording() ?? .failure(.recordingFailed("The capture bridge was deallocated."))
            },
            currentPreflightSnapshot: { [weak self] in
                self?.currentPreflightSnapshot() ?? ReferenceAuthoringCaptureBridge.disconnectedSnapshot
            },
            latestCalibrationObservation: { [weak self] in
                self?.latestCalibrationObservation()
            },
            refreshWatchEvidence: { [weak self] in
                self?.refreshWatchEvidence()
            }
        )
    }

    // MARK: - startRecording

    private func startRecording() -> Result<Void, ReferenceAuthoringError> {
        if let mainThreadError = Self.mainThreadMisuseError(action: "startRecording") {
            return .failure(mainThreadError)
        }
        guard let configuration = pendingConfiguration else {
            return .failure(.recordingFailed(
                "No take configuration was set. Call setPendingConfiguration(_:) before beginRecording()."
            ))
        }

        let preparedBeat = configuration.preparedBeat
        guard configuration.isMovementCheck
                ? (preparedBeat == nil && configuration.captureIntent?.beatSpec == nil)
                : (preparedBeat != nil && preparedBeat?.binding == configuration.captureIntent?.beatSpec) else {
            return .failure(.recordingFailed("Prepare the backing sound before recording this reference take."))
        }

        let now = Date()
        // 1. Publish the take's configuration and RESERVE its identity. This
        //    single reserved sessionID/takeID is what the Watch command, the
        //    macOS media file, the sidecar and the ReferenceTake all carry —
        //    the same reservation Capture makes, not a parallel one.
        let identityResult: Result<TakeIdentity, ReferenceAuthoringError> = DispatchQueue.main.sync {
            engine.recordingSessionConfig = configuration.recordingSessionConfig(
                existing: engine.recordingSessionConfig, now: now
            )
            do {
                return .success(try engine.reserveNextRoutineTakeIdentity())
            } catch {
                return .failure(.recordingFailed(
                    "Could not reserve a take identity: \(SessionExportFailureText.describe(error))"
                ))
            }
        }

        let takeIdentity: TakeIdentity
        switch identityResult {
        case .success(let value):
            takeIdentity = value
        case .failure(let error):
            return .failure(error)
        }
        reservedTakeIdentity = takeIdentity

        // 2. Attempt paired Watch start on this exact identity. A degraded
        //    reply is retained as diagnostic evidence and cannot prevent raw
        //    media capture; an explicit cancellation still stops this attempt.
        let handshakeGeneration = currentStartHandshakeCancellationGeneration()
        let handshakeOutcome = Self.performWatchStartHandshake(
            engine: engine,
            receiver: companionReceiver,
            identity: takeIdentity,
            watchWrist: configuration.handedness.rawValue,
            timeout: Self.watchHandshakeTimeout,
            pollInterval: Self.pollInterval,
            isCancelled: { [weak self] in
                self?.startHandshakeWasCancelled(since: handshakeGeneration) ?? true
            }
        )

        let reply: WatchCaptureControlReply
        switch handshakeOutcome.replyForDiagnosticCapture(identity: takeIdentity) {
        case .success(let value):
            reply = value
        case .failure(let error):
            reservedTakeIdentity = nil
            DispatchQueue.main.sync {
                _ = engine.cancelPendingRoutineReservation()
            }
            return .failure(error)
        }

        // 3. Only now start the audible click count-in. The real macOS take
        //    starts on the click engine's recording boundary, carrying those
        //    exact host times into the persisted sidecar. From there the
        //    engine's `watchStopRequestHandler` remains the single stop owner.
        let timedStart = TimedRecordingStartRelay()
        let beatStartError: Error? = DispatchQueue.main.sync {
            engine.applyPendingWatchReply(reply)
            guard !startHandshakeWasCancelled(since: handshakeGeneration) else {
                return ReferenceAuthoringError.recordingFailed("The capture start was cancelled.")
            }
            if configuration.isMovementCheck {
                // No invented beat origin: start the same token-owned capture
                // immediately and leave its end to Stop and Finalize.
                let token = engine.startRoutineRecording(captureTiming: nil)
                if timedStart.complete(with: token) {
                    _ = engine.requestRoutineRecordingStop(for: token, reason: .interrupted)
                }
                return nil
            }
            guard let preparedBeat else {
                return ReferenceAuthoringError.recordingFailed("The backing sound is missing.")
            }
            do {
                // Prepare the camera and audio during count-in. The engine starts
                // the movie on a sample boundary just before the first beat.
                var armedToken: RoutineRecordingRequestToken?
                let started = try beatEngine.start(
                    preparedBeat: preparedBeat,
                    mode: configuration.beatEngineMode,
                    bpm: configuration.bpm,
                    onRecordingStart: { [engine, beatEngine] in
                        do { _ = try beatEngine.verifiedPreparedOutputRoute() }
                        catch {
                            beatEngine.stop()
                            timedStart.fail(SessionExportFailureText.describe(error))
                            if let token = armedToken {
                                _ = engine.requestRoutineRecordingStop(for: token, reason: .captureError)
                            }
                        }
                    }
                )
                let outputRoute = try beatEngine.verifiedPreparedOutputRoute()
                let captureTiming = CaptureTimingMetadata(
                    clickStartHostTime: started.clickStartHostTime,
                    recordingStartHostTime: started.recordingStartHostTime,
                    recordingStartOffsetSeconds: AVAudioTime.seconds(
                        forHostTime: started.recordingStartHostTime - started.clickStartHostTime)
                )
                let token = engine.startRoutineRecording(captureTiming: captureTiming,
                    beatOutputRoute: outputRoute)
                armedToken = token
                if timedStart.complete(with: token) {
                    beatEngine.stop()
                    _ = engine.requestRoutineRecordingStop(for: token, reason: .interrupted)
                }
                return nil
            } catch {
                return error
            }
        }

        if let beatStartError {
            DispatchQueue.main.sync {
                beatEngine.stop()
                _ = engine.cancelPendingRoutineReservation()
            }
            reservedTakeIdentity = nil
            return .failure(.recordingFailed(
                "Could not start capture: \(SessionExportFailureText.describe(beatStartError))"
            ))
        }

        let countInDuration = Double(configuration.isMovementCheck ? 0 : CaptureClickTrackDefaults.countInBeats)
            * 60.0 / Double(CaptureClickTrackDefaults.clampedBPM(configuration.bpm))
        let recordingToken: RoutineRecordingRequestToken
        if let token = timedStart.wait(timeout: countInDuration + 3)
            ?? timedStart.abandon() {
            recordingToken = token
        } else {
            DispatchQueue.main.sync {
                beatEngine.stop()
                _ = engine.cancelPendingRoutineReservation()
            }
            reservedTakeIdentity = nil
            return .failure(.recordingFailed(
                timedStart.failureMessage ?? "The audible count-in finished, but recording did not start."
            ))
        }

        switch Self.waitForRoutineRecordingStart(
            engine: engine,
            token: recordingToken,
            timeout: Self.startTimeout
        ) {
        case .success:
            activeRecordingToken = recordingToken
            return .success(())
        case .failure(let error):
            DispatchQueue.main.sync {
                beatEngine.stop()
                _ = engine.requestRoutineRecordingStop(
                    for: recordingToken,
                    reason: .interrupted
                )
            }
            return .failure(error)
        }
    }

    // MARK: - Watch start handshake

    /// What the bounded wait on the paired Watch start produced.
    enum WatchStartHandshakeOutcome {
        case acknowledged(WatchCaptureControlReply)
        case notAcknowledged(WatchCaptureControlReply)
        case timedOut
        case cancelled
        case unavailable

        /// Only cancellation refuses recording. Missing/degraded Watch data
        /// is persisted exactly as such and remains ineligible for approval.
        func replyForDiagnosticCapture(
            identity: TakeIdentity
        ) -> Result<WatchCaptureControlReply, ReferenceAuthoringError> {
            switch self {
            case .acknowledged(let reply), .notAcknowledged(let reply):
                guard reply.sessionID == identity.sessionID, reply.takeID == identity.takeID else {
                    return .success(WatchCaptureControlReply(
                        commandID: UUID().uuidString.lowercased(),
                        sessionID: identity.sessionID, takeID: identity.takeID,
                        syncState: .failed,
                        detail: "Watch start replied for another take; no synchronized Watch evidence is claimed."
                    ))
                }
                return .success(reply)
            case .timedOut, .unavailable:
                return .success(WatchCaptureControlReply(
                    commandID: UUID().uuidString.lowercased(),
                    sessionID: identity.sessionID, takeID: identity.takeID,
                    syncState: isTimedOut ? .timedOut : .unavailable,
                    detail: isTimedOut
                        ? "Watch start did not reply within the bounded wait. Raw media capture continued without synchronized Watch evidence."
                        : "The Watch relay was unavailable. Raw media capture continued without Watch evidence."
                ))
            case .cancelled:
                return .failure(.recordingFailed(
                    "The capture start was cancelled. Recording was not started."
                ))
            }
        }

        private var isTimedOut: Bool {
            if case .timedOut = self { return true }
            return false
        }
    }

    /// Cross-thread handoff between the bounded waiter (a non-main worker
    /// thread) and the `@MainActor` task that owns the real handshake.
    ///
    /// Exists so the waiter can give up on a bound WITHOUT orphaning a Watch
    /// capture: whichever side loses the race takes responsibility for
    /// releasing it, exactly once.
    private final class WatchStartHandshakeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: WatchCaptureControlReply?
        private var waiterAbandoned = false
        private var completed = false

        /// A task delayed on the main actor must not send a new start after
        /// the worker has already cancelled or continued without the Watch.
        func canBeginRequest() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !waiterAbandoned
        }

        /// Called by the handshake task. `true` when the waiter has already
        /// given up, so the TASK owns the cleanup.
        func complete(with reply: WatchCaptureControlReply) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.reply = reply
            completed = true
            return waiterAbandoned
        }

        /// Called by the waiter when its bound expires. Returns a reply only
        /// if the task landed first; otherwise the waiter has handed cleanup
        /// to the task.
        func abandon() -> WatchCaptureControlReply? {
            lock.lock()
            defer { lock.unlock() }
            if completed { return reply }
            waiterAbandoned = true
            return nil
        }

        var settledReply: WatchCaptureControlReply? {
            lock.lock()
            defer { lock.unlock() }
            return reply
        }
    }

    /// Carries the exact engine token created by the click engine's scheduled
    /// recording boundary back to the bridge's serial worker. If the bounded
    /// waiter has already left, the callback owns immediate cleanup so neither
    /// the Mac recorder nor the Watch can be orphaned.
    private final class TimedRecordingStartRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var token: RoutineRecordingRequestToken?
        private var waiterAbandoned = false
        private var failure: String?

        var failureMessage: String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func fail(_ message: String) {
            lock.lock()
            failure = message
            lock.unlock()
            semaphore.signal()
        }

        func complete(with token: RoutineRecordingRequestToken) -> Bool {
            lock.lock()
            self.token = token
            let shouldCleanUp = waiterAbandoned
            lock.unlock()
            semaphore.signal()
            return shouldCleanUp
        }

        func wait(timeout: TimeInterval) -> RoutineRecordingRequestToken? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                return nil
            }
            lock.lock()
            defer { lock.unlock() }
            return token
        }

        @discardableResult
        func abandon() -> RoutineRecordingRequestToken? {
            lock.lock()
            defer { lock.unlock() }
            if let token { return token }
            waiterAbandoned = true
            return nil
        }
    }

    /// Runs the SAME `requestWatchCaptureStart` call Capture makes, on the
    /// reserved identity, and blocks the CALLING (never main) thread on a
    /// bounded, cancellable wait for its answer.
    ///
    /// The caller applies only the settled reply. An abandoned wait's late
    /// reply can clean up only its original Watch identity, never a newer
    /// reservation or capture, and cannot promote degraded evidence.
    static func performWatchStartHandshake(
        engine: MacCaptureEngine,
        receiver: CompanionCameraReceiver?,
        identity: TakeIdentity,
        watchWrist: String?,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        isCancelled: @escaping () -> Bool
    ) -> WatchStartHandshakeOutcome {
        guard !isCancelled() else { return .cancelled }
        guard let receiver else { return .unavailable }
        return waitForWatchStartReply(
            engine: engine, identity: identity, timeout: timeout,
            pollInterval: pollInterval, isCancelled: isCancelled,
            requestStart: {
                await receiver.requestWatchCaptureStart(
                    sessionID: identity.sessionID, takeID: identity.takeID,
                    takeNumber: identity.takeNumber, watchWrist: watchWrist
                )
            }
        )
    }

    /// The same bounded handoff is injectable without starting hardware, so
    /// late replies and cancellation can be tested against real stop ownership.
    static func waitForWatchStartReply(
        engine: MacCaptureEngine,
        identity: TakeIdentity,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        isCancelled: @escaping () -> Bool,
        requestStart: @escaping @MainActor () async -> WatchCaptureControlReply
    ) -> WatchStartHandshakeOutcome {
        let relay = WatchStartHandshakeRelay()
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            guard relay.canBeginRequest() else { return }
            let reply = await requestStart()
            if relay.complete(with: reply),
               CaptureWatchStopPolicy.startMayHaveLeftWatchRecording(reply.syncState) {
                _ = engine.requestWatchStop(for: identity, reason: .interrupted)
            }
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var settled: WatchCaptureControlReply?
        var cancelled = false
        while true {
            if semaphore.wait(timeout: .now() + pollInterval) == .success {
                settled = relay.settledReply
                break
            }
            if isCancelled() {
                cancelled = true
                break
            }
            if Date() >= deadline { break }
        }

        if settled == nil {
            settled = relay.abandon()
        }
        if cancelled || isCancelled() {
            if let settled,
               CaptureWatchStopPolicy.startMayHaveLeftWatchRecording(settled.syncState) {
                DispatchQueue.main.sync {
                    _ = engine.requestWatchStop(for: identity, reason: .interrupted)
                }
            }
            return .cancelled
        }
        guard let reply = settled else {
            return .timedOut
        }
        return reply.syncState == .acknowledged
            ? .acknowledged(reply)
            : .notAcknowledged(reply)
    }

    /// Poll for the AUTHORITATIVE "recording genuinely started" signal.
    ///
    /// The generation is allocated for this exact start request, then marked
    /// started only by `didStartRecordingTo`. A prior take's status string or
    /// optimistic `isRoutineRecording` value can never satisfy this wait.
    private static func waitForRoutineRecordingStart(
        engine: MacCaptureEngine,
        token: RoutineRecordingRequestToken,
        timeout: TimeInterval
    ) -> Result<Void, ReferenceAuthoringError> {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let boundary = engine.routineRecordingBoundary(for: token) {
                if boundary.didStartRecording {
                    return .success(())
                }
                if let failure = boundary.startFailureDescription {
                    return .failure(.recordingFailed(failure))
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let status = DispatchQueue.main.sync { engine.routineRecordingStatus }
        return .failure(.recordingFailed(
            "Recording did not confirm within \(Int(timeout))s. Last status: \(status)"
        ))
    }

    // MARK: - stopRecording

    private func stopRecording() -> Result<ReferenceRecordedTakeArtifacts, ReferenceAuthoringError> {
        if let mainThreadError = Self.mainThreadMisuseError(action: "stopRecording") {
            return .failure(mainThreadError)
        }
        guard let recordingToken = activeRecordingToken else {
            return .failure(.noActiveRecording)
        }

        DispatchQueue.main.sync {
            beatEngine.stop()
        }

        let cancellationGeneration = currentFinalizationWaitCancellationGeneration()
        let completionResult: Result<RoutineRecordingFinalizationCompletion, ReferenceAuthoringError>
        switch engine.requestRoutineRecordingStop(for: recordingToken, reason: .manual) {
        case .accepted:
            completionResult = Self.waitForRoutineFinalization(
                token: recordingToken,
                timeout: Self.finalizeTimeout,
                pollInterval: Self.pollInterval,
                readBoundary: { [engine] in
                    engine.routineRecordingBoundary(for: recordingToken)
                },
                isCancelled: { [weak self] in
                    self?.finalizationWaitWasCancelled(since: cancellationGeneration) ?? true
                }
            )
        case .alreadyCompleted(let completion):
            completionResult = Self.validatedFinalizationCompletion(
                completion,
                expectedToken: recordingToken
            )
        case .rejected(let detail):
            return .failure(.recordingFailed(detail))
        }

        let completion: RoutineRecordingFinalizationCompletion
        switch completionResult {
        case .success(let value):
            completion = value
        case .failure(let error):
            return .failure(error)
        }

        // Identities the take-start crossfader snapshot must have been
        // observed under. Read from the LIVE engine here, at stop time, so a
        // snapshot recorded under a since-replaced device connection or a
        // since-changed input selection is refused rather than adopted.
        let liveIdentity: (sourceID: String, connectionGeneration: UInt64) = DispatchQueue.main.sync {
            (engine.selectedMIDIInputSourceID, engine.midiConnectionGeneration)
        }
        let takeStartCorrelation = reservedTakeIdentity.map { identity in
            ReferenceCrossfaderTakeStart.Correlation(
                sessionID: identity.sessionID,
                takeID: identity.takeID,
                takeGeneration: recordingToken.generation,
                midiSourceID: liveIdentity.sourceID,
                midiConnectionGeneration: liveIdentity.connectionGeneration
            )
        }

        do {
            if let preparedBeat = pendingConfiguration?.preparedBeat {
                try Self.preserveBeat(preparedBeat, beside: completion.mediaURL)
            }
        } catch {
            return .failure(.recordingFailed("Could not preserve this take's backing sound: \(error.localizedDescription)"))
        }

        let artifacts = Self.buildArtifacts(
            mediaURL: completion.mediaURL,
            expectedIdentity: reservedTakeIdentity,
            takeStartCorrelation: takeStartCorrelation
        )
        if case .success = artifacts {
            activeRecordingToken = nil
            // Retain the identity/URL for the Watch-transfer wait BEFORE
            // clearing the reservation — the transfer completes after this
            // point, and re-reading needs to name this exact take.
            lastFinalizedIdentity = reservedTakeIdentity
            lastFinalizedMediaURL = completion.mediaURL
            reservedTakeIdentity = nil
        }
        return artifacts
    }

    static func preserveBeat(_ beat: ReferencePreparedBeat, beside mediaURL: URL) throws {
        let root = mediaURL.deletingLastPathComponent().appendingPathComponent("beat_assets", isDirectory: true)
        let destination = root.appendingPathComponent(beat.binding.id, isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: destination.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: beat.directoryURL, to: staging)
            try manager.moveItem(at: staging, to: destination)
        }
        _ = try ReferenceBeatAssetStore.resolve(binding: beat.binding, rootURL: root)
    }

    /// Wait for a durable terminal record for one exact engine generation.
    /// The injected clock/wait/read seams keep every edge deterministic in
    /// tests without constructing AVFoundation hardware.
    static func waitForRoutineFinalization(
        token: RoutineRecordingRequestToken,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        readBoundary: () -> RoutineRecordingBoundarySnapshot?,
        isCancelled: () -> Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Result<RoutineRecordingFinalizationCompletion, ReferenceAuthoringError> {
        let deadline = now() + timeout
        while now() < deadline {
            if isCancelled() {
                return .failure(.recordingFailed("Finalization wait was cancelled."))
            }
            if let boundary = readBoundary(),
               boundary.token == token,
               boundary.didStartRecording,
               boundary.stopWasRequested,
               boundary.didEnterFinalization,
               let completion = boundary.completion,
               completion.token == token,
               completion.takeID == boundary.takeID,
               completion.mediaURL == boundary.mediaURL {
                return validatedFinalizationCompletion(
                    completion,
                    expectedToken: token
                )
            }
            wait(pollInterval)
        }
        if isCancelled() {
            return .failure(.recordingFailed("Finalization wait was cancelled."))
        }
        return .failure(.recordingFailed(
            "Finalization did not complete within \(formattedSeconds(timeout))s."
        ))
    }

    private static func validatedFinalizationCompletion(
        _ completion: RoutineRecordingFinalizationCompletion,
        expectedToken: RoutineRecordingRequestToken
    ) -> Result<RoutineRecordingFinalizationCompletion, ReferenceAuthoringError> {
        guard completion.token == expectedToken else {
            return .failure(.recordingFailed(
                "Finalization completed for a different recording generation."
            ))
        }
        guard completion.succeeded else {
            return .failure(.recordingFailed(
                completion.statusMessage.isEmpty
                    ? "Recording ended without producing a finished take."
                    : completion.statusMessage
            ))
        }
        return .success(completion)
    }

    private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds
            ? String(Int(seconds))
            : String(format: "%.2f", seconds)
    }

    // MARK: - Artifact assembly (post-finalize)

    /// Read the finalized sidecar + measure/hash the finalized files. Every
    /// measurement here is either a direct reuse of `ArtifactPreflight`
    /// (existence/size/stability — `SessionExportCoordinator.swift`) or
    /// `ReferencePackageIO.sha256Hex` (hashing —
    /// `ScratchLab/Services/ReferencePackageIO.swift`), never a re-implementation
    /// of either.
    static func buildArtifacts(
        mediaURL: URL,
        expectedIdentity: TakeIdentity?,
        takeStartCorrelation: ReferenceCrossfaderTakeStart.Correlation? = nil,
        fileManager: FileManager = .default
    ) -> Result<ReferenceRecordedTakeArtifacts, ReferenceAuthoringError> {
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: mediaURL)
        let audioURL = mediaURL.deletingPathExtension().appendingPathExtension("wav")

        guard fileManager.fileExists(atPath: sidecarURL.path) else {
            return .failure(.recordingFailed(
                "Finalize reported success but \(sidecarURL.lastPathComponent) does not exist."
            ))
        }
        let sidecar: CaptureCore.LocalRecordingSidecar
        let sourceBinding: ReferenceTearEvidenceSourceBinding
        do {
            let data = try Data(contentsOf: sidecarURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)
            sourceBinding = try ReferenceTearEvidenceCodec.makeSourceBinding(
                rawSidecarData: data, fileName: sidecarURL.lastPathComponent
            )
        } catch {
            return .failure(.recordingFailed(
                "Finalized sidecar \(sidecarURL.lastPathComponent) could not be read: \(SessionExportFailureText.describe(error))"
            ))
        }
        guard sidecar.recordingStatus == "completed" else {
            return .failure(.recordingFailed(
                sidecar.errorDescription ?? "Take finalized with status '\(sidecar.recordingStatus)', not 'completed'."
            ))
        }

        // Identity, bytes and the measured hash describe one finalized snapshot.
        // Later sidecar rewrites must fail companion export, never silently rebind it.
        let sidecarMeasurement = ReferenceArtifactMeasurement(
            fileName: sidecarURL.lastPathComponent, exists: true,
            byteCount: Int64(sourceBinding.rawSidecarData.count),
            recordedSHA256: sourceBinding.rawSidecarSHA256,
            currentSHA256: sourceBinding.rawSidecarSHA256
        )

        let audioCheck = ArtifactPreflight.checkFileReady(url: audioURL, fileManager: fileManager)
        guard audioCheck.exists, audioCheck.bytes > 0 else {
            return .failure(.recordingFailed(
                "\(audioURL.lastPathComponent) is missing or empty after finalize."
            ))
        }
        let audioMeasurement: ReferenceArtifactMeasurement
        switch measureAudio(url: audioURL, byteCount: audioCheck.bytes, fileManager: fileManager) {
        case .success(let measurement):
            audioMeasurement = measurement
        case .failure(let error):
            return .failure(error)
        }

        let videoCheck = ArtifactPreflight.checkFileReady(url: mediaURL, fileManager: fileManager)
        let videoMeasurement = measureArtifact(
            url: mediaURL,
            fileManager: fileManager,
            readError: (!videoCheck.exists || videoCheck.bytes <= 0)
                ? "Video file is missing or empty after finalize."
                : (!videoCheck.isStable ? "Video file had not finished writing." : nil)
        )

        let detectedNotation = sidecar.detectedNotation
        let mixerMidiEvents = detectedNotation?.mixerMidiEvents ?? []
        let crossfaderEvents = mixerMidiEvents.filter { $0.mappedControl == "crossfader" }
        // Keep saved events/counts verbatim. Reuse the shared raw decoder only
        // for a companion provenance view, including runs lost by old filters.
        let platterMovementEvents = detectedNotation?.recordMovementEvents ?? []
        let mediaTimeOrigin: ReferenceMediaTimeOrigin?
        do {
            mediaTimeOrigin = try makeMediaTimeOrigin(captureTiming: sidecar.captureTiming)
        } catch {
            return .failure(.recordingFailed(error.localizedDescription))
        }
        let witnessedTiming = makeWitnessedTiming(
            sidecar: sidecar,
            audio: audioMeasurement,
            videoURL: videoMeasurement.exists ? mediaURL : nil,
            mediaTimeOrigin: mediaTimeOrigin
        )
        let perTakeSourceState = makePerTakeSourceState(
            sidecar: sidecar,
            expectedIdentity: expectedIdentity,
            takeDirectory: mediaURL.deletingLastPathComponent()
        )

        return .success(
            ReferenceRecordedTakeArtifacts(
                audio: audioMeasurement,
                video: videoMeasurement,
                sidecar: sidecarMeasurement,
                actualMediaFileName: mediaURL.lastPathComponent,
                crossfaderRawSamples: crossfaderPositionSamples(from: crossfaderEvents),
                rawMixerMIDIEvents: mixerMidiEvents,
                observedCrossfaderAddress: observedCrossfaderAddress(from: crossfaderEvents),
                platterMovementEventCount: platterMovementEvents.count,
                recordedAt: sidecar.endedAt ?? sidecar.startedAt,
                autoDetectedTechnique: autoDetectedTechnique(
                    fromDetectedLabel: detectedNotation?.effectiveDetectedLabel
                ),
                watchEvidence: watchEvidence(in: sidecar, expectedIdentity: expectedIdentity),
                platterMovementEvents: platterMovementEvents,
                platterEvidenceIntervals: CaptureCore.derivePlatterMotionEvidence(
                    from: mixerMidiEvents
                ).retaining(normalizedEvents: platterMovementEvents).intervals,
                // Handed through VERBATIM. Whether it may seed this take's
                // fader baseline is decided once, by
                // `ReferenceCrossfaderTakeStart.correlate`, in the session —
                // this bridge only supplies the record and the identities it
                // must be correlated against.
                crossfaderTakeStartState: sidecar.crossfaderTakeStartState,
                crossfaderTakeStartCorrelation: takeStartCorrelation,
                tearEvidenceSourceBinding: sourceBinding,
                rawSidecarURL: sidecarURL,
                witnessedTiming: witnessedTiming,
                mediaTimeOrigin: mediaTimeOrigin,
                sourceState: perTakeSourceState
            )
        )
    }

    private static func makePerTakeSourceState(
        sidecar: CaptureCore.LocalRecordingSidecar,
        expectedIdentity: TakeIdentity?,
        takeDirectory: URL
    ) -> ReferencePerTakeSourceState {
        guard let expectedIdentity else {
            return .conflict(identity: nil, detail: "the capture bridge has no reserved take identity")
        }
        guard sidecar.sessionID == expectedIdentity.sessionID,
              sidecar.takeID == expectedIdentity.takeID else {
            let expected = ReferenceTakeSourceIdentity(
                sessionID: expectedIdentity.sessionID, takeID: expectedIdentity.takeID,
                takeNumber: expectedIdentity.takeNumber, takeToken: sidecar.watchCommandID ?? "missing-token"
            )
            return .identityMismatch(
                expected: expected,
                foundSessionID: sidecar.sessionID,
                foundTakeID: sidecar.takeID
            )
        }
        guard let token = sidecar.watchCommandID, !token.isEmpty else {
            return sidecar.watchSyncState == .notRequested
                ? .notRequested(policy: "supported capture policy did not request Watch evidence")
                : .conflict(identity: nil, detail: "Watch evidence has no take token")
        }
        let identity = ReferenceTakeSourceIdentity(
            sessionID: expectedIdentity.sessionID,
            takeID: expectedIdentity.takeID,
            takeNumber: expectedIdentity.takeNumber,
            takeToken: token
        )
        let evidence = watchEvidence(in: sidecar, expectedIdentity: expectedIdentity)
        switch evidence {
        case .linked(let fileName):
            guard let data = verifiedWatchData(sidecar: sidecar, takeDirectory: takeDirectory) else {
                return .conflict(identity: identity, detail: "The linked Watch file could not be verified for this take.")
            }
            return .linked(identity: identity, motionFileName: fileName, sha256: ReferencePackageIO.sha256Hex(data))
        case .acknowledgedTransferPending:
            return .waitingForLateTransfer(
                identity: identity,
                deadline: (sidecar.endedAt ?? sidecar.startedAt).addingTimeInterval(90)
            )
        case .transferFailed(let detail):
            return sidecar.watchSyncState == .timedOut
                ? .timedOut(identity: identity)
                : .conflict(identity: identity, detail: detail)
        case .identityMismatch(_, let found):
            let pieces = found.split(separator: "/", maxSplits: 1).map(String.init)
            return .identityMismatch(
                expected: identity,
                foundSessionID: pieces.first ?? found,
                foundTakeID: pieces.count > 1 ? pieces[1] : "unknown"
            )
        case .missing(let syncState):
            if sidecar.watchSyncState == .unavailable {
                return .unavailable(policy: "Watch was unavailable under the supported CXL policy")
            }
            if sidecar.watchSyncState == .timedOut {
                return .timedOut(identity: identity)
            }
            return .conflict(identity: identity, detail: "Watch source ended as \(syncState)")
        }
    }

    static func verifiedWatchData(sidecar: CaptureCore.LocalRecordingSidecar, takeDirectory: URL) -> Data? {
        guard let fileName = sidecar.linkedMotionFileName,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              let expectedCaptureID = sidecar.linkedMotionCaptureID else { return nil }
        let localURL = takeDirectory.appendingPathComponent(fileName)
        let resolvedURL = FileManager.default.fileExists(atPath: localURL.path)
            ? localURL : SessionArchiveBuilder().resolveLinkedWatchCaptureArtifact(for: sidecar)?.fileURL
        guard let resolvedURL, let data = try? Data(contentsOf: resolvedURL),
              let capture = try? WatchMotionCaptureCodec.decoder.decode(WatchMotionCaptureSession.self, from: data),
              capture.id == expectedCaptureID,
              WatchAssociationResolver.isLinkedCaptureValid(sessionID: sidecar.sessionID,
                takeID: sidecar.takeID, captureSession: capture) else { return nil }
        return data
    }

    static func makeMediaTimeOrigin(captureTiming: CaptureTimingMetadata?) throws -> ReferenceMediaTimeOrigin? {
        guard let captureTiming else { return nil }
        guard let clickStart = captureTiming.clickStartHostTime,
              let recordingStart = captureTiming.recordingStartHostTime,
              clickStart > 0, recordingStart >= clickStart else {
            throw ReferenceAuthoringError.recordingFailed("The take's media origin has missing or unordered capture timestamps.")
        }
        let origin = ReferenceMediaTimeOrigin(
            clickStartHostTime: clickStart,
            recordingStartHostTime: recordingStart,
            recordingStartOffsetSeconds: captureTiming.recordingStartOffsetSeconds
                ?? AVAudioTime.seconds(forHostTime: recordingStart - clickStart)
        )
        guard origin.validationIssues.isEmpty else {
            throw ReferenceAuthoringError.recordingFailed(origin.validationIssues.joined(separator: " "))
        }
        return origin
    }

    static func makeWitnessedTiming(
        sidecar: CaptureCore.LocalRecordingSidecar,
        audio: ReferenceArtifactMeasurement,
        videoURL: URL?,
        mediaTimeOrigin: ReferenceMediaTimeOrigin?
    ) -> ReferenceWitnessedTiming? {
        guard let captureTiming = sidecar.captureTiming,
              let clickStart = captureTiming.clickStartHostTime,
              let actualStart = captureTiming.recordingStartHostTime,
              let config = sidecar.sessionConfig,
              let intent = config.referenceCaptureIntent,
              let beat = intent.beatSpec,
              let audioFrames = audio.frameCount,
              let audioSampleRate = audio.sampleRate,
              audioSampleRate.isFinite, audioSampleRate > 0,
              beat.sampleRate > 0 else { return nil }
        let sampleRate = Double(beat.sampleRate)
        let intendedStart = clickStart + AVAudioTime.hostTime(
            forSeconds: Double(beat.countInFrameCount) / sampleRate
        )
        let wavDuration = Double(audioFrames) / audioSampleRate
        let plannedDuration = ReferenceRecordingOriginPolicy.intendedDuration(intent: intent, beat: beat)
        let movDuration: Double?
        if let videoURL {
            let measured = CMTimeGetSeconds(AVURLAsset(url: videoURL).duration)
            movDuration = measured.isFinite && measured > 0 ? measured : nil
        } else {
            movDuration = nil
        }
        return ReferenceWitnessedTiming(
            clickStartHostTime: clickStart,
            intendedMediaOriginHostTime: intendedStart,
            actualRecordingOriginHostTime: actualStart,
            sampleRate: beat.sampleRate,
            countInFrameCount: beat.countInFrameCount,
            loopStartFrame: beat.loopStartFrame,
            loopFrameCount: beat.loopFrameCount,
            beatsPerCycle: intent.beatsPerCycle,
            plannedRepetitions: intent.plan.repetitionCount,
            plannedDurationSeconds: plannedDuration,
            measuredWAVDurationSeconds: wavDuration,
            measuredMOVDurationSeconds: movDuration,
            uncertaintySeconds: max(1.0 / sampleRate, 1.0 / audioSampleRate),
            source: .captureSidecarHostClock
        )
    }

    /// Classify a finalized sidecar's Watch evidence against the identity this
    /// bridge reserved.
    ///
    /// Deliberately a STATE, not a boolean. On 2026-09-05 take-003 the Watch
    /// acknowledged at 17:07:42Z on the reserved identity, was stopped once and
    /// resolved at 17:07:59Z on the same identity, and its
    /// `motionTransferState` was still `pending` when finalization read the
    /// sidecar. A boolean reported that working Watch as missing and left the
    /// take permanently un-approvable.
    ///
    /// The identity check comes first and is absolute: evidence naming another
    /// session or take is never attached, whatever state it is in.
    static func watchEvidence(
        in sidecar: CaptureCore.LocalRecordingSidecar,
        expectedIdentity: TakeIdentity?
    ) -> ReferenceWatchEvidence {
        guard let expectedIdentity else {
            return .missing(syncState: sidecar.watchSyncState.rawValue)
        }
        let expected = "\(expectedIdentity.sessionID)/\(expectedIdentity.takeID)"
        guard sidecar.sessionID == expectedIdentity.sessionID,
              sidecar.takeID == expectedIdentity.takeID else {
            return .identityMismatch(
                expected: expected,
                found: "\(sidecar.sessionID)/\(sidecar.takeID)"
            )
        }
        if let diagnostics = sidecar.watchStopDiagnostics,
           let stopSession = diagnostics.sessionID,
           let stopTake = diagnostics.takeID,
           stopSession != expectedIdentity.sessionID || stopTake != expectedIdentity.takeID {
            return .identityMismatch(expected: expected, found: "\(stopSession)/\(stopTake)")
        }
        // A linked motion capture is the only thing that counts as landed.
        if sidecar.linkedMotionCaptureID != nil {
            return .linked(motionFileName: sidecar.linkedMotionFileName)
        }
        guard sidecar.watchSyncState == .acknowledged else {
            return .missing(syncState: sidecar.watchSyncState.rawValue)
        }
        // `sent` is an in-flight command, not a failed transfer. Finalization
        // often wins the race with the reply; keep polling the exact take.
        if sidecar.watchStopDiagnostics?.outcome == .sent {
            return .acknowledgedTransferPending
        }
        if let stop = sidecar.watchStopDiagnostics, stop.outcome.isDegraded {
            return .transferFailed(
                detail: "The Watch did not confirm Stop (\(stop.outcome.rawValue)). If it is still recording, open ScratchLab on the Watch and press Stop. The Mac recording is retained."
            )
        }
        switch sidecar.watchStopDiagnostics?.motionTransferState {
        case .completed:
            // Transfer says completed but nothing is linked — that is a
            // failure to associate, not a success.
            return .transferFailed(
                detail: "the transfer reported completed but no motion capture is linked to this take."
            )
        case .pending, .none:
            return .acknowledgedTransferPending
        case .notApplicable:
            return .transferFailed(
                detail: "the Watch acknowledged the start but reported no motion artifact for this take."
            )
        }
    }

    /// The media URL of the take this bridge most recently finalized, or
    /// `nil` when it has finalized none.
    ///
    /// Read-only provenance for the RAW diagnostic export action. Exposing it
    /// starts, stops, promotes and publishes nothing: the export path copies
    /// the already-written capture through the existing
    /// `SessionExportCoordinator`, and never touches reference lifecycle
    /// state.
    var lastFinalizedRecordingURL: URL? { lastFinalizedMediaURL }

    var activeRecordingHasStopped: Bool {
        guard let token = activeRecordingToken,
              let boundary = engine.routineRecordingBoundary(for: token),
              boundary.token == token, boundary.didStartRecording else { return false }
        return boundary.stopWasRequested || boundary.didEnterFinalization || boundary.completion != nil
    }

    /// Re-read the last finalized take's sidecar and re-classify its Watch
    /// evidence. Pure file read; attaches nothing itself.
    private func refreshWatchEvidence() -> ReferenceWatchEvidenceRefresh? {
        guard let mediaURL = lastFinalizedMediaURL else { return nil }
        return Self.refreshWatchEvidence(mediaURL: mediaURL, expectedIdentity: lastFinalizedIdentity)
    }

    /// Reopening a draft reads its own recording, never the bridge's latest take.
    static func refreshWatchEvidence(mediaURL: URL, expectedIdentity: TakeIdentity?) -> ReferenceWatchEvidenceRefresh? {
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: mediaURL)
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: data
        ) else { return nil }
        let sourceBinding = try? ReferenceTearEvidenceCodec.makeSourceBinding(
            rawSidecarData: data,
            fileName: sidecarURL.lastPathComponent
        )
        let sourceState = Self.makePerTakeSourceState(sidecar: sidecar,
            expectedIdentity: expectedIdentity, takeDirectory: mediaURL.deletingLastPathComponent())
        let evidence = Self.watchEvidence(in: sidecar, expectedIdentity: expectedIdentity)
        if case .linked = sourceState {
            return .init(evidence: evidence, sourceBinding: sourceBinding, sourceState: sourceState)
        }
        if evidence.isLinked, case .conflict(_, let detail) = sourceState {
            return .init(evidence: .transferFailed(detail: detail), sourceBinding: sourceBinding)
        }
        return .init(evidence: evidence, sourceBinding: sourceBinding)
    }

    private static func measureArtifact(
        url: URL,
        fileManager: FileManager,
        readError: String?
    ) -> ReferenceArtifactMeasurement {
        let check = ArtifactPreflight.checkFileReady(url: url, fileManager: fileManager)
        let hash = (try? Data(contentsOf: url)).map(ReferencePackageIO.sha256Hex)
        return ReferenceArtifactMeasurement(
            fileName: url.lastPathComponent,
            exists: check.exists,
            byteCount: check.bytes,
            readError: readError,
            recordedSHA256: hash,
            currentSHA256: hash
        )
    }

    /// Peak level + frame count, measured directly (no existing public helper
    /// computes an overall peak — `SessionArchiveBuilder.probeAudio` reports
    /// duration/sample rate/channel/frame counts but not peak, and
    /// `ScratchLabDemoAudioSampleBuffer` builds a playback activity envelope,
    /// not a single peak figure — so this is new, not a duplicate).
    private static func measureAudio(
        url: URL,
        byteCount: Int64,
        fileManager: FileManager
    ) -> Result<ReferenceArtifactMeasurement, ReferenceAuthoringError> {
        let hash = (try? Data(contentsOf: url)).map(ReferencePackageIO.sha256Hex)
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate > 0,
                  file.length > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(file.length)
                  ) else {
                return .failure(.recordingFailed(
                    "\(url.lastPathComponent) could not be prepared for peak measurement."
                ))
            }
            try file.read(into: buffer)
            let frameCount = Int(buffer.frameLength)
            var peak: Float = 0
            if let channelData = buffer.floatChannelData {
                let channelCount = Int(format.channelCount)
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    for frame in 0..<frameCount {
                        peak = max(peak, abs(samples[frame]))
                    }
                }
            }
            return .success(
                ReferenceArtifactMeasurement(
                    fileName: url.lastPathComponent,
                    exists: true,
                    byteCount: byteCount,
                    peakLevel: Double(peak),
                    frameCount: Int64(frameCount),
                    sampleRate: format.sampleRate,
                    recordedSHA256: hash,
                    currentSHA256: hash
                )
            )
        } catch {
            return .failure(.recordingFailed(
                "\(url.lastPathComponent) could not be read: \(SessionExportFailureText.describe(error))"
            ))
        }
    }

    // MARK: - Pure mapping (unit-testable without a live engine)

    /// Requirement: use `calibratedPosition`; fall back to the diagnostic
    /// `normalizedValue` (raw / 127, NOT a deck position) only when the WHOLE
    /// crossfader stream lacks calibration — never mixed sample-by-sample,
    /// matching the all-or-nothing rule
    /// `CaptureCore.deriveDetectedNotationFaderEvents` already applies.
    static func crossfaderPositionSamples(
        from crossfaderEvents: [CaptureCore.RawMixerMIDIEvent]
    ) -> [CrossfaderPositionSample] {
        let usesCalibratedPositions = !crossfaderEvents.isEmpty
            && crossfaderEvents.allSatisfy { $0.calibratedPosition != nil }
        return crossfaderEvents.map { event in
            CrossfaderPositionSample(
                takeRelativeTime: event.takeRelativeTime,
                rawValue: event.value,
                normalizedPosition: usesCalibratedPositions
                    ? (event.calibratedPosition ?? event.normalizedValue)
                    : event.normalizedValue
            )
        }
    }

    static func observedCrossfaderAddress(
        from crossfaderEvents: [CaptureCore.RawMixerMIDIEvent]
    ) -> CrossfaderMIDIAddress? {
        guard let first = crossfaderEvents.first else { return nil }
        return CrossfaderMIDIAddress(
            deviceIdentifier: first.deviceIdentifier ?? "",
            deviceName: first.deviceName,
            channel: first.channel,
            controller: first.controller
        )
    }

    /// The COMPLETE vocabulary the finalized-take automatic detector can emit.
    ///
    /// `MacScratchDetector.process` runs exactly one matcher,
    /// `matchBabyScratch`, and that matcher hardcodes
    /// `scratchID: "baby_scratch"` / `scratchName: "Baby Scratch"`. The
    /// registry in `ScratchClassifying` currently registers only
    /// `BabyScratchClassifier`. So the detector cannot express Tear, Chirp,
    /// Transform or Flare AT ALL — a Baby Scratch result against one of those
    /// selected techniques is the detector's limit, not evidence that the
    /// operator chose wrongly. Callers must say so rather than render a
    /// mismatch warning; see
    /// `ReferenceAuthoringViewModel.advisoryDetectionStatement(for:)`.
    static let advisoryDetectorVocabulary: Set<ReferenceTechnique> = [.babyScratch]

    /// Whether the advisory detector is even able to agree or disagree about
    /// `technique`. `false` means any result it produced is uninformative
    /// about this take.
    static func advisoryDetectorCanExpress(_ technique: ReferenceTechnique) -> Bool {
        advisoryDetectorVocabulary.contains(technique)
    }

    /// Advisory-only mapping from what auto-detection believed to
    /// `ReferenceTechnique`. NEVER called anywhere that writes into
    /// `ReferenceAuthoringSession.selectedTechnique` — see the file header.
    ///
    /// `detectedLabel` carries a display TITLE (e.g. "Baby Scratch", from
    /// `ScratchLibrary.Scratch.name`), not a raw scratch-type ID, so title is
    /// matched first; a raw-ID match is a forward-compatible fallback. A bare
    /// "Flare" (any casing, no click count) intentionally matches nothing —
    /// see `ReferenceTechnique`'s no-bare-flare rule.
    static func autoDetectedTechnique(fromDetectedLabel label: String?) -> ReferenceTechnique? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let byTitle = CaptureSessionScratchType.allCases.first(where: {
            $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return ReferenceTechnique(scratchType: byTitle)
        }
        return ReferenceTechnique(scratchTypeID: trimmed)
    }

    // MARK: - Live preflight

    static let disconnectedSnapshot = ReferencePreflightSnapshot(
        controllerName: nil,
        controllerIdentifier: nil,
        observedCrossfaderAddress: nil,
        latestCrossfaderRawValue: nil,
        calibration: nil,
        crossfaderEventCount: 0,
        platterEventCount: 0,
        platterIsMoving: false,
        audioInputPeakLevel: nil,
        audioDeviceName: nil,
        watchIsReachable: false,
        watchMotionIsStreaming: false,
        cameraDeviceName: nil,
        cameraIsActive: false
    )

    private func currentPreflightSnapshot() -> ReferencePreflightSnapshot {
        // Reading @Published state via `DispatchQueue.main.sync` below would
        // deadlock if this were already running on the main thread. Unlike
        // start/stop (which fail loudly with a `Result`), this accessor
        // returns a plain value, so it fails SOFT here instead: an
        // all-blocked snapshot, which is safe (it can never let recording
        // proceed) rather than a crash on the UI thread. Misuse is still
        // discoverable — every row reads "not satisfied" instead of the real
        // engine state, which is a visible, debuggable symptom.
        guard !Thread.isMainThread else {
            return Self.disconnectedSnapshot
        }

        return DispatchQueue.main.sync {
            let controllerName = engine.selectedMIDIInputSourceName
            let connectedMIDI = engine.currentConnectedMIDIObservationsSnapshot()
            let currentObservations = connectedMIDI?.observations ?? []
            let hasController = connectedMIDI != nil && !controllerName.isEmpty && controllerName != "Not Connected"

            let crossfaderMapping = engine.persistedCrossfaderMappingSnapshot
            let crossfaderObservation = crossfaderMapping.map {
                let mapping = $0
                return currentObservations.first { $0.channel == mapping.channel && $0.controller == mapping.controller }
            } ?? nil
            let observedAddress = crossfaderObservation.map {
                CrossfaderMIDIAddress(
                    deviceIdentifier: engine.selectedMIDIInputSourceID,
                    deviceName: $0.deviceName,
                    channel: $0.channel,
                    controller: $0.controller
                )
            }
            let calibration = crossfaderMapping.flatMap {
                engine.crossfaderCalibration(
                    forDeviceIdentifier: engine.selectedMIDIInputSourceID,
                    channel: $0.channel,
                    controller: $0.controller
                )
            }

            let platterObservation = currentObservations.first {
                $0.channel == Self.platterChannel && $0.controller == Self.platterController
            }
            let now = CACurrentMediaTime()
            let platterIsMoving = platterObservation.map {
                now - $0.observedAt < Self.recentActivityWindow
            } ?? false

            // Age of the crossfader's most recent message. Without this the
            // panel could only show a lifetime total, which never decreases
            // and so reads "satisfied" forever after one message.
            let crossfaderAge = crossfaderObservation.map { now - $0.observedAt }
            // Crossfader messages inside the take that is recording RIGHT
            // NOW — the number that actually reaches the sidecar, read from
            // the same non-destructive snapshot of the same buffer
            // finalization drains.
            let isRecording = engine.isRoutineRecording
            let takeScopedCrossfaderCount: Int
            if isRecording, let mapping = crossfaderMapping {
                takeScopedCrossfaderCount = engine.capturedMidiCCEventsSnapshot()
                    .reduce(into: 0) { total, event in
                        if event.channel == mapping.channel, event.controller == mapping.controller {
                            total += 1
                        }
                    }
            } else {
                takeScopedCrossfaderCount = 0
            }
            let observedAddresses = currentObservations.map { observation in
                ReferenceLiveMIDIAddressObservation(
                    deviceName: observation.deviceName,
                    channel: observation.channel,
                    controller: observation.controller,
                    latestRawValue: observation.value,
                    eventCount: observation.eventCount,
                    secondsSinceLastMessage: now - observation.observedAt
                )
            }

            let cameraName = engine.availableVideoDevices
                .first(where: { $0.uniqueID == engine.selectedVideoDeviceUniqueID })?
                .localizedName

            return ReferencePreflightSnapshot(
                controllerName: hasController ? controllerName : nil,
                controllerIdentifier: hasController ? engine.selectedMIDIInputSourceID : nil,
                observedCrossfaderAddress: observedAddress,
                latestCrossfaderRawValue: crossfaderObservation?.value,
                calibration: calibration,
                crossfaderEventCount: crossfaderObservation?.eventCount ?? 0,
                platterEventCount: platterObservation?.eventCount ?? 0,
                platterIsMoving: platterIsMoving,
                audioInputPeakLevel: engine.activeCaptureAudioSignalLevel.map(Double.init),
                audioDeviceName: engine.availableAudioDevices
                    .first(where: { $0.uniqueID == engine.selectedAudioDeviceUniqueID })?
                    .localizedName,
                // Real paired-Watch availability, from the same receiver
                // Capture uses. Previously hardcoded `false`, which made the
                // row say "not connected" whatever the hardware was doing.
                // Never synthesised: with no receiver at all the answer stays
                // `false` and recording is refused.
                watchIsReachable: companionReceiver?.relayedWatchCaptureStore.watchIsReachable ?? false,
                watchMotionIsStreaming: companionReceiver?.relayedWatchCaptureStore.relayState == .active,
                cameraDeviceName: cameraName,
                cameraIsActive: engine.isCameraActive,
                crossfaderSecondsSinceLastMessage: crossfaderAge,
                takeScopedCrossfaderEventCount: takeScopedCrossfaderCount,
                isRecordingTake: isRecording,
                observedMIDIAddresses: observedAddresses
            )
        }
    }

    /// Live reading on the LEARNED crossfader address, tagged with the message
    /// it came from.
    ///
    /// Two deliberate properties:
    ///
    /// 1. `observationSequence` is the engine's per-address lifetime message
    ///    count, which only advances when a real CC message arrives. The
    ///    session uses it to tell a held fader from a silent one — a bare
    ///    value cannot, because this cache keeps returning the last value
    ///    forever. That is what let the 2026-09-04 sweep settle full-left and
    ///    centre on the same stale 0 without the fader moving.
    ///
    /// 2. There is NO "most recently active address of any kind" fallback any
    ///    more. It made the platter's ~800 Hz CC6 stream a candidate source
    ///    for a crossfader calibration whenever no mapping was learned, which
    ///    would calibrate the crossfader against the platter. Without a
    ///    learned mapping this returns `nil` and the sweep simply cannot
    ///    advance, which is the correct fail-closed answer.
    private func latestCalibrationObservation() -> CrossfaderCalibrationObservation? {
        // Same fail-soft rationale as `currentPreflightSnapshot()` above.
        guard !Thread.isMainThread else {
            return nil
        }
        return DispatchQueue.main.sync {
            guard let mapping = engine.persistedCrossfaderMappingSnapshot,
                  let observation = engine.latestCCObservation(
                    channel: mapping.channel,
                    controller: mapping.controller
                  ) else { return nil }
            return CrossfaderCalibrationObservation(
                rawValue: observation.value,
                observationSequence: observation.eventCount
            )
        }
    }

    // MARK: - Finalization-wait cancellation

    /// Cancels only the bridge's in-flight wait. It never starts/stops capture,
    /// deletes an artifact, or promotes/persists reference state. If an explicit
    /// Stop already reached the engine, that engine-owned finalization continues
    /// normally and can be recovered by retrying against the same token.
    func cancelPendingFinalizationWait() {
        cancellationLock.lock()
        finalizationWaitCancellationGeneration &+= 1
        cancellationLock.unlock()
    }

    /// Cancels an in-flight Watch start handshake. Safe at any time: the
    /// handshake task releases only the original Watch identity when its reply
    /// arrives after cancellation, so leaving the screen
    /// mid-handshake cannot orphan a recording wrist.
    func cancelPendingStartHandshake() {
        cancellationLock.lock()
        startHandshakeCancellationGeneration &+= 1
        cancellationLock.unlock()
        DispatchQueue.main.async { [beatEngine] in
            beatEngine.stop()
        }
    }

    private func currentStartHandshakeCancellationGeneration() -> UInt64 {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return startHandshakeCancellationGeneration
    }

    private func startHandshakeWasCancelled(since generation: UInt64) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return startHandshakeCancellationGeneration != generation
    }

    private func currentFinalizationWaitCancellationGeneration() -> UInt64 {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return finalizationWaitCancellationGeneration
    }

    private func finalizationWaitWasCancelled(since generation: UInt64) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return finalizationWaitCancellationGeneration != generation
    }

    // MARK: - Main-thread misuse guard

    private static func mainThreadMisuseError(action: String) -> ReferenceAuthoringError? {
        guard Thread.isMainThread else { return nil }
        return .recordingFailed(
            "ReferenceAuthoringCaptureBridge.\(action) must not be called from the main thread; "
                + "MacCaptureEngine publishes completion on the main actor and calling this from it "
                + "would deadlock. Call it from a background Task."
        )
    }
}
