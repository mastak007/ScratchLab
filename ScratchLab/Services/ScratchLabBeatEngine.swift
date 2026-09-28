import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// A verified playback destination, independent of the recorded scratch stem.
struct BeatPlaybackOutputRoute: Codable, Equatable, Sendable {
    var deviceID: UInt32
    var deviceUID: String
    var deviceName: String
    var channelPair: String
    var channelMap: [Int]
}

/// Hardware routing is supplied by the host; scheduling and PCM stay shared.
protocol BeatPlaybackOutputRouting: AnyObject {
    var route: BeatPlaybackOutputRoute? { get }
    func prepare(_ engine: AVAudioEngine) throws
    func verify(_ engine: AVAudioEngine) throws
    /// Snapshot UI-owned routing choices before enqueuing device work.
    func snapshotForRequest() throws -> any BeatPlaybackOutputRouting
}

extension BeatPlaybackOutputRouting {
    func snapshotForRequest() throws -> any BeatPlaybackOutputRouting { self }
}

protocol ClickTrackTimingEngine: AnyObject {
    func start(
        bpm requestedBPM: Int,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) throws -> ClickTrackStartMetadata
    func startOwned(bpm: Int, isCurrent: @escaping () -> Bool,
                    onCountInBeat: ((Int) -> Void)?, onRecordingStart: (() -> Void)?) throws -> ClickTrackStartMetadata
    func stop()
    func setOutputGain(_ normalizedGain: Double)
}

extension ClickTrackTimingEngine {
    func startOwned(bpm: Int, isCurrent: @escaping () -> Bool,
                    onCountInBeat: ((Int) -> Void)?, onRecordingStart: (() -> Void)?) throws -> ClickTrackStartMetadata {
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        let result = try start(bpm: bpm, onCountInBeat: onCountInBeat, onRecordingStart: onRecordingStart)
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        return result
    }
    func setOutputGain(_ normalizedGain: Double) {}
}

extension ClickTrackEngine: ClickTrackTimingEngine {}

struct BeatEngineStartMetadata: Equatable, Sendable {
    let bpm: Int
    let countInBeats: Int
    let beatsPerBar: Int
    let clickStartHostTime: UInt64
    let recordingStartHostTime: UInt64
    let clickAccentPattern: String
    let clickVersion: String
    let beatEngineMode: BeatEngineMode
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let engineVersion: String
    var outputRoute: BeatPlaybackOutputRoute? = nil
    // Runtime ownership only; not part of CaptureTimingMetadata or export schemas.
    var requestGeneration: UUID? = nil

    /// Shared adapter used by both ordinary capture surfaces. No clock is read
    /// while transporting the prepared start into persisted capture metadata.
    var captureTiming: CaptureTimingMetadata {
        CaptureTimingMetadata(clickStartHostTime: clickStartHostTime,
                              recordingStartHostTime: recordingStartHostTime)
    }
}

/// Immutable host-clock plan for one ordinary start. Wall-clock audit dates
/// describe observed events separately; they never schedule this plan.
struct OrdinaryTimedCaptureOrigin: Equatable, Sendable {
    let generation: UUID
    let playbackStartHostTime: UInt64
    let recordingStartHostTime: UInt64
    let beatDurationSeconds: Double

    init(generation: UUID, preparedAt hostTime: UInt64, leadInSeconds: Double,
         beatDurationSeconds: Double, countInDurationSeconds: Double) {
        self.generation = generation
        self.beatDurationSeconds = beatDurationSeconds
        playbackStartHostTime = hostTime + AVAudioTime.hostTime(forSeconds: leadInSeconds)
        recordingStartHostTime = playbackStartHostTime
            + AVAudioTime.hostTime(forSeconds: countInDurationSeconds)
    }

    func countInHostTime(beatIndex: Int) -> UInt64 {
        playbackStartHostTime + AVAudioTime.hostTime(forSeconds: Double(beatIndex) * beatDurationSeconds)
    }

    /// AVAudio host time and Dispatch uptime share the monotonic uptime clock.
    /// Convert units rather than sampling another "now" to reconstruct a deadline.
    static func deadline(for hostTime: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: UInt64(AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000_000))
    }
}

enum ScratchLabBeatEngineError: LocalizedError {
    case unableToStartAudio
    case supersededStart

    var errorDescription: String? {
        switch self {
        case .unableToStartAudio:
            return "ScratchLab could not start the beat engine."
        case .supersededStart:
            return "The timed audio start was cancelled or replaced."
        }
    }
}

final class ScratchLabBeatEngine: ObservableObject {
    private struct StepVoicing {
        let kick: Bool
        let snare: Bool
        let hat: Bool
        let openHat: Bool
        let ghostSnare: Bool
        let percussion: Bool

        init(
            kick: Bool = false,
            snare: Bool = false,
            hat: Bool = false,
            openHat: Bool = false,
            ghostSnare: Bool = false,
            percussion: Bool = false
        ) {
            self.kick = kick
            self.snare = snare
            self.hat = hat
            self.openHat = openHat
            self.ghostSnare = ghostSnare
            self.percussion = percussion
        }

        static let silent = StepVoicing()
    }

    private static let preRollLeadInSeconds = 0.12
    private static let scheduledStepHorizon = 64

    /// One player timeline: an optional click-only bar followed by the
    /// existing repeating drum pattern. The frame boundary also owns the
    /// recording-start host time; no completion callback starts another engine.
    struct PlaybackSchedule {
        let countInBuffer: AVAudioPCMBuffer?
        let stepBuffers: [AVAudioPCMBuffer]
        let beatFrameLength: Int
        let framesPerBar: Int
        let swingFrameOffset: Int
        let sampleRate: Double

        var patternStartFrame: Int { Int(countInBuffer?.frameLength ?? 0) }
        var countInDurationSeconds: Double { Double(patternStartFrame) / sampleRate }

        func sampleTime(forStepIndex stepIndex: Int) -> AVAudioFramePosition {
            AVAudioFramePosition(patternStartFrame + ScratchLabBeatEngine.sampleTimeForStepIndex(
                stepIndex,
                beatFrames: beatFrameLength,
                framesPerBar: framesPerBar,
                swingFrames: swingFrameOffset
            ))
        }
    }

    struct PreparedPlayback {
        let countInBuffer: AVAudioPCMBuffer
        let loopBuffer: AVAudioPCMBuffer
    }

