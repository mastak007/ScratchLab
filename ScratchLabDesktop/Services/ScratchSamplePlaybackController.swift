// ScratchSamplePlaybackController.swift
// ScratchLab Desktop — Platter-Driven Scratch Sample Playback
//
// AVAudioEngine-based sample playback driven by CC6 platter position.
// Loads bundled WAVs into PCM buffers; maps accumulated platter steps to
// sample position; schedules short audio segments for forward/backward scratch.
//
// Owned by MacCaptureEngine. Output = system default audio device.
// No MIDI routing. No scoring. No Rane audio device routing.
//
// Thread model: load, ensureLoadedForDVSDrive, pausePlayback, resumePlayback,
// unload, and setCrossfader are safe to call from any thread, including the
// CoreMIDI callback thread — they enqueue work on a private serial audioQueue
// and return immediately. positionDidChange is different: it runs its
// complete trace + scheduling transaction synchronously on audioQueue (via
// runSynchronouslyOnAudioQueue), serialized with the async work above, so the
// caller blocks for a bounded scheduling operation instead of racing it.

import AVFoundation
import Foundation

/// Drives sample playback from a `ScratchPlatterTracker` position.
/// - Hot cue press: loads the corresponding bundled WAV (async, off CoreMIDI thread).
/// - Platter CC6 movement: updates playback position and schedules audio, as a
///   bounded synchronous transaction on `audioQueue` (caller blocks).
/// - No motion: audio stops after the current short segment plays out.
final class ScratchSamplePlaybackController {

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeedNode = AVAudioUnitVarispeed()

    // MARK: - Serial audio queue

    // All AVAudioEngine, AVAudioPlayerNode, AVAudioFile, and AVAudioPCMBuffer
    // work is confined here. Public methods async-dispatch to it and return
    // immediately, keeping the CoreMIDI callback thread unblocked.
    private let audioQueue = DispatchQueue(
        label: "com.scratchlab.samplePlayback",
        qos: .userInteractive
    )
    /// Marks `audioQueue` so `runSynchronouslyOnAudioQueue` can tell whether
    /// it is already executing there and avoid a self-deadlocking `sync`.
    private let audioQueueKey = DispatchSpecificKey<Void>()
    private let schedulingClock: () -> TimeInterval

    // MARK: - Loaded sample state (access confined to audioQueue)

    private(set) var loadedSampleID: String?
    private var forwardBuffer: AVAudioPCMBuffer?
    private(set) var totalFrames: Int = 0
    private var lastScheduledSteps: Int = 0
    private var lastScheduledDirection: ScratchPlatterDirection?
    private var lastScheduleTime: Double = 0
    private var diagnosticPreviewPlayedSampleID: String?
    private(set) var currentSampleFrame: Int = 0
    private var lastPlatterSteps: Int?
    private var framesPerStep: Double = 1
    private(set) var lastScheduledSourceFrame: Int?
    private(set) var lastScheduledSegmentFrames: Int?
    private(set) var lastScheduledRate: Float?
    private(set) var lastScheduleSkippedReason: String?
    private(set) var lastEffectiveFrameDelta: Int?
    private(set) var lastReversalCompensated: Bool = false
    private var forwardScheduleCount = 0
    private var backwardScheduleCount = 0
    private(set) var pendingDVSControlWindow: TimeInterval = 0
    private(set) var estimatedDVSQueuedDuration: TimeInterval = 0
    private var lastDVSQueueEstimateAt: TimeInterval?
    private(set) var lastDVSConsumedControlWindow: TimeInterval?
    private(set) var lastDVSScheduledOutputWindow: TimeInterval?

#if DEBUG
    /// CACurrentMediaTime of the most recent `positionDidChange` entry — for measuring
    /// elapsed between consecutive calls at this layer. Read by [DVS-TRACE:4].
    private var _lastPositionDidChangeTime: TimeInterval = 0

    /// Whether the player node is currently playing. Exposed for cross-module trace
    /// logging (MacCaptureEngine reads it for [DVS-TRACE:3]).
    var isPlaying: Bool { playerNode.isPlaying }

    /// One real scheduled grain exactly as queued onto `playerNode` — the
    /// PCM (post edge-fade, post time-stretch) plus the timing metadata
    /// needed to reconstruct actual output-time placement offline, without a
    /// running AVAudioEngine/device.
    struct ScheduledGrainSnapshot {
        let direction: ScratchPlatterDirection
        let interrupts: Bool
        let nodeRate: Float
        let scheduledOutputWindow: TimeInterval
        let sourceFrame: Int
        let sampleRate: Double
        let channelData: [[Float]]
        /// Whether this grain went through `copyTimeStretched` — the sub-0.25x
        /// software time-stretch path used when the physical rate falls below
        /// `AVAudioUnitVarispeed`'s floor. Lets offline diagnosis separate
        /// software-stretched grain boundaries from normal-varispeed ones.
        let usesSoftwareSlowGrain: Bool
        /// Raw source-frame count feeding `copyTimeStretched` before
        /// stretching (i.e. `segmentFrames`) — how few real samples were
        /// available to reconstruct the grain's full output window.
        let rawSourceFrameCount: Int
    }

    /// Test/diagnostic-only hook: invoked synchronously on the audio queue
    /// immediately before `scheduleBuffer`, with the exact buffer and timing
    /// that was queued. `nil` by default; production and hardware code paths
    /// never set it, and setting it does not change what gets scheduled.
    /// Used by the offline scheduled-grain renderer to reconstruct real
    /// playback in a WAV for discontinuity/overlap/underrun diagnosis.
    var scheduledGrainObserver: ((ScheduledGrainSnapshot) -> Void)?

    private func channelData(of buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: frameCount))
        }
    }
#endif

    /// Set when the most recent `loadOnQueue` attempt failed after the
    /// synchronous URL-resolution check passed (file open error, unreadable
    /// PCM, etc.) — the failure class `ensureLoadedForDVSDrive`'s boolean
    /// return value cannot report, because that return only reflects
    /// whether a load was successfully *queued*, not whether the queued
    /// load actually completed. `nil` after a successful load. Cleared at
    /// the start of every load attempt so a stale error from a previous
    /// sample doesn't linger.
    private(set) var lastLoadError: String?

    // MARK: - Rate-limit / segment constants

    /// Minimum interval between scheduleBuffer calls (seconds).
    private let minScheduleInterval: Double = 1.0 / 60.0

    /// Segment duration scheduled per position update (seconds).
    private let segmentDuration: Double = 1.0 / 60.0

    /// Nominal vinyl RPM for normal-speed playback (33⅓ RPM).
    private static let nominalVinylRPM: Double = 100.0 / 3.0

    /// Controller steps per platter revolution (Rane ONE MKII CC6).
    private let stepsPerRevolution: Int = 3932

    /// Minimum CC6 step delta that produces a continuous-sounding grain.
    /// Below ~9 steps/slot at 33⅓ RPM, the varispeed floor (0.25) cannot
    /// stretch the grain to fill the 16.7 ms scheduling slot, producing a
    /// rapid on/off/on sputter ("farting"). Silently track the needle;
    /// suppress the grain.
    private let minAudibleDeltaSteps = 9

    /// Maximum frameDelta to borrow from the previous direction when
    /// compensating the first grain after a reversal. Caps the symmetry
    /// compensation so a very fast push doesn't produce a pathological
    /// jump on the matching return stroke. ~1500 frames ≈ 34 ms of audio.
    private let reversalSymmetryCapFrames = 1500

    /// Varispeed rate clamps — mirrors AVAudioUnitVarispeed's supported range.
    private let minVarispeedRate: Float = 0.25
    private let maxVarispeedRate: Float = 4.0

    /// A small output-time reserve maintained by DVS grains. The control
    /// worker and the audio device are independent clocks; scheduling exactly
    /// one elapsed control window on every timer callback leaves no protection
    /// against ordinary sub-millisecond timer jitter and produces underruns.
    ///
    /// The reserve is restored only when the estimate falls below this target,
    /// so it remains bounded instead of adding latency on every grain.
    private let dvsQueueCushion: TimeInterval = 0.004

    /// Matches the control pipeline's maximum trusted elapsed interval. It also
    /// bounds accumulated zero-step/early-tick time after a scheduling stall.
    private let maximumDVSControlWindow: TimeInterval = 0.25

    /// PCM frames ramped from/to zero at the leading and trailing edge of each
    /// scheduled scratch grain. The ramp smooths the hard PCM cut that would
    /// otherwise cause a click when the waveform value at the cut point is non-zero.
    /// Clamped to at most half the grain's frame count, so tiny grains are never
    /// fully zeroed. Not applied to the diagnostic load preview.
    let grainEdgeFadeFrames = 32

    // MARK: - Engine state

    private var engineStarted = false
    // engineLock guards engineStarted across deinit (any thread) and
    // ensureEngineRunning (audioQueue), preventing concurrent start/stop.
    private let engineLock = NSLock()

    // MARK: - Published state (main thread only)

    @Published var statusLabel: String = "idle"
    @Published var crossfaderGate: Float = 1.0
    @Published var lastCrossfaderRawValue: Int? = nil

    // MARK: - Lifecycle

    init(schedulingClock: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.schedulingClock = schedulingClock
        audioQueue.setSpecific(key: audioQueueKey, value: ())
        engine.attach(playerNode)
        engine.attach(varispeedNode)
        engine.connect(playerNode, to: varispeedNode, format: nil)
        engine.connect(varispeedNode, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        stopEngine()
    }

    private func debugPublishOnMainAsync(field: String, _ body: @escaping () -> Void) {
        let requestTime = CACurrentMediaTime()
        let requestThread = Thread.isMainThread ? "main" : "background"
        print("[SwiftUIStateGuard] publish request · field=ScratchSamplePlaybackController.\(field) thread=\(requestThread) time=\(String(format: "%.6f", requestTime))")

        DispatchQueue.main.async(execute: body)
    }

    // MARK: - Engine start/stop (audioQueue or deinit only)

    private func ensureEngineRunning() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !engineStarted else { return }
        do {
            try engine.start()
            engineStarted = true
            playerNode.play()
            print("[ScratchSamplePlaybackController] engine started, output = system default")
        } catch {
            print("[ScratchSamplePlaybackController] engine start failed: \(error)")
        }
    }

    private func stopEngine() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard engineStarted else { return }
        playerNode.stop()
        engine.stop()
        engineStarted = false
    }

    // MARK: - Sample loading

    /// Load a bundled sample into the playback buffer.
    ///
    /// Returns false synchronously only if the sample ID is unknown or the WAV
    /// is absent from the bundle. Actual file I/O, buffer preparation, and
    /// engine startup run on the audio queue; the caller returns immediately.
    @discardableResult
    func load(sampleID: String) -> Bool {
        print("[ScratchSamplePlaybackController] load requested · sampleID=\(sampleID)")
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            debugPublishOnMainAsync(field: "statusLabel.missing") { [weak self] in
                self?.statusLabel = "missing: \(sampleID)"
            }
            return false
        }
        audioQueue.async { [weak self] in
            self?.loadOnQueue(sampleID: sampleID, url: url)
        }
        return true
    }

    /// Ensures `sampleID` is loaded before DVS-driven position updates can
    /// reach `positionDidChange`. Unlike `load(sampleID:)`, this is
    /// idempotent: if `sampleID` is already the loaded sample, it does
    /// nothing — safe to call on every DVS evaluation tick without reload
    /// churn or resetting `currentSampleFrame` mid-scratch. The idempotency
    /// check runs on the audio queue (where `loadedSampleID` is mutated),
    /// so it is race-free regardless of the caller's thread.
    ///
    /// Returns false synchronously only if the sample ID is unknown or the
    /// WAV is absent from the bundle — same failure contract as
    /// `load(sampleID:)`. Does not affect manual `load(sampleID:)` callers
    /// (hot-cue pads, crossfader trigger, debug button), which always
    /// reload/reset as before.
    @discardableResult
    func ensureLoadedForDVSDrive(sampleID: String) -> Bool {
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            debugPublishOnMainAsync(field: "statusLabel.missing") { [weak self] in
                self?.statusLabel = "missing: \(sampleID)"
            }
            return false
        }
        audioQueue.async { [weak self] in
            guard let self, self.loadedSampleID != sampleID else { return }
            self.loadOnQueue(sampleID: sampleID, url: url)
        }
        return true
    }

    private func loadOnQueue(sampleID: String, url: URL) {
        print("[ScratchSamplePlaybackController] sample load queued: \(sampleID)")
        lastLoadError = nil
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            print("[ScratchSamplePlaybackController] failed to open \(sampleID): \(error)")
            lastLoadError = "open failed: \(error.localizedDescription)"
            debugPublishOnMainAsync(field: "statusLabel.error") { [weak self] in
                self?.statusLabel = "error: \(sampleID)"
            }
            return
        }

        guard let buffer = readIntoBuffer(file) else {
            print("[ScratchSamplePlaybackController] failed to read PCM for \(sampleID)")
            lastLoadError = "unreadable PCM"
            return
        }

        forwardBuffer = buffer
        totalFrames = Int(buffer.frameLength)
        loadedSampleID = sampleID
        lastScheduledSteps = 0
        lastScheduledDirection = nil
        lastScheduleTime = 0
        currentSampleFrame = 0
        lastPlatterSteps = nil
        // 33⅓ RPM → 1.8 s/rev → normal-speed playback allocates
        // (sampleRate × 1.8) frames per revolution, distributed across
        // controller steps. This way the varispeed graph hits rate=1.0
        // when the platter turns at nominal vinyl speed, regardless of
        // sample length — a 1 s snare and a 10 s bass both play back at
        // the same pitch for the same platter speed.
        let vinylSecondsPerRevolution = 60.0 / Self.nominalVinylRPM
        let rate = Double(buffer.format.sampleRate)
        framesPerStep = max(1, (rate * vinylSecondsPerRevolution) / Double(stepsPerRevolution))
        lastScheduledSourceFrame = nil
        lastScheduledSegmentFrames = nil
        lastScheduledRate = nil
        forwardScheduleCount = 0
        backwardScheduleCount = 0
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = nil
        lastReversalCompensated = false
        resetDVSGrainTiming()
        varispeedNode.rate = 1.0

        ensureEngineRunning()

        if diagnosticPreviewPlayedSampleID == sampleID {
            print("[ScratchSamplePlaybackController] diagnostic preview skipped · sampleID=\(sampleID)")
        } else {
            diagnosticPreviewPlayedSampleID = sampleID

            // HARDWARE DIAGNOSTIC: prove AVAudioEngine + playerNode + loaded sample are audible.
            let previewFrames = min(
                Int(buffer.format.sampleRate * 0.35),
                Int(buffer.frameLength)
            )

            if let preview = copySegment(
                from: buffer,
                startFrame: 0,
                frameCount: previewFrames
            ) {
                playerNode.stop()
                engine.mainMixerNode.outputVolume = 1.0
                playerNode.scheduleBuffer(
                    preview,
                    at: nil,
                    options: [],
                    completionHandler: {
                        print("[ScratchSamplePlaybackController] diagnostic preview completed")
                    }
                )
                playerNode.volume = 1.0
                playerNode.play()
                print("[ScratchSamplePlaybackController] diagnostic preview scheduled · \(previewFrames) frames")
            } else {
                print("[ScratchSamplePlaybackController] diagnostic preview failed")
            }
        }

        print("[ScratchSamplePlaybackController] loaded \(sampleID)")
        print("[ScratchSamplePlaybackController] ready for platter · sampleID=\(sampleID) totalFrames=\(totalFrames) framesPerStep=\(String(format: "%.2f", framesPerStep))")
        debugPublishOnMainAsync(field: "statusLabel.loaded") { [weak self] in
            self?.statusLabel = "loaded: \(sampleID) · system default"
        }
    }

    // MARK: - Position-driven playback

    /// Called when platter position changes. Runs the complete trace +
    /// scheduling transaction synchronously on `audioQueue`, serialized with
    /// load/unload/pause/resume/crossfader work, so the caller (CoreMIDI
    /// callback thread or the DVS worker) blocks until this tick's
    /// scheduling transaction is fully applied — no stale DVS scheduling
    /// backlog, and no interleaving with the other queue-confined mutations.
    /// `runSynchronouslyOnAudioQueue` avoids a self-deadlock if this is ever
    /// reached while already running on `audioQueue`.
    func positionDidChange(steps: Int, direction: ScratchPlatterDirection?, segmentWindow: TimeInterval? = nil) {
        runSynchronouslyOnAudioQueue {
            #if DEBUG
            let _ts = DVSTrace.current
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            let _dt = (_tm - self._lastPositionDidChangeTime) * 1000
            let _swStr = segmentWindow.map { sw in String(format: "%.3f", sw) }
            let _dirStr = direction.map { d in "\(d)" } ?? "nil"
            let _swDisplay = _swStr ?? "nil"
            DVSTrace.log("[DVS-TRACE:4] playbackController positionDidChange seq=\(_ts) monotonic=\(_tm) dt=\(_dt)ms steps=\(steps) dir=\(_dirStr) segmentWindow=\(_swDisplay) thread=\(_thr)")
            self._lastPositionDidChangeTime = _tm
            #endif
            self.positionDidChangeOnQueue(steps: steps, direction: direction, segmentWindow: segmentWindow)
        }
    }

    /// Runs `work` on `audioQueue`, executing it directly when already
    /// running there (instead of a self-deadlocking `audioQueue.sync`) and
    /// otherwise dispatching via `sync` so the caller blocks until `work`
    /// completes. Direct execution is safe because `audioQueue` is serial —
    /// nothing else can be interleaved either way.
    private func runSynchronouslyOnAudioQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: audioQueueKey) != nil {
            work()
        } else {
            audioQueue.sync(execute: work)
        }
    }

    private func positionDidChangeOnQueue(steps: Int, direction: ScratchPlatterDirection?, segmentWindow: TimeInterval? = nil) {
        let now = schedulingClock()
#if DEBUG
        let tScheduleEntry = now
#endif

        let dvsWindow: TimeInterval?
        if let segmentWindow, segmentWindow.isFinite {
            let sanitized = min(max(segmentWindow, 0), maximumDVSControlWindow)
            pendingDVSControlWindow = min(
                maximumDVSControlWindow,
                pendingDVSControlWindow + sanitized
            )
            dvsWindow = sanitized
        } else {
            dvsWindow = nil
        }

        // MIDI can arrive much faster than the grain cadence and retains its
        // existing ~60 Hz limiter. DVS already comes from a coalescing 60 Hz
        // serial worker; applying the same exact boundary a second time makes
        // harmless timer jitter discard alternating grains. Crucially, the
        // rejected tick's platter steps still accumulate, while its elapsed
        // window does not, inflating the next rate and leaving an audio hole.
        guard dvsWindow != nil || now - lastScheduleTime >= minScheduleInterval else {
            #if DEBUG
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            let _elapsed = now - lastScheduleTime
            let _minInt = minScheduleInterval
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(CACurrentMediaTime()) reason=rateLimit steps=\(steps) elapsed=\(_elapsed)s min=\(_minInt)s thread=\(_thr)")
            #endif
            return
        }

        guard direction != nil else {
            resetDVSGrainTiming()
            lastScheduleSkippedReason = "noDirection"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=noDirection steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noDirection steps=\(steps) thread=\(_thr)")
            #endif
            return
        }

        guard let forward = forwardBuffer, totalFrames > 0 else {
            resetDVSGrainTiming()
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noBuffer steps=\(steps) hasBuffer=\(forwardBuffer != nil) totalFrames=\(totalFrames) thread=\(_thr)")
            #endif
            return
        }

        guard let previousSteps = lastPlatterSteps else {
            lastPlatterSteps = steps
            resetDVSGrainTiming()
            lastScheduleSkippedReason = "priming"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=priming steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=priming steps=\(steps) thread=\(_thr)")
            #endif
            return
        }

        let deltaResult = steps.subtractingReportingOverflow(previousSteps)
        let deltaSteps = deltaResult.overflow ? (steps >= previousSteps ? Int.max : Int.min) : deltaResult.partialValue
        let deltaStepMagnitude: Double
        if deltaResult.overflow || deltaSteps == Int.min {
            deltaStepMagnitude = Double(Int.max)
        } else {
            deltaStepMagnitude = Double(abs(deltaSteps))
        }
        guard deltaStepMagnitude > 0 else {
            lastScheduleSkippedReason = "noMotion"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=noMotion steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noMotion steps=\(steps) thread=\(_thr)")
            #endif
            return
        }

        // Scheduling direction comes from deltaSteps sign — the unambiguous physical
        // signal. The tracker direction (passed as a parameter) uses a 16-event window
        // that lags ~20ms at 800Hz; relying on it caused mismatch skips that silenced
        // the first ~16 grains after every reversal and prevented the needle from
        // returning to its cue position. The `direction` parameter is used only as a
        // nil-guard above and is not consulted for actual scheduling direction.
        let schedulingDirection: ScratchPlatterDirection = deltaSteps > 0 ? .forward : .backward

        // The sample loops at its own length: frame 0 is the "12 o'clock" loop
        // origin, and `totalFrames` is the loop end. Motion is never blocked at
        // either edge — `wrappedSampleFrame` carries it around instead, so the
        // needle simply continues into the wrapped region. `currentSampleFrame`
        // is always kept in [0, totalFrames) by wrapping (see below), so it can
        // never itself sit exactly at a boundary the way the old clamp did.

        let sourceTotalFrames = Int(forward.frameLength)
        let frameDeltaDouble = min(Double(sourceTotalFrames), (deltaStepMagnitude * framesPerStep).rounded())
        let frameDelta = max(1, Int(frameDeltaDouble))
        let consumedControlWindow = dvsWindow == nil
            ? segmentDuration
            : max(pendingDVSControlWindow, 0.001)
        let requestedFrames = Int(
            forward.format.sampleRate * consumedControlWindow
        )

        // Skip pathologically tiny grains (a single PCM sample), which would
        // produce an audible click. This guard catches literal single-sample
        // grains (frameDelta=1) that can only occur with atypically short
        // samples. The nearStop gate below handles musical near-stop motion.
        let minimumGrainFrames = 2
        guard frameDelta >= minimumGrainFrames else {
            lastScheduleSkippedReason = "tinyGrain"
            lastPlatterSteps = steps
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=tinyGrain steps=\(steps) frameDelta=\(frameDelta) minimum=\(minimumGrainFrames)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=tinyGrain steps=\(steps) frameDelta=\(frameDelta) minimum=\(minimumGrainFrames) thread=\(_thr)")
            #endif
            return
        }

        // Near-stop gate for the MIDI path: when the platter moves too slowly,
        // the varispeed floor (0.25) cannot stretch the grain to fill the
        // scheduling slot. DVS calls provide an explicit `segmentWindow`; those
        // grains use deterministic software stretching below the varispeed floor
        // later in this method, preserving slow captured motion without gaps.
        let minAudibleFrameDelta = max(1, Int(Double(minAudibleDeltaSteps) * framesPerStep))
        let permitsSoftwareSlowGrain = dvsWindow != nil
        guard frameDelta >= minAudibleFrameDelta || permitsSoftwareSlowGrain else {
            switch schedulingDirection {
            case .forward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame + frameDelta)
            case .backward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame - frameDelta)
            }
            lastScheduleSkippedReason = "nearStop"
            lastPlatterSteps = steps
            lastScheduleTime = now
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=nearStop deltaSteps=\(deltaSteps) threshold=\(minAudibleFrameDelta) frameDelta=\(frameDelta)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=nearStop deltaSteps=\(deltaSteps) threshold=\(minAudibleFrameDelta) frameDelta=\(frameDelta) thread=\(_thr)")
            #endif
            return
        }

        // Reversal symmetry: the first grain after a direction change is
        // starved by the 60 Hz rate limiter — the new direction's motion
        // only accumulates during the ~16.7 ms gap. This creates an
        // asymmetry where the last forward grain covers ~727 frames but
        // the first backward grain covers only ~101 frames, causing the
        // start point to drift forward on every baby-scratch cycle.
        //
        // Compensate by borrowing the last direction's effective frameDelta,
        // capped so a very fast push doesn't produce a pathological jump on
        // the matching return stroke.
        let isDirectionChange = schedulingDirection != lastScheduledDirection
        let reversalCompensated: Bool
        let effectiveFrameDelta: Int
        if isDirectionChange,
           let lastEff = lastEffectiveFrameDelta {
            let borrowed = min(lastEff, reversalSymmetryCapFrames)
            if borrowed > frameDelta {
                effectiveFrameDelta = borrowed
                reversalCompensated = true
            } else {
                effectiveFrameDelta = frameDelta
                reversalCompensated = false
            }
        } else {
            effectiveFrameDelta = frameDelta
            reversalCompensated = false
        }

        #if DEBUG
        let _tsEntry = DVSTrace.current
        let _tEntry = tScheduleEntry
        let _thr = Thread.current.isMainThread ? "main" : "bg"
        DVSTrace.log("[DVS-TRACE:5] playbackController scheduleEntry seq=\(_tsEntry) monotonic=\(_tEntry) steps=\(steps) deltaSteps=\(deltaSteps) schedulingDir=\(directionDescription(schedulingDirection)) frameDelta=\(frameDelta) effectiveFrameDelta=\(effectiveFrameDelta) requestedFrames=\(requestedFrames) currentFrame=\(currentSampleFrame) reversalCompensated=\(reversalCompensated) playerNodePlaying=\(playerNode.isPlaying) thread=\(_thr)")