    private let clickTrackEngine: ClickTrackTimingEngine
    private final class RoutingSnapshot: BeatPlaybackOutputRouting {
        var current: any BeatPlaybackOutputRouting
        init(_ current: any BeatPlaybackOutputRouting) { self.current = current }
        var route: BeatPlaybackOutputRoute? { current.route }
        func prepare(_ engine: AVAudioEngine) throws { try current.prepare(engine) }
        func verify(_ engine: AVAudioEngine) throws { try current.verify(engine) }
    }
    private final class AudioGraph {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        init(format: AVAudioFormat?) {
            engine.attach(player)
            if let format { engine.connect(player, to: engine.mainMixerNode, format: format) }
            engine.prepare()
        }
        func stop() {
            player.stop()
            player.reset()
            if engine.isRunning { engine.stop() }
        }
    }
    private let routingProvider: (any BeatPlaybackOutputRouting)?
    private let outputRouting: RoutingSnapshot?
    private var audioGraph: AudioGraph?
    private var graph: AudioGraph {
        if let audioGraph { return audioGraph }
        let created = AudioGraph(format: playerFormat)
        audioGraph = created
        return created
    }
    private var audioEngine: AVAudioEngine { graph.engine }
    private var playerNode: AVAudioPlayerNode { graph.player }

    // One fixed device worker per existing engine; requests do not create
    // replacement workers when an external call remains blocked.
    let audioOperationQueue: DispatchQueue
    private let audioOperationKey = DispatchSpecificKey<UInt8>()
    private let requestLock = NSLock()
    private var requestGeneration = UUID()
    private var pendingOperation: (() -> Void)?
    private var pendingRejection: (() -> Void)?
    private var activeRejection: (() -> Void)?
    private var operationScheduled = false
    private var desiredGain = 1.0
    private var gainScheduled = false
    private let schedulingQueue = DispatchQueue(label: "scratchlab.beatengine.scheduler")

    private var playerFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 1
    )
    private var currentMode: BeatEngineMode = .silent
    private var currentBPM = CaptureClickTrackDefaults.defaultTimedBPM
    private var currentSwingAmount = 0.0
    private var playbackSchedule: PlaybackSchedule?
    private var preparedPlayback: PreparedPlayback?
    private var scheduledStepCount = 0
    private var consumedStepCount = 0
    private var activeGeneration: UUID {
        get { requestLock.withLock { requestGeneration } }
        set {
            let retired = requestLock.withLock { () -> (() -> Void)? in
                guard requestGeneration != newValue else { return nil }
                requestGeneration = newValue
                let reject = activeRejection
                activeRejection = nil
                return reject
            }
            // Retire the logical client immediately. The device operation may
            // still be inside C and remains owned by the same fixed worker.
            retired?()
        }
    }
    private var isRunning = false
    private var pendingUIWorkItems: [DispatchWorkItem] = []

#if DEBUG
    // Deterministic offline seams: only replace device preparation/output and
    // clock delivery, leaving the production request/origin/callback flow intact.
    var testOnly_preparedOutput: (() throws -> Void)?
    var testOnly_preparedPlaybackScheduled: ((BeatEngineStartMetadata) -> Void)?
    var testOnly_pendingOperationCount: Int { requestLock.withLock { pendingOperation == nil ? 0 : 1 } }
    var testOnly_ordinaryPreparation: (() throws -> PlaybackSchedule)?
    var testOnly_ordinaryHostTime: (() -> UInt64)?
    var testOnly_ordinaryPlaybackScheduled: ((OrdinaryTimedCaptureOrigin) -> Void)?
    var testOnly_ordinaryCallbackScheduled: ((UInt64, @escaping () -> Void) -> Void)?
#endif

    init(clickTrackEngine: ClickTrackTimingEngine? = nil,
         outputRouting: (any BeatPlaybackOutputRouting)? = nil,
         audioOperationQueue: DispatchQueue? = nil) {
        routingProvider = outputRouting
        let routing = outputRouting.map(RoutingSnapshot.init)
        self.outputRouting = routing
        self.clickTrackEngine = clickTrackEngine ?? ClickTrackEngine(outputRouting: routing)
        self.audioOperationQueue = audioOperationQueue
            ?? DispatchQueue(label: "scratchlab.beatengine.device.\(UUID().uuidString)")
        self.audioOperationQueue.setSpecific(key: audioOperationKey, value: 1)
    }

    deinit {
        // The queue owns final device teardown too; dropping a UI owner never
        // joins an external call. No replacement worker is spawned on Stop.
        let retainedGraph = audioGraph
        let click = clickTrackEngine
        audioOperationQueue.async {
            click.stop()
            retainedGraph?.stop()
        }
    }

    private func onAudioQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: audioOperationKey) != nil { return try work() }
        return try audioOperationQueue.sync(execute: work)
    }

    private func enqueueLatest(_ work: @escaping () -> Void, rejected: (() -> Void)? = nil) {
        let admission = requestLock.withLock { () -> (Bool, (() -> Void)?) in
            let old = pendingRejection
            pendingOperation = work
            pendingRejection = rejected
            let schedule = !operationScheduled
            operationScheduled = true
            return (schedule, old)
        }
        admission.1?()
        if admission.0 { audioOperationQueue.async { [weak self] in self?.drainOperations() } }
    }

    private func drainOperations() {
        let work = requestLock.withLock { () -> (() -> Void)? in
            let next = pendingOperation
            activeRejection = pendingRejection
            pendingOperation = nil
            pendingRejection = nil
            return next
        }
        work?()
        let again = requestLock.withLock {
            activeRejection = nil
            if pendingOperation != nil { return true }
            operationScheduled = false
            return false
        }
        if again { audioOperationQueue.async { [weak self] in self?.drainOperations() } }
    }

    /// Main-queue callback delivery can race a worker returning its metadata.
    /// Hold at most the five count-in callbacks until readiness is published.
    private final class CallbackPublication {
        private let completionLock = NSLock()
        private var completed = false
        func claimCompletion() -> Bool {
            completionLock.withLock {
                guard !completed else { return false }
                completed = true
                return true
            }
        }
        private var prepared = false
        private var failed = false
        private var pending: [() -> Void] = []
        func receive(_ callback: @escaping () -> Void) {
            DispatchQueue.main.async {
                guard !self.failed else { return }
                if self.prepared { callback() } else { self.pending.append(callback) }
            }
        }
        func complete(_ result: Result<BeatEngineStartMetadata, Error>,
                      completion: (Result<BeatEngineStartMetadata, Error>) -> Void) {
            completion(result)
            switch result {
            case .success:
                prepared = true
                let callbacks = pending
                pending.removeAll()
                callbacks.forEach { $0() }
            case .failure:
                failed = true
                pending.removeAll()
            }
        }
    }

    /// Nonblocking admission. Routing choices are snapshotted on the caller's
    /// MainActor; device work and its fixed-size replacement mailbox stay here.
    @MainActor @discardableResult
    func requestStart(mode: BeatEngineMode, bpm: Int, usesClickCountIn: Bool = false,
        isStillOwned: @escaping () -> Bool = { true },
        onCountInBeat: ((Int) -> Void)? = nil, onRecordingStart: (() -> Void)? = nil,
        completion: @escaping (Result<BeatEngineStartMetadata, Error>) -> Void) -> UUID {
        let generation = UUID()
        activeGeneration = generation
        let routing = Result { try routingProvider?.snapshotForRequest() }
        let publication = CallbackPublication()
        let current = { [weak self] in self?.activeGeneration == generation && isStillOwned() }
        let deliver: (Result<BeatEngineStartMetadata, Error>) -> Void = { result in
            guard publication.claimCompletion() else { return }
            DispatchQueue.main.async {
                publication.complete(current() ? result : .failure(ScratchLabBeatEngineError.supersededStart),
                                     completion: completion)
            }
        }
        enqueueLatest({ [weak self] in
            guard let self, current() else { deliver(.failure(ScratchLabBeatEngineError.supersededStart)); return }
            do {
                if let snapshot = try routing.get() { self.outputRouting?.current = snapshot }
                _ = try self.startOnAudioQueue(mode: mode, bpm: bpm, usesClickCountIn: usesClickCountIn,
                    generation: generation, isStillOwned: isStillOwned,
                    onCountInBeat: { beat in publication.receive { if current() { onCountInBeat?(beat) } } },
                    onRecordingStart: { publication.receive { if current() { onRecordingStart?() } } },
                    prepared: { deliver(.success($0)) })
            } catch { deliver(.failure(error)) }
        }, rejected: { deliver(.failure(ScratchLabBeatEngineError.supersededStart)) })
        return generation
    }

    @MainActor @discardableResult
    func requestPreparedStart(_ beat: ReferencePreparedBeat, mode: BeatEngineMode, bpm: Int,
        isStillOwned: @escaping () -> Bool,
        onRecordingStart: (() -> Void)? = nil,
        completion: @escaping (Result<BeatEngineStartMetadata, Error>) -> Void) -> UUID {
        let generation = UUID()
        activeGeneration = generation
        let routing = Result { try routingProvider?.snapshotForRequest() }
        let publication = CallbackPublication()
        let current = { [weak self] in self?.activeGeneration == generation && isStillOwned() }
        let deliver: (Result<BeatEngineStartMetadata, Error>) -> Void = { result in
            guard publication.claimCompletion() else { return }
            DispatchQueue.main.async {
                publication.complete(current() ? result : .failure(ScratchLabBeatEngineError.supersededStart),
                                     completion: completion)
            }
        }
        enqueueLatest({ [weak self] in
            guard let self, current() else { deliver(.failure(ScratchLabBeatEngineError.supersededStart)); return }
            do {
                let metadata = try self.start(preparedBeat: beat, mode: mode, bpm: bpm,
                    onRecordingStart: { publication.receive { if current() { onRecordingStart?() } } },
                    reservedStart: (generation, try routing.get()), isStillOwned: isStillOwned)
                deliver(.success(metadata))
            } catch { deliver(.failure(error)) }
        }, rejected: { deliver(.failure(ScratchLabBeatEngineError.supersededStart)) })
        return generation
    }

    /// Verification remains device work. A retired request neither verifies a
    /// successor's graph nor publishes a route failure into that successor.
    func requestPreparedOutputVerification(for metadata: BeatEngineStartMetadata,
        completion: @escaping (Result<BeatPlaybackOutputRoute?, Error>) -> Void) {
        guard isCurrentTimedStart(metadata) else { return }
        audioOperationQueue.async { [weak self] in
            guard let self, self.isCurrentTimedStart(metadata) else { return }
            let result = Result { try self.verifiedPreparedOutputRoute() }
            DispatchQueue.main.async {
                guard self.isCurrentTimedStart(metadata) else { return }
                completion(result)
            }
        }
    }

    func isCurrentRequest(_ generation: UUID) -> Bool { activeGeneration == generation }

    static func currentHostTime() -> UInt64 {
        ClickTrackEngine.currentHostTime()
    }

    func hardResetBeatPlayback() {
        let generation = UUID()
        activeGeneration = generation
        enqueueLatest { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.resetBeatPlayback(for: generation)
        }
    }

    private func resetBeatPlayback(for generation: UUID) {
        cancelPendingUICallbacks()
        clickTrackEngine.stop()

        let isCurrent = schedulingQueue.sync {
            guard self.activeGeneration == generation else { return false }
            self.isRunning = false
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.playbackSchedule = nil
            self.preparedPlayback = nil
            return true
        }
        guard isCurrent else { return }

        playerNode.stop()
        playerNode.reset()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.detach(playerNode)
        audioEngine.reset()
        audioEngine.attach(playerNode)
        if let fmt = playerFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: fmt)
        }
        audioEngine.prepare()
    }

    func start(mode: BeatEngineMode, bpm: Int, usesClickCountIn: Bool = false,
        onCountInBeat: ((Int) -> Void)? = nil, onRecordingStart: (() -> Void)? = nil) throws -> BeatEngineStartMetadata {
        let generation = UUID()
        activeGeneration = generation
        return try onAudioQueue {
            try startOnAudioQueue(mode: mode, bpm: bpm, usesClickCountIn: usesClickCountIn,
                generation: generation, onCountInBeat: onCountInBeat, onRecordingStart: onRecordingStart)
        }
    }

    private func startOnAudioQueue(mode: BeatEngineMode, bpm requestedBPM: Int, usesClickCountIn: Bool,
        generation: UUID, isStillOwned: @escaping () -> Bool = { true },
        onCountInBeat: ((Int) -> Void)?, onRecordingStart: (() -> Void)?,
        prepared: ((BeatEngineStartMetadata) -> Void)? = nil) throws -> BeatEngineStartMetadata {
        guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
        resetBeatPlayback(for: generation)
        guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }

        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        if mode == .clickTrack {
            let clickMetadata = try clickTrackEngine.startOwned(
                bpm: bpm, isCurrent: { [weak self] in self?.activeGeneration == generation && isStillOwned() },
                onCountInBeat: onCountInBeat,
                onRecordingStart: onRecordingStart
            )
            let metadata = BeatEngineStartMetadata(
                bpm: clickMetadata.bpm,
                countInBeats: clickMetadata.countInBeats,
                beatsPerBar: clickMetadata.beatsPerBar,
                clickStartHostTime: clickMetadata.clickStartHostTime,
                recordingStartHostTime: clickMetadata.recordingStartHostTime,
                clickAccentPattern: clickMetadata.clickAccentPattern,
                clickVersion: clickMetadata.clickVersion,
                beatEngineMode: .clickTrack,
                beatEnabled: false,
                beatPatternName: nil,
                beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
                swingAmount: 0,
                engineVersion: CaptureBeatEngineDefaults.engineVersion,
                outputRoute: outputRouting?.route,
                requestGeneration: generation
            )
            prepared?(metadata)
            return metadata
        }

        // Stop or a newer start invalidates this exact request.
        let schedule: PlaybackSchedule
        do {
#if DEBUG
            if let prepare = testOnly_ordinaryPreparation {
                schedule = try prepare()
            } else {
                schedule = try prepareOrdinaryPlayback(mode: mode, bpm: bpm, usesClickCountIn: usesClickCountIn,
                    isCurrent: { self.activeGeneration == generation && isStillOwned() })
            }
#else
            schedule = try prepareOrdinaryPlayback(mode: mode, bpm: bpm, usesClickCountIn: usesClickCountIn,
                    isCurrent: { self.activeGeneration == generation && isStillOwned() })
#endif
        } catch {
            // A failed obsolete preparation must not stop its successor.
            if activeGeneration == generation { stopAudioOnQueue() }
            throw error
        }

        let origin: OrdinaryTimedCaptureOrigin? = schedulingQueue.sync {
            guard self.activeGeneration == generation, isStillOwned() else { return nil }
            self.currentMode = mode
            self.currentBPM = bpm
            self.currentSwingAmount = mode.defaultSwingAmount
            self.isRunning = true
            self.playbackSchedule = schedule
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
#if DEBUG
            let offline = self.testOnly_ordinaryPreparation != nil
#else
            let offline = false
#endif
            if !offline {
                if let countInBuffer = schedule.countInBuffer {
                    self.playerNode.scheduleBuffer(countInBuffer,
                        at: AVAudioTime(sampleTime: 0, atRate: schedule.sampleRate), options: [])
                }
                self.scheduleStepsIfNeeded()
            }
            // Route, startup, PCM and initial buffer scheduling are complete.
            // No startup cost can consume this request's timed lead-in.
#if DEBUG
            let preparedAt = self.testOnly_ordinaryHostTime?() ?? Self.currentHostTime()
#else
            let preparedAt = Self.currentHostTime()
#endif
            let beatDuration = schedule.countInBuffer != nil
                ? Double(schedule.beatFrameLength) / schedule.sampleRate : 60.0 / Double(bpm)
            return OrdinaryTimedCaptureOrigin(generation: generation, preparedAt: preparedAt,
                leadInSeconds: Self.preRollLeadInSeconds, beatDurationSeconds: beatDuration,
                countInDurationSeconds: schedule.countInBuffer != nil
                    ? schedule.countInDurationSeconds
                    : Double(CaptureClickTrackDefaults.countInBeats) * beatDuration)
        }
        guard let origin else { throw ScratchLabBeatEngineError.supersededStart }