#endif

        // DVS maintains only a small bounded queue reserve. On reversal,
        // preserve that tail and enqueue the opposite-direction grain after it:
        // interrupting would discard valid PCM and turn every direction change
        // into an audible truncation. The resulting direction latency is
        // bounded by the reserve (normally about 4 ms). MIDI retains its
        // existing immediate interrupt behavior.
        let interruptsQueuedAudio = dvsWindow == nil && isDirectionChange
        let outputTiming = dvsWindow.map { _ in
            dvsOutputTiming(
                controlWindow: consumedControlWindow,
                now: now,
                interruptsQueuedAudio: interruptsQueuedAudio
            )
        }
        let scheduledOutputWindow = outputTiming?.outputWindow ?? consumedControlWindow
        let scheduledOutputFrames = Int(
            forward.format.sampleRate * scheduledOutputWindow
        )

        // Varispeed rate = platter-driven frame displacement / output window size.
        // A grain of effectiveFrameDelta frames played at this rate consumes exactly
        // its scheduled output window. DVS reports the physical rate against
        // the matching accumulated control window; a one-time/bounded cushion
        // may make the actual node rate slightly lower while the queue reserve
        // is replenished.
        let physicalRawRate = Double(effectiveFrameDelta) / Double(requestedFrames)
        let scheduledRawRate = Double(effectiveFrameDelta) / Double(scheduledOutputFrames)
        let usesSoftwareSlowGrain = permitsSoftwareSlowGrain &&
            scheduledRawRate < Double(minVarispeedRate)
        let nodeRate = usesSoftwareSlowGrain
            ? Float(1)
            : Float(max(Double(minVarispeedRate), min(Double(maxVarispeedRate), scheduledRawRate)))
        let reportedRate = permitsSoftwareSlowGrain
            ? Float(max(0, min(Double(maxVarispeedRate), physicalRawRate)))
            : nodeRate
        varispeedNode.rate = nodeRate

        let sourceFrame: Int
        let segmentFrames: Int
        var segment: AVAudioPCMBuffer?

        switch schedulingDirection {
        case .forward:
            sourceFrame = currentSampleFrame
            segmentFrames = effectiveFrameDelta
            segment = copyWrappedForwardSegment(
                from: forward,
                startFrame: sourceFrame,
                frameCount: segmentFrames
            )
            currentSampleFrame = wrappedSampleFrame(currentSampleFrame + effectiveFrameDelta)
        case .backward:
            sourceFrame = currentSampleFrame
            segmentFrames = effectiveFrameDelta
            segment = copyWrappedReversedSegmentEnding(
                at: sourceFrame,
                frameCount: segmentFrames,
                from: forward
            )
            currentSampleFrame = wrappedSampleFrame(currentSampleFrame - effectiveFrameDelta)
        }
        if usesSoftwareSlowGrain, let sourceSegment = segment {
            segment = copyTimeStretched(
                sourceSegment,
                outputFrameCount: scheduledOutputFrames
            )
        }

        #if DEBUG
        DVSTrace.log("[ScratchSamplePlaybackController] platter state · steps=\(steps) deltaSteps=\(deltaSteps) direction=\(directionDescription(schedulingDirection)) currentFrame=\(currentSampleFrame) effectiveFrameDelta=\(effectiveFrameDelta) totalFrames=\(sourceTotalFrames)")
        DVSTrace.log("[ScratchSamplePlaybackController] schedule input · steps=\(steps) direction=\(directionDescription(schedulingDirection)) sourceFrame=\(sourceFrame) segmentFrames=\(segmentFrames) rate=\(String(format: "%.3f", reportedRate)) nodeRate=\(String(format: "%.3f", nodeRate)) softwareSlow=\(usesSoftwareSlowGrain) totalFrames=\(sourceTotalFrames)")
        #endif

        let isValidSegment: Bool
        switch schedulingDirection {
        case .forward:
            isValidSegment = sourceFrame >= 0 &&
                sourceFrame < sourceTotalFrames &&
                segmentFrames > 0 &&
                segmentFrames <= sourceTotalFrames
        case .backward:
            isValidSegment = sourceFrame >= 0 &&
                sourceFrame < sourceTotalFrames &&
                segmentFrames > 0 &&
                segmentFrames <= sourceTotalFrames
        }

        guard isValidSegment else {
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(sourceFrame) frames=\(segmentFrames) totalFrames=\(sourceTotalFrames)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=invalidSegment sourceFrame=\(sourceFrame) frames=\(segmentFrames) totalFrames=\(sourceTotalFrames) thread=\(_thr)")
            #endif
            lastScheduleSkippedReason = "invalidSegment"
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        guard let segment else {
            lastScheduleSkippedReason = "copyFailed"
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=copyFailed sourceFrame=\(sourceFrame) frames=\(segmentFrames) thread=\(_thr)")
            #endif
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        // Contiguous queued source segments meet at adjacent PCM frames and
        // must not be faded to zero: doing so amplitude-modulates playback at
        // the scheduler rate. Only the legacy MIDI reversal path interrupts
        // the node and therefore retains its edge fade.
        if interruptsQueuedAudio {
            applyEdgeFade(to: segment)
        }

        let opts: AVAudioPlayerNodeBufferOptions = interruptsQueuedAudio ? .interrupts : []
#if DEBUG
        let _scheduleThread = Thread.current.isMainThread ? "main" : "bg"
        let _optsStr = opts == .interrupts ? "interrupts" : "none"
        DVSTrace.log("[DVS-TRACE:6] playbackController scheduleBuffer seq=\(DVSTrace.current) monotonic=\(CACurrentMediaTime()) dir=\(directionDescription(schedulingDirection)) rate=\(reportedRate) nodeRate=\(nodeRate) softwareSlow=\(usesSoftwareSlowGrain) segmentFrames=\(segmentFrames) segmentWindow=\(segmentWindow ?? segmentDuration) opts=\(_optsStr) playerNodePlaying=\(playerNode.isPlaying) sourceFrame=\(sourceFrame) currentFrame=\(currentSampleFrame) thread=\(_scheduleThread)")
#endif
#if DEBUG
        if let observer = scheduledGrainObserver {
            observer(
                ScheduledGrainSnapshot(
                    direction: schedulingDirection,
                    interrupts: opts == .interrupts,
                    nodeRate: nodeRate,
                    scheduledOutputWindow: scheduledOutputWindow,
                    sourceFrame: sourceFrame,
                    sampleRate: forward.format.sampleRate,
                    channelData: channelData(of: segment),
                    usesSoftwareSlowGrain: usesSoftwareSlowGrain,
                    rawSourceFrameCount: segmentFrames
                )
            )
        }
#endif
        playerNode.scheduleBuffer(
            segment,
            at: nil,
            options: opts,
            completionHandler: nil
        )

        if !playerNode.isPlaying {
            playerNode.play()
        }

        lastScheduledSteps = steps
        lastScheduledDirection = schedulingDirection
        if schedulingDirection == .forward {
            forwardScheduleCount += 1
        } else {
            backwardScheduleCount += 1
        }
        lastScheduleTime = now
        lastPlatterSteps = steps
        lastScheduledSourceFrame = sourceFrame
        lastScheduledSegmentFrames = segmentFrames
        lastScheduledRate = reportedRate
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = effectiveFrameDelta
        lastReversalCompensated = reversalCompensated
        if let outputTiming {
            estimatedDVSQueuedDuration = outputTiming.estimatedQueuedDuration
            lastDVSQueueEstimateAt = now
            lastDVSConsumedControlWindow = consumedControlWindow
            lastDVSScheduledOutputWindow = scheduledOutputWindow
            pendingDVSControlWindow = 0
        }
    }

    private func dvsOutputTiming(
        controlWindow: TimeInterval,
        now: TimeInterval,
        interruptsQueuedAudio: Bool
    ) -> (outputWindow: TimeInterval, estimatedQueuedDuration: TimeInterval) {
        let elapsedSinceEstimate = lastDVSQueueEstimateAt.map {
            max(0, now - $0)
        } ?? .infinity
        let remainingQueue = interruptsQueuedAudio
            ? 0
            : max(0, estimatedDVSQueuedDuration - elapsedSinceEstimate)
        let cushionTopUp = max(0, dvsQueueCushion - remainingQueue)
        let outputWindow = controlWindow + cushionTopUp
        return (
            outputWindow,
            min(
                controlWindow + dvsQueueCushion,
                remainingQueue + outputWindow
            )
        )
    }

    private func resetDVSGrainTiming() {
        pendingDVSControlWindow = 0
        estimatedDVSQueuedDuration = 0
        lastDVSQueueEstimateAt = nil
        lastDVSConsumedControlWindow = nil
        lastDVSScheduledOutputWindow = nil
    }

    /// Stop playback (e.g. when platter is idle).
    func pausePlayback() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.lastScheduledDirection = nil
            let id = self.loadedSampleID
            self.debugPublishOnMainAsync(field: "statusLabel.paused") { [weak self] in
                guard let self, let id else { return }
                self.statusLabel = "loaded: \(id) · paused"
            }
        }
    }

    /// Resume after pause.
    func resumePlayback() {
        audioQueue.async { [weak self] in
            guard let self, self.loadedSampleID != nil else { return }
            self.playerNode.play()
        }
    }

    /// Unload the current sample and stop audio.
    func unload() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.forwardBuffer = nil
            self.loadedSampleID = nil
            self.totalFrames = 0
            self.lastScheduledSteps = 0
            self.lastScheduledDirection = nil
            self.diagnosticPreviewPlayedSampleID = nil
            self.currentSampleFrame = 0
            self.lastPlatterSteps = nil
            self.lastScheduledSourceFrame = nil
            self.lastScheduledSegmentFrames = nil
            self.lastScheduledRate = nil
            self.forwardScheduleCount = 0
            self.backwardScheduleCount = 0
            self.lastScheduleSkippedReason = nil
            self.lastEffectiveFrameDelta = nil
            self.lastReversalCompensated = false
            self.resetDVSGrainTiming()
            print("[ScratchSamplePlaybackController] unloaded")
            self.debugPublishOnMainAsync(field: "unload") { [weak self] in
                self?.statusLabel = "idle"
                self?.crossfaderGate = 1.0
                self?.lastCrossfaderRawValue = nil
            }
        }
    }

    // MARK: - Crossfader gate

    /// Apply crossfader CC8 value as audio gate.
    ///
    /// Rane ONE MKII: ch=15 CC8, range 0–127.
    ///   - 0   → fully closed (cut, volume 0.0)
    ///   - 127 → fully open (volume 1.0)
    ///
    /// Dispatches to the audio queue and returns immediately.
    func setCrossfader(value: Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let normalized = Float(value) / 127.0
            let raw = value
            self.playerNode.volume = 1.0
            self.debugPublishOnMainAsync(field: "crossfaderGate") { [weak self] in
                self?.crossfaderGate = normalized
                self?.lastCrossfaderRawValue = raw
            }
        }
    }

    // MARK: - Queue drain (test seam and ordered shutdown)

    /// Block the caller until all pending audio-queue work completes.
    ///
    /// Use in tests before reading state that is mutated on the audio queue.
    /// Do not call from within the audio queue itself.
    func waitForAudioQueue() {
        audioQueue.sync {}
    }

    // MARK: - Diagnostics

    /// Point-in-time snapshot of playback state, for distinguishing "no
    /// audio because nothing was ever scheduled" from "scheduling
    /// happened but the output path is silent" — the two failure classes
    /// that look identical from the UI toggle / bridge status alone.
    struct DVSPlaybackDiagnostics: Equatable {
        let loadedSampleID: String?
        let lastLoadError: String?
        let engineRunning: Bool
        let playerIsPlaying: Bool
        let currentSampleFrame: Int
        let lastScheduleSkippedReason: String?
        let lastScheduledRate: Float?
        let lastScheduledSourceFrame: Int?
        let lastScheduledDirection: ScratchPlatterDirection?
        let forwardScheduleCount: Int
        let backwardScheduleCount: Int
    }

    /// Reads all fields together on `audioQueue` so the snapshot is
    /// internally consistent (no torn reads across a concurrent
    /// `positionDidChangeOnQueue` mutation). Safe to call from any
    /// thread, including the main thread on a UI polling timer — the
    /// audioQueue work here is a handful of variable reads, not I/O.
    func diagnosticsSnapshot() -> DVSPlaybackDiagnostics {
        audioQueue.sync {
            DVSPlaybackDiagnostics(
                loadedSampleID: loadedSampleID,
                lastLoadError: lastLoadError,
                engineRunning: engineStarted,
                playerIsPlaying: playerNode.isPlaying,
                currentSampleFrame: currentSampleFrame,
                lastScheduleSkippedReason: lastScheduleSkippedReason,
                lastScheduledRate: lastScheduledRate,
                lastScheduledSourceFrame: lastScheduledSourceFrame,
                lastScheduledDirection: lastScheduledDirection,
                forwardScheduleCount: forwardScheduleCount,
                backwardScheduleCount: backwardScheduleCount
            )
        }
    }

    // MARK: - Position → frame mapping

    /// Map accumulated CC6 steps to a sample frame index.
    /// Cycles within 0..<totalFrames. One full revolution (~3932 steps)
    /// wraps the full sample; forward/backward advances at the
    /// framesPerStep pace (driven by vinyl RPM, not sample length).
    func sampleFrame(for steps: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        let scaled = (Double(steps) * Double(totalFrames)) / Double(stepsPerRevolution)
        var wrapped = scaled.truncatingRemainder(dividingBy: Double(totalFrames))
        if wrapped < 0 { wrapped += Double(totalFrames) }
        return min(max(Int(wrapped), 0), totalFrames - 1)
    }

    /// Wraps a frame index into the loop region `[0, totalFrames)` — the
    /// full loaded sample. Frame 0 is the "12 o'clock" loop origin: crossing
    /// past `totalFrames` wraps to the start, crossing before 0 wraps to the
    /// end, in both cases continuing motion rather than stopping at the edge.
    private func wrappedSampleFrame(_ frame: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        let wrapped = frame % totalFrames
        return wrapped < 0 ? wrapped + totalFrames : wrapped
    }

    /// Apply a symmetric linear fade-in/fade-out ramp to the leading and trailing
    /// `grainEdgeFadeFrames` samples of `buffer`, mutating it in place.
    /// The fade length is clamped to at most half the buffer's frame count so
    /// that tiny grains produced near sample boundaries are never fully zeroed.
    func applyEdgeFade(to buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let f = min(grainEdgeFadeFrames, count / 2)
        guard f > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let data = channels[ch]
            for i in 0..<f {
                let ramp = Float(i) / Float(f)
                data[i]             *= ramp   // fade in: frame 0 → 0.0, frame f-1 → (f-1)/f
                data[count - 1 - i] *= ramp   // fade out: last frame → 0.0
            }
        }
    }

    private func directionDescription(_ direction: ScratchPlatterDirection) -> String {
        switch direction {
        case .forward: return "forward"
        case .backward: return "backward"
        }
    }

    // MARK: - WAV resolution

    private static let sampleFileNames: [String: String] = [
        "ahhh":          "ahhh.wav",
        "dvs_ahhh":      "VirtualPlatter/ahhh.wav",
        "fresh":         "fresh.wav",
        "ah_yeah":       "ah_yeah.wav",
        "check_it_out":  "check_it_out.wav",
    ]

    private func wavURL(for sampleID: String) -> URL? {
        guard let fileName = Self.sampleFileNames[sampleID],
              let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var knownSampleIDs: Set<String> {
        Set(sampleFileNames.keys)
    }

    // MARK: - Buffer helpers

    private func readIntoBuffer(_ file: AVAudioFile) -> AVAudioPCMBuffer? {
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            print("[ScratchSamplePlaybackController] unsupported PCM format after normalization: \(format)")
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            print("[ScratchSamplePlaybackController] read error: \(error)")
            return nil
        }
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            print("[ScratchSamplePlaybackController] normalized buffer unavailable: \(format)")
            return nil
        }
        return buffer
    }

    private func reverseBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = source.format
        let frameCount = Int(source.frameLength)
        guard frameCount > 0,
              let reversed = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        reversed.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = reversed.floatChannelData else {
            print("[ScratchSamplePlaybackController] reverse skipped · reason=unsupportedFormat format=\(format)")
            return nil
        }
        let channelCount = Int(format.channelCount)

        for ch in 0..<channelCount {
            let src = srcChannels[ch]
            let dst = dstChannels[ch]
            for i in 0..<frameCount {
                dst[i] = src[frameCount - 1 - i]
            }
        }
        return reversed
    }

    /// Expands a sub-varispeed-floor DVS grain to its complete control-tick
    /// window. Interpolation keeps the exact source-frame displacement (and
    /// therefore needle position) while producing continuous audio for the
    /// whole window; the player node then runs this prepared grain at 1×.
    ///
    /// With at least 4 raw source frames, adjacent output samples are
    /// reconstructed with Catmull-Rom cubic interpolation instead of a
    /// straight line between the two surrounding raw samples. Plain linear
    /// interpolation collapses a grain's true waveform curvature into a flat
    /// ramp between control points — measured (offline, against the saved
    /// `slow_reversals`/`fast_reversals` hardware captures) to roughly halve
    /// the grain's oscillation/high-frequency content relative to a normal
    /// (non-stretched) grain of the same source. Slow scratch motion spends a
    /// large fraction of its grains on this path (as high as ~38% observed in
    /// `slow_reversals`), so that quality gap dominates the audible character
    /// of slow playback specifically, rather than showing up as a single
    /// isolated boundary click — matching the reported "static-like" texture.
    /// Cubic interpolation uses the same two raw samples the grain would
    /// already interpolate between, plus one real sample of context on each
    /// side (clamped to the segment's own edges), so it recovers more of the
    /// true waveform shape without reading beyond the segment already copied
    /// for this grain and without changing needle position/frame accounting
    /// at all. Grains with only 2-3 raw source frames fall back to the
    /// original linear method — there is no additional real information to
    /// use, and Catmull-Rom degenerates to it in that regime anyway.
    private func copyTimeStretched(
        _ source: AVAudioPCMBuffer,
        outputFrameCount: Int
    ) -> AVAudioPCMBuffer? {
        let inputFrameCount = Int(source.frameLength)
        let format = source.format
        guard inputFrameCount >= 2,
              outputFrameCount >= inputFrameCount,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let inputChannels = source.floatChannelData,
              let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(outputFrameCount)
              ),
              let outputChannels = output.floatChannelData else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(outputFrameCount)

        let inputSpan = Double(inputFrameCount - 1)
        let outputSpan = Double(max(1, outputFrameCount - 1))
        let useCubicInterpolation = inputFrameCount >= 4
        for channel in 0..<Int(format.channelCount) {
            let input = inputChannels[channel]
            let destination = outputChannels[channel]
            for outputIndex in 0..<outputFrameCount {
                let inputPosition = Double(outputIndex) * inputSpan / outputSpan
                let lowerIndex = Int(inputPosition)
                let upperIndex = min(lowerIndex + 1, inputFrameCount - 1)
                let fraction = Float(inputPosition - Double(lowerIndex))
                if useCubicInterpolation {
                    let beforeIndex = max(0, lowerIndex - 1)
                    let afterIndex = min(inputFrameCount - 1, upperIndex + 1)
                    destination[outputIndex] = Self.catmullRomInterpolate(
                        p0: input[beforeIndex],
                        p1: input[lowerIndex],
                        p2: input[upperIndex],
                        p3: input[afterIndex],
                        t: fraction
                    )
                } else {
                    destination[outputIndex] =
                        input[lowerIndex] +
                        ((input[upperIndex] - input[lowerIndex]) * fraction)
                }
            }
        }
        return output
    }

    /// Standard Catmull-Rom cubic spline: passes exactly through `p1` at
    /// `t == 0` and `p2` at `t == 1`, using `p0`/`p3` only to shape the
    /// tangent between them — unlike linear interpolation, the curve's slope
    /// is continuous with its neighbors instead of kinking at every raw
    /// sample.
    private static func catmullRomInterpolate(p0: Float, p1: Float, p2: Float, p3: Float, t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private func copySegment(
        from source: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard startFrame >= 0,
              startFrame < sourceFrames,
              frameCount > 0 else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(startFrame) frames=\(frameCount) totalFrames=\(sourceFrames)")
            return nil
        }

        let actualCount = min(frameCount, sourceFrames - startFrame)
        guard actualCount > 0,
              startFrame + actualCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(actualCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(actualCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=unsupportedFormat sourceFrame=\(startFrame) frames=\(actualCount) totalFrames=\(sourceFrames)")
            return nil
        }
        let channelCount = Int(format.channelCount)

        for ch in 0..<channelCount {
            let src = srcChannels[ch].advanced(by: startFrame)
            let dst = dstChannels[ch]
            dst.update(from: src, count: actualCount)
        }
        return segment
    }

    /// Copies a complete forward grain from the loop. If the requested
    /// displacement reaches the WAV end, the remainder continues at frame
    /// zero instead of returning a shortened buffer.
    private func copyWrappedForwardSegment(
        from source: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard startFrame >= 0,
              startFrame < sourceFrames,
              frameCount > 0,
              frameCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            return nil
        }

        for channel in 0..<Int(format.channelCount) {
            let sourceChannel = srcChannels[channel]
            let destination = dstChannels[channel]
            for offset in 0..<frameCount {
                destination[offset] = sourceChannel[(startFrame + offset) % sourceFrames]
            }
        }
        return segment
    }

    /// Copies a complete backward grain from the loop. If the requested
    /// displacement reaches frame zero, the remainder continues backward
    /// from the WAV's final frame instead of returning a shortened buffer.
    private func copyWrappedReversedSegmentEnding(
        at endFrame: Int,
        frameCount: Int,
        from source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard endFrame >= 0,
              endFrame < sourceFrames,
              frameCount > 0,
              frameCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            return nil
        }

        for channel in 0..<Int(format.channelCount) {
            let sourceChannel = srcChannels[channel]
            let destination = dstChannels[channel]
            for offset in 0..<frameCount {
                let index = (endFrame - offset) % sourceFrames
                destination[offset] = sourceChannel[
                    index < 0 ? index + sourceFrames : index
                ]
            }
        }
        return segment
    }
}