#if DEBUG
        if testOnly_ordinaryPreparation != nil {
            testOnly_ordinaryPlaybackScheduled?(origin)
        } else {
            playerNode.play(at: AVAudioTime(hostTime: origin.playbackStartHostTime))
        }
#else
        playerNode.play(at: AVAudioTime(hostTime: origin.playbackStartHostTime))
#endif
        let metadata = BeatEngineStartMetadata(
            bpm: bpm,
            countInBeats: CaptureClickTrackDefaults.countInBeats,
            beatsPerBar: CaptureClickTrackDefaults.beatsPerBar,
            clickStartHostTime: origin.playbackStartHostTime,
            recordingStartHostTime: origin.recordingStartHostTime,
            clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
            clickVersion: CaptureClickTrackDefaults.clickVersion,
            beatEngineMode: mode,
            beatEnabled: mode.beatEnabled,
            beatPatternName: mode.beatPatternName,
            beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
            swingAmount: mode.defaultSwingAmount,
            engineVersion: CaptureBeatEngineDefaults.engineVersion,
            outputRoute: outputRouting?.route,
                requestGeneration: generation
        )
        prepared?(metadata)
        scheduleOrdinaryUICallbacks(origin: origin,
            onCountInBeat: onCountInBeat, onRecordingStart: onRecordingStart)
        return metadata
    }

    /// Recheck at the consuming actor boundary, not only before enqueuing a
    /// callback. A cancelled/replaced start can never authorize a later take.
    func isCurrentTimedStart(_ metadata: BeatEngineStartMetadata) -> Bool {
        guard let generation = metadata.requestGeneration else { return false }
        return activeGeneration == generation
    }

    private func prepareOrdinaryPlayback(mode: BeatEngineMode, bpm: Int,
                                         usesClickCountIn: Bool, isCurrent: () -> Bool) throws -> PlaybackSchedule {
        let sampleRate = resolvedSampleRate()
        try configurePlayerFormat(sampleRate: sampleRate)
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        try outputRouting?.prepare(audioEngine)
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        if !audioEngine.isRunning { try audioEngine.start() }
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        try outputRouting?.verify(audioEngine)
        guard isCurrent() else { throw ScratchLabBeatEngineError.supersededStart }
        return try Self.makePlaybackSchedule(mode: mode, bpm: bpm,
            sampleRate: sampleRate, usesClickCountIn: usesClickCountIn)
    }

    private func scheduleOrdinaryUICallbacks(origin: OrdinaryTimedCaptureOrigin,
                                           onCountInBeat: ((Int) -> Void)?,
                                           onRecordingStart: (() -> Void)?) {
        cancelPendingUICallbacks()
        func schedule(at hostTime: UInt64, _ callback: @escaping () -> Void) {
            let delivery = { [weak self] in
                guard let self, self.schedulingQueue.sync(execute: {
                    self.activeGeneration == origin.generation
                }) else { return }
                callback()
            }
#if DEBUG
            if let schedule = testOnly_ordinaryCallbackScheduled {
                schedule(hostTime, delivery)
                return
            }
#endif
            let workItem = DispatchWorkItem(block: delivery)
            pendingUIWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: OrdinaryTimedCaptureOrigin.deadline(for: hostTime),
                                          execute: workItem)
        }
        for index in 0..<CaptureClickTrackDefaults.countInBeats {
            schedule(at: origin.countInHostTime(beatIndex: index)) {
                onCountInBeat?((index % CaptureClickTrackDefaults.beatsPerBar) + 1)
            }
        }
        schedule(at: origin.recordingStartHostTime) { onRecordingStart?() }
    }

    /// CXL playback consumes the exact verified production WAV that is bound
    /// to the take. The four-click prefix runs once; the remaining frames loop
    /// on this same player node without a timer or renderer transition.
    func start(
        preparedBeat: ReferencePreparedBeat,
        mode: BeatEngineMode,
        bpm: Int,
        onCountInBeat: ((Int) -> Void)? = nil,
        onRecordingStart: (() -> Void)? = nil,
        reservedStart: (UUID, (any BeatPlaybackOutputRouting)?)? = nil,
        isStillOwned: @escaping () -> Bool = { true }
    ) throws -> BeatEngineStartMetadata {
        let generation = reservedStart?.0 ?? UUID()
        if reservedStart == nil { activeGeneration = generation }
        return try onAudioQueue {
        guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
        if let routing = reservedStart?.1 { outputRouting?.current = routing }
        resetBeatPlayback(for: generation)
        do {
            let playback = try Self.loadPreparedPlayback(preparedBeat: preparedBeat, mode: mode, bpm: bpm)
            let sampleRate = playback.loopBuffer.format.sampleRate
#if DEBUG
            let offline = testOnly_preparedOutput != nil
            if let prepare = testOnly_preparedOutput {
                try prepare()
                guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            } else {
            try configurePlayerFormat(sampleRate: sampleRate, channelCount: playback.loopBuffer.format.channelCount)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try outputRouting?.prepare(audioEngine)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try audioEngine.start()
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try outputRouting?.verify(audioEngine)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            }
#else
            let offline = false
            try configurePlayerFormat(sampleRate: sampleRate, channelCount: playback.loopBuffer.format.channelCount)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try outputRouting?.prepare(audioEngine)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try audioEngine.start()
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
            try outputRouting?.verify(audioEngine)
            guard activeGeneration == generation, isStillOwned() else { throw ScratchLabBeatEngineError.supersededStart }
#endif
            currentMode = mode
            currentBPM = bpm
            currentSwingAmount = mode.defaultSwingAmount
            let countInFrames = playback.countInBuffer.frameLength
            let clickStart = Self.currentHostTime() + AVAudioTime.hostTime(forSeconds: Self.preRollLeadInSeconds)
            let recordingStart = clickStart + AVAudioTime.hostTime(forSeconds: Double(countInFrames) / sampleRate)
            schedulingQueue.sync {
                self.isRunning = true
                self.preparedPlayback = playback
                if !offline {
                self.playerNode.scheduleBuffer(
                    playback.countInBuffer,
                    at: AVAudioTime(sampleTime: 0, atRate: sampleRate), options: []
                )
                self.playerNode.scheduleBuffer(
                    playback.loopBuffer,
                    at: AVAudioTime(sampleTime: AVAudioFramePosition(countInFrames), atRate: sampleRate),
                    options: [.loops]
                )
                }
            }
            if !offline { playerNode.play(at: AVAudioTime(hostTime: clickStart)) }
            scheduleUICallbacks(
                generation: generation, bpm: bpm, countInStartHostTime: clickStart,
                countInBeatDurationSeconds: Double(countInFrames) / 4.0 / sampleRate,
                recordingStartHostTime: recordingStart,
                onCountInBeat: onCountInBeat, onRecordingStart: onRecordingStart
            )
            let metadata = BeatEngineStartMetadata(
                bpm: bpm, countInBeats: 4, beatsPerBar: 4,
                clickStartHostTime: clickStart, recordingStartHostTime: recordingStart,
                clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
                clickVersion: CaptureClickTrackDefaults.clickVersion,
                beatEngineMode: mode, beatEnabled: mode.beatEnabled,
                beatPatternName: mode.beatPatternName,
                beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
                swingAmount: mode.defaultSwingAmount,
                engineVersion: CaptureBeatEngineDefaults.engineVersion,
                outputRoute: outputRouting?.route,
                requestGeneration: generation
            )
#if DEBUG
            testOnly_preparedPlaybackScheduled?(metadata)
#endif
            return metadata
        } catch {
            if activeGeneration == generation { stopAudioOnQueue() }
            throw error
        }
        }
    }

    /// A hardware-free loading seam shared by playback and its PCM regressions.
    /// Revalidate the bound set each time; a stale prepared URL is not evidence.
    static func loadPreparedPlayback(
        preparedBeat: ReferencePreparedBeat,
        mode: BeatEngineMode,
        bpm: Int
    ) throws -> PreparedPlayback {
        let verified = try ReferenceBeatAssetStore.resolve(
            binding: preparedBeat.binding,
            rootURL: preparedBeat.directoryURL.deletingLastPathComponent()
        )
        guard verified == preparedBeat, verified.mode == mode, verified.binding.bpm == bpm else {
            throw ReferenceBeatAssetError.invalid("playback mode or BPM differs from the prepared binding")
        }
        let file = try AVAudioFile(forReading: verified.productionMasterURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        func readFrames(_ frameCount: Int64) throws -> AVAudioPCMBuffer {
            guard frameCount > 0, frameCount <= Int64(UInt32.max),
                  let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                  let destination = result.floatChannelData,
                  let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
                  let source = chunk.floatChannelData else {
                throw ReferenceBeatAssetError.invalid("the production WAV could not be decoded")
            }
            var copied: Int64 = 0
            while copied < frameCount {
                chunk.frameLength = 0
                try file.read(into: chunk, frameCount: AVAudioFrameCount(min(frameCount - copied, Int64(chunk.frameCapacity))))
                guard chunk.frameLength > 0 else {
                    throw ReferenceBeatAssetError.invalid("the production WAV ended before its bound frame count")
                }
                let length = min(Int(chunk.frameLength), Int(frameCount - copied))
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    destination[channel].advanced(by: Int(copied)).update(from: source[channel], count: length)
                }
                copied += Int64(length)
            }
            result.frameLength = AVAudioFrameCount(frameCount)
            return result
        }
        let countIn = try readFrames(verified.binding.countInFrameCount)
        let loop = try readFrames(verified.binding.loopFrameCount)
        let hashAfterRead = SHA256.hash(data: try Data(contentsOf: verified.productionMasterURL))
            .map { String(format: "%02x", $0) }.joined()
        guard file.framePosition == file.length, hashAfterRead == verified.binding.productionMasterSHA256 else {
            throw ReferenceBeatAssetError.invalid("the production WAV changed while playback was loading")
        }
        return PreparedPlayback(countInBuffer: countIn, loopBuffer: loop)
    }

    /// Recheck after the count-in, immediately before the capture is armed.
    func verifiedPreparedOutputRoute() throws -> BeatPlaybackOutputRoute? {
        try outputRouting?.verify(audioEngine)
        return outputRouting?.route
    }

    func stop() {
        let generation = UUID()
        activeGeneration = generation
        enqueueLatest { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.stopAudioOnQueue()
        }
    }

    private func stopAudioOnQueue() {
        clickTrackEngine.stop()
        cancelPendingUICallbacks()
        schedulingQueue.sync {
            self.isRunning = false
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.playbackSchedule = nil
            self.preparedPlayback = nil
        }
        audioGraph?.stop()
    }

    func setOutputGain(_ normalizedGain: Double) {
        let gain = min(max(normalizedGain.isFinite ? normalizedGain : 0, 0), 1)
        let enqueue = requestLock.withLock {
            desiredGain = gain
            if gainScheduled { return false }
            gainScheduled = true
            return true
        }
        guard enqueue else { return }
        audioOperationQueue.async { [weak self] in
            guard let self else { return }
            let gain = self.requestLock.withLock {
                self.gainScheduled = false
                return self.desiredGain
            }
            self.playerNode.volume = Float(gain)
            self.clickTrackEngine.setOutputGain(gain)
        }
    }

    /// Peak-level policy for audio ScratchLab *generates* (timing/beat stems and
    /// the scratch+timing mix).
    ///
    /// Summed percussion voices routinely overshoot full scale, and the old
    /// export clamped the overshoot sample-by-sample, which is hard clipping:
    /// it is audible, it is irreversible, and it makes a stem that no longer
    /// matches what the pattern actually is. Instead every generated buffer is
    /// attenuated by one constant linear gain until its peak sits at the
    /// ceiling. Attenuation only — a quiet pattern is never boosted — so the
    /// operation is a pure gain and cannot change frame counts, timing, or the
    /// relative shape of the waveform.
    enum GeneratedAudioHeadroom {
        /// Ceiling for stems ScratchLab renders on its own (beat_only).
        static let generatedStemCeilingDBFS: Double = -1.0
        /// Ceiling for the scratch + timing mix.
        ///
        /// Deliberately close to full scale rather than matching the generated
        /// stem ceiling. The mix contains *captured* audio, and the captured
        /// scratch in the regression fixture already peaks at -0.234 dBFS; a
        /// -1 dBFS mix ceiling would force an attenuation of the recording
        /// itself just to make room for a stem ScratchLab generated. The mix
        /// instead holds the scratch at unity and reduces only the timing
        /// contribution — see `SessionArchiveBuilder.mixScratchWithTiming`.
        static let mixCeilingDBFS: Double = -0.1

        static func amplitude(forDBFS dbfs: Double) -> Float {
            Float(pow(10.0, dbfs / 20.0))
        }

        static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
            guard let channels = buffer.floatChannelData else { return 0 }
            let frameCount = Int(buffer.frameLength)
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    peak = max(peak, abs(samples[frame]))
                }
            }
            return peak
        }

        /// Attenuates `buffer` in place so its peak is at most `ceilingDBFS`.
        /// Returns the gain that was applied (1.0 when nothing was needed).
        @discardableResult
        static func applyCeiling(_ ceilingDBFS: Double, to buffer: AVAudioPCMBuffer) -> Float {
            let ceiling = amplitude(forDBFS: ceilingDBFS)
            let peak = peakAmplitude(of: buffer)
            guard peak > ceiling, peak.isFinite, peak > 0,
                  let channels = buffer.floatChannelData else { return 1 }

            let gain = ceiling / peak
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    samples[frame] *= gain
                }
            }
            return gain
        }
    }

    static func renderedTimingBuffer(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        durationSeconds: Double,
        countInBeats: Int,
        beatsPerBar: Int,
        clickStartHostTime: UInt64?,
        recordingStartHostTime: UInt64?,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        exactFrameCount: AVAudioFrameCount? = nil
    ) throws -> AVAudioPCMBuffer {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let startBeatIndex = resolvedStartBeatIndex(
            bpm: bpm,
            countInBeats: countInBeats,
            clickStartHostTime: clickStartHostTime,
            recordingStartHostTime: recordingStartHostTime
        )

        if mode == .clickTrack {
            let clickBuffer = try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: bpm,
                durationSeconds: durationSeconds,
                sampleRate: sampleRate,
                channelCount: channelCount,
                startBeatIndex: startBeatIndex,
                exactFrameCount: exactFrameCount
            )
            GeneratedAudioHeadroom.applyCeiling(
                GeneratedAudioHeadroom.generatedStemCeilingDBFS,
                to: clickBuffer
            )
            return clickBuffer
        }

        let totalFrameCount = max(
            1,
            exactFrameCount.map(Int.init)
                ?? Int(ceil(max(0, durationSeconds) * sampleRate))
        )
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrameCount)
        ),
        let channelData = buffer.floatChannelData else {
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        buffer.frameLength = AVAudioFrameCount(totalFrameCount)
        for channel in 0..<Int(channelCount) {
            channelData[channel].initialize(repeating: 0, count: totalFrameCount)
        }

        guard mode != .silent else { return buffer }

        let renderedSteps = makeRenderedStepSamples(mode: mode, sampleRate: sampleRate)
        let beatFrames = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        let framesPerBar = beatFrames * beatsPerBar
        let swingFrames = Int((Double(beatFrames) * mode.defaultSwingAmount).rounded())
        let startStepIndex = max(0, startBeatIndex * 2)
        let renderedDurationSeconds = Double(totalFrameCount) / sampleRate
        let totalStepCount = Int(ceil(renderedDurationSeconds / max(0.0001, 60.0 / Double(bpm) / 2.0))) + 8

        for stepIndex in startStepIndex..<(startStepIndex + totalStepCount) {
            let stepInBar = stepIndex % renderedSteps.count
            let stepSamples = renderedSteps[stepInBar]
            guard !stepSamples.isEmpty else { continue }
            let relativeStepIndex = stepIndex - startStepIndex
            let sampleTime = sampleTimeForStepIndex(
                relativeStepIndex,
                beatFrames: beatFrames,
                framesPerBar: framesPerBar,
                swingFrames: swingFrames
            )
            guard sampleTime < totalFrameCount else { break }
            for frameOffset in 0..<stepSamples.count {
                let frameIndex = sampleTime + frameOffset
                guard frameIndex < totalFrameCount else { break }
                let sample = stepSamples[frameOffset]
                for channel in 0..<Int(channelCount) {
                    channelData[channel][frameIndex] += sample
                }
            }
        }

        // Overlapping kick/snare/hat voices sum past full scale on the
        // downbeat. Pull the whole stem back to the headroom ceiling with one
        // gain instead of clipping individual samples.
        GeneratedAudioHeadroom.applyCeiling(
            GeneratedAudioHeadroom.generatedStemCeilingDBFS,
            to: buffer
        )

        return buffer
    }

    private func resolvedSampleRate() -> Double {
        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        return sampleRate > 0 ? sampleRate : 48_000
    }

    private func configurePlayerFormat(sampleRate: Double, channelCount: AVAudioChannelCount = 1) throws {
        guard let requestedFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        guard playerFormat?.sampleRate != requestedFormat.sampleRate
                || playerFormat?.channelCount != requestedFormat.channelCount else { return }

        playerNode.stop()
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: requestedFormat)
        playerFormat = requestedFormat
    }

    static func makePlaybackSchedule(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        sampleRate: Double,
        usesClickCountIn: Bool = false
    ) throws -> PlaybackSchedule {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let beatFrames = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        let countInFrames = beatFrames * CaptureClickTrackDefaults.countInBeats
        let countInBuffer: AVAudioPCMBuffer?
        if usesClickCountIn && mode.beatEnabled {
            countInBuffer = try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: bpm,
                durationSeconds: Double(countInFrames) / sampleRate,
                sampleRate: sampleRate,
                channelCount: 1,
                startBeatIndex: 0,
                exactFrameCount: AVAudioFrameCount(countInFrames)
            )
        } else {
            countInBuffer = nil
        }
        let stepBuffers = makeStepBuffers(mode: mode, sampleRate: sampleRate)
        guard !stepBuffers.isEmpty else { throw ScratchLabBeatEngineError.unableToStartAudio }
        return PlaybackSchedule(
            countInBuffer: countInBuffer,
            stepBuffers: stepBuffers,
            beatFrameLength: beatFrames,
            framesPerBar: beatFrames * CaptureClickTrackDefaults.beatsPerBar,
            swingFrameOffset: Int((Double(beatFrames) * mode.defaultSwingAmount).rounded()),
            sampleRate: sampleRate
        )
    }

    private static func makeStepBuffers(mode: BeatEngineMode, sampleRate: Double) -> [AVAudioPCMBuffer] {
        let renderedSteps = Self.makeRenderedStepSamples(mode: mode, sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return []
        }

        return renderedSteps.compactMap { stepSamples in
            let frameCount = max(1, stepSamples.count)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channelData = buffer.floatChannelData?.pointee else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            channelData.initialize(repeating: 0, count: frameCount)
            if !stepSamples.isEmpty {
                stepSamples.withUnsafeBufferPointer { samples in
                    guard let baseAddress = samples.baseAddress else { return }
                    memcpy(
                        channelData,
                        baseAddress,
                        min(frameCount, samples.count) * MemoryLayout<Float>.size
                    )
                }
            }
            return buffer
        }
    }

    private static func makeRenderedStepSamples(mode: BeatEngineMode, sampleRate: Double) -> [[Float]] {
        let kick = kickSamples(sampleRate: sampleRate)
        let snare = snareSamples(
            sampleRate: sampleRate,
            aggressive: [.battleLoop, .pocketDouble, .dropTheory].contains(mode),
            ghost: false
        )
        let ghostSnare = snareSamples(sampleRate: sampleRate, aggressive: false, ghost: true)
        let hat = hatSamples(sampleRate: sampleRate)
        let openHat = openHatSamples(sampleRate: sampleRate)
        let percussion = percussionSamples(sampleRate: sampleRate)
        return stepPattern(for: mode).map { step in
            mixStepSamples(
                kick: step.kick ? kick : [],
                snare: step.snare ? snare : [],
                ghostSnare: step.ghostSnare ? ghostSnare : [],
                hat: step.hat ? hat : [],
                openHat: step.openHat ? openHat : [],
                percussion: step.percussion ? percussion : []
            )
        }
    }

    private func scheduleStepsIfNeeded() {
        while isRunning, scheduledStepCount - consumedStepCount < Self.scheduledStepHorizon {
            scheduleStep(at: scheduledStepCount, generation: activeGeneration)
            scheduledStepCount += 1
        }
    }

    private func scheduleStep(at stepIndex: Int, generation: UUID) {
        guard let playbackSchedule, !playbackSchedule.stepBuffers.isEmpty else { return }
        guard let playerFormat else { return }
        let stepBuffer = playbackSchedule.stepBuffers[stepIndex % playbackSchedule.stepBuffers.count]
        let sampleTime = playbackSchedule.sampleTime(forStepIndex: stepIndex)

        playerNode.scheduleBuffer(
            stepBuffer,
            at: AVAudioTime(sampleTime: AVAudioFramePosition(sampleTime), atRate: playerFormat.sampleRate),
            options: [],
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            guard let self else { return }
            self.schedulingQueue.async {
                guard self.isRunning, self.activeGeneration == generation else { return }
                self.consumedStepCount += 1
                self.scheduleStepsIfNeeded()
            }
        }
    }

    private static func sampleTimeForStepIndex(
        _ stepIndex: Int,
        beatFrames: Int,
        framesPerBar: Int,
        swingFrames: Int
    ) -> Int {
        let stepInBar = stepIndex % 8
        let barIndex = stepIndex / 8
        let beatIndex = stepInBar / 2
        let isOffbeat = stepInBar % 2 == 1

        var frame = (barIndex * framesPerBar) + (beatIndex * beatFrames)
        if isOffbeat {
            frame += max(1, beatFrames / 2) + swingFrames
        }
        return frame
    }

    private func scheduleUICallbacks(
        generation: UUID,
        bpm: Int,
        countInStartHostTime: UInt64?,
        countInBeatDurationSeconds: Double,
        recordingStartHostTime: UInt64?,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) {
        cancelPendingUICallbacks()

        let beatDurationSeconds = 60.0 / Double(bpm)
        func delay(until hostTime: UInt64) -> Double {
            let now = Self.currentHostTime()
            return hostTime > now ? AVAudioTime.seconds(forHostTime: hostTime - now) : 0
        }
        for beatIndex in 0..<CaptureClickTrackDefaults.countInBeats {
            let beatNumber = (beatIndex % CaptureClickTrackDefaults.beatsPerBar) + 1
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.activeGeneration == generation else { return }
                onCountInBeat?(beatNumber)
            }
            pendingUIWorkItems.append(workItem)
            let beatDelay = countInStartHostTime.map {
                delay(until: $0 + AVAudioTime.hostTime(forSeconds: Double(beatIndex) * countInBeatDurationSeconds))
            } ?? (Self.preRollLeadInSeconds + Double(beatIndex) * beatDurationSeconds)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + beatDelay,
                execute: workItem
            )
        }

        let recordingStartItem = DispatchWorkItem { [weak self] in
            guard self?.activeGeneration == generation else { return }
            onRecordingStart?()
        }
        pendingUIWorkItems.append(recordingStartItem)
        let recordingDelay = recordingStartHostTime.map { delay(until: $0) }
            ?? (Self.preRollLeadInSeconds + Double(CaptureClickTrackDefaults.countInBeats) * beatDurationSeconds)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + recordingDelay,
            execute: recordingStartItem
        )
    }

    private func cancelPendingUICallbacks() {
        pendingUIWorkItems.forEach { $0.cancel() }
        pendingUIWorkItems.removeAll()
    }

    private static func resolvedStartBeatIndex(
        bpm: Int,
        countInBeats: Int,
        clickStartHostTime: UInt64?,
        recordingStartHostTime: UInt64?
    ) -> Int {
        guard let clickStartHostTime,
              let recordingStartHostTime,
              recordingStartHostTime > clickStartHostTime else {
            return countInBeats
        }

        let beatDurationHostTime = AVAudioTime.hostTime(forSeconds: 60.0 / Double(bpm))
        guard beatDurationHostTime > 0 else { return countInBeats }
        let delta = recordingStartHostTime - clickStartHostTime
        let beatOffset = Int((Double(delta) / Double(beatDurationHostTime)).rounded())
        return max(0, beatOffset)
    }

    private static func stepPattern(for mode: BeatEngineMode) -> [StepVoicing] {
        switch mode {
        case .silent:
            return Array(repeating: .silent, count: 8)
        case .clickTrack:
            return Array(repeating: .silent, count: 8)
        case .boomBapTrainer:
            return [
                StepVoicing(kick: true, hat: true, percussion: true),
                StepVoicing(hat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, percussion: true),
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, ghostSnare: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, openHat: true, percussion: true)
            ]
        case .minimalFunk:
            return [
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, percussion: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, ghostSnare: true),
                StepVoicing(kick: true, hat: true, percussion: true),
                StepVoicing(hat: true, openHat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, ghostSnare: true, percussion: true)
            ]
        case .battleLoop:
            return [
                StepVoicing(kick: true, hat: true, percussion: true),
                StepVoicing(hat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(kick: true, ghostSnare: true, percussion: true),
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, openHat: true, ghostSnare: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, percussion: true)
            ]
        case .ghostPocket:
            return [
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, ghostSnare: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(kick: true, hat: true, percussion: true),
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, openHat: true),
                StepVoicing(snare: true, hat: true, ghostSnare: true),
                StepVoicing(hat: true, percussion: true)
            ]
        case .pocketDouble:
            return [
                StepVoicing(kick: true, hat: true, percussion: true),
                StepVoicing(hat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, percussion: true),
                StepVoicing(kick: true, hat: true, ghostSnare: true),
                StepVoicing(hat: true, openHat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(kick: true, hat: true, percussion: true)
            ]
        case .dropTheory:
            return [
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true, openHat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(kick: true, ghostSnare: true, percussion: true),
                StepVoicing(kick: true, hat: true),
                StepVoicing(hat: true),
                StepVoicing(snare: true, hat: true),
                StepVoicing(hat: true, openHat: true, percussion: true)
            ]
        }
    }

    private static func mixStepSamples(
        kick: [Float],
        snare: [Float],
        ghostSnare: [Float],
        hat: [Float],
        openHat: [Float],
        percussion: [Float]
    ) -> [Float] {
        let frameCount = max(1, [kick, snare, ghostSnare, hat, openHat, percussion].map(\.count).max() ?? 0)
        var samples = Array(repeating: Float(0), count: frameCount)

        for (source, gain) in [
            (kick, Float(1.0)),
            (snare, Float(0.88)),
            (ghostSnare, Float(0.38)),
            (hat, Float(0.34)),
            (openHat, Float(0.28)),
            (percussion, Float(0.42))
        ] {
            for index in 0..<source.count {
                samples[index] += source[index] * gain
            }
        }

        return samples
    }

    private static func kickSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.18).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let frequency = 120.0 * exp(-time * 10.0) + 42.0
            let envelope = exp(-time * 18.0)
            let body = sin(2.0 * .pi * frequency * time)
            let transient = sin(2.0 * .pi * 240.0 * time) * exp(-time * 42.0)
            let saturated = tanh((body + (transient * 0.3)) * 1.25)
            return Float(saturated * envelope) * 0.92
        }
    }

    private static func snareSamples(sampleRate: Double, aggressive: Bool, ghost: Bool) -> [Float] {
        let frameCount = max(1, Int((sampleRate * (ghost ? 0.075 : 0.19)).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * (ghost ? 48.0 : (aggressive ? 27.0 : 23.0)))
            let noise = deterministicNoise(frame: frame, seed: aggressive ? 31 : 17)
            let filteredNoise = noise - (frame > 0 ? deterministicNoise(frame: frame - 1, seed: aggressive ? 31 : 17) * 0.72 : 0)
            let tone = sin(2.0 * .pi * (aggressive ? 205.0 : 185.0) * time) * exp(-time * 15.0)
            let clap = sin(2.0 * .pi * 1_450.0 * time) * exp(-time * 42.0)
            return Float(((filteredNoise * 0.62) + (tone * 0.34) + (clap * 0.16)) * envelope)
                * (ghost ? 0.52 : (aggressive ? 1.0 : 0.9))
        }
    }

    private static func hatSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.055).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 72.0)
            let noise = deterministicNoise(frame: frame, seed: 71)
            let metallic = sin(2.0 * .pi * 7_400.0 * time) + sin(2.0 * .pi * 10_100.0 * time)
            return Float((noise * 0.42 + metallic * 0.09) * envelope)
        }
    }

    private static func openHatSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.19).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 25.0)
            let noise = deterministicNoise(frame: frame, seed: 91)
            let metallic = sin(2.0 * .pi * 7_900.0 * time) + sin(2.0 * .pi * 11_300.0 * time)
            return Float((noise * 0.3 + metallic * 0.075) * envelope)
        }
    }

    private static func percussionSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.11).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 34.0)
            let tone = sin(2.0 * .pi * 420.0 * time) + sin(2.0 * .pi * 690.0 * time)
            let click = deterministicNoise(frame: frame, seed: 113) * exp(-time * 75.0)
            return Float((tone * 0.16 + click * 0.3) * envelope)
        }
    }

    private static func deterministicNoise(frame: Int, seed: Int) -> Double {
        var value = UInt64(bitPattern: Int64(frame &* 1_664_525 &+ seed &* 1_013_904_223))
        value ^= value >> 13
        value &*= 1_274_126_177
        value ^= value >> 16
        return (Double(value & 0xFFFF) / 32_767.5) - 1.0
    }
}
