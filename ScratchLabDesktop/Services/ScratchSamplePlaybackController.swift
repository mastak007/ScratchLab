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
// Thread model: all public methods are safe to call from any thread, including
// the CoreMIDI callback thread. They enqueue work on a private serial audioQueue
// and return immediately so the CoreMIDI callback thread is never blocked by
// file I/O, engine startup, buffer scheduling, or playerNode mutation.

import AVFoundation
import Foundation

/// Drives sample playback from a `ScratchPlatterTracker` position.
/// - Hot cue press: loads the corresponding bundled WAV (async, off CoreMIDI thread).
/// - Platter CC6 movement: updates playback position and schedules audio (async).
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

    init() {
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

    private func loadOnQueue(sampleID: String, url: URL) {
        print("[ScratchSamplePlaybackController] sample load queued: \(sampleID)")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            print("[ScratchSamplePlaybackController] failed to open \(sampleID): \(error)")
            debugPublishOnMainAsync(field: "statusLabel.error") { [weak self] in
                self?.statusLabel = "error: \(sampleID)"
            }
            return
        }

        guard let buffer = readIntoBuffer(file) else {
            print("[ScratchSamplePlaybackController] failed to read PCM for \(sampleID)")
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
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = nil
        lastReversalCompensated = false
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

    /// Called when platter position changes. Dispatches audio scheduling to
    /// the audio queue and returns immediately from the CoreMIDI callback thread.
    func positionDidChange(steps: Int, direction: ScratchPlatterDirection?) {
        audioQueue.async { [weak self] in
            self?.positionDidChangeOnQueue(steps: steps, direction: direction)
        }
    }

    private func positionDidChangeOnQueue(steps: Int, direction: ScratchPlatterDirection?) {
        let now = CACurrentMediaTime()

        // Rate-limit to ~60 Hz.
        guard now - lastScheduleTime >= minScheduleInterval else { return }

        guard let direction else {
            lastScheduleSkippedReason = "noDirection"
            print("[ScratchSamplePlaybackController] schedule skipped · reason=noDirection steps=\(steps)")
            return
        }

        guard let forward = forwardBuffer, totalFrames > 0 else { return }

        guard let previousSteps = lastPlatterSteps else {
            lastPlatterSteps = steps
            lastScheduleSkippedReason = "priming"
            print("[ScratchSamplePlaybackController] schedule skipped · reason=priming steps=\(steps)")
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
            print("[ScratchSamplePlaybackController] schedule skipped · reason=noMotion steps=\(steps)")
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
        let requestedFrames = Int(forward.format.sampleRate * segmentDuration)

        // Skip pathologically tiny grains (a single PCM sample), which would
        // produce an audible click. This guard catches literal single-sample
        // grains (frameDelta=1) that can only occur with atypically short
        // samples. The nearStop gate below handles musical near-stop motion.
        let minimumGrainFrames = 2
        guard frameDelta >= minimumGrainFrames else {
            lastScheduleSkippedReason = "tinyGrain"
            lastPlatterSteps = steps
            print("[ScratchSamplePlaybackController] schedule skipped · reason=tinyGrain steps=\(steps) frameDelta=\(frameDelta) minimum=\(minimumGrainFrames)")
            return
        }

        // Near-stop gate: when the platter moves too slowly, the varispeed
        // floor (0.25) cannot stretch the grain to fill the 16.7 ms scheduling
        // slot. Scheduling the grain would produce a rapid on/off/on sputter
        // ("farting"). Suppress scheduling but advance the needle position
        // silently so the virtual stylus stays in sync with the physical platter.
        let minAudibleFrameDelta = max(1, Int(Double(minAudibleDeltaSteps) * framesPerStep))
        guard frameDelta >= minAudibleFrameDelta else {
            switch schedulingDirection {
            case .forward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame + frameDelta)
            case .backward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame - frameDelta)
            }
            lastScheduleSkippedReason = "nearStop"
            lastPlatterSteps = steps
            lastScheduleTime = now
            print("[ScratchSamplePlaybackController] schedule skipped · reason=nearStop deltaSteps=\(deltaSteps) threshold=\(minAudibleFrameDelta) frameDelta=\(frameDelta)")
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
        let reversalCompensated: Bool
        let effectiveFrameDelta: Int
        if schedulingDirection != lastScheduledDirection,
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

        // Varispeed rate = platter-driven frame displacement / output window size.
        // A grain of effectiveFrameDelta frames played at this rate consumes exactly
        // segmentDuration seconds of real time → one grain per scheduling slot,
        // no queue buildup. Fast platter → rate>1 → higher pitch. Slow → rate<1 → lower.
        let rawRate = Double(effectiveFrameDelta) / Double(requestedFrames)
        let rate = Float(max(Double(minVarispeedRate), min(Double(maxVarispeedRate), rawRate)))
        varispeedNode.rate = rate

        let sourceFrame: Int
        let segmentFrames: Int
        let segment: AVAudioPCMBuffer?

        switch schedulingDirection {
        case .forward:
            sourceFrame = currentSampleFrame
            let remainingFrames = sourceTotalFrames - sourceFrame
            segmentFrames = min(effectiveFrameDelta, remainingFrames)
            segment = copySegment(
                from: forward,
                startFrame: sourceFrame,
                frameCount: segmentFrames
            )
            currentSampleFrame = wrappedSampleFrame(currentSampleFrame + effectiveFrameDelta)
        case .backward:
            sourceFrame = currentSampleFrame
            let availableFrames = sourceFrame + 1
            segmentFrames = min(effectiveFrameDelta, availableFrames)
            segment = copyReversedSegmentEnding(
                at: sourceFrame,
                frameCount: segmentFrames,
                from: forward
            )
            currentSampleFrame = wrappedSampleFrame(currentSampleFrame - effectiveFrameDelta)
        }

        #if DEBUG
        print("[ScratchSamplePlaybackController] platter state · steps=\(steps) deltaSteps=\(deltaSteps) direction=\(directionDescription(schedulingDirection)) currentFrame=\(currentSampleFrame) effectiveFrameDelta=\(effectiveFrameDelta) totalFrames=\(sourceTotalFrames)")
        print("[ScratchSamplePlaybackController] schedule input · steps=\(steps) direction=\(directionDescription(schedulingDirection)) sourceFrame=\(sourceFrame) segmentFrames=\(segmentFrames) rate=\(String(format: "%.3f", rate)) totalFrames=\(sourceTotalFrames)")
        #endif

        let isValidSegment: Bool
        switch schedulingDirection {
        case .forward:
            isValidSegment = sourceFrame >= 0 &&
                sourceFrame < sourceTotalFrames &&
                segmentFrames > 0 &&
                sourceFrame + segmentFrames <= sourceTotalFrames
        case .backward:
            isValidSegment = sourceFrame >= 0 &&
                sourceFrame < sourceTotalFrames &&
                segmentFrames > 0 &&
                segmentFrames <= sourceFrame + 1
        }

        guard isValidSegment else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(sourceFrame) frames=\(segmentFrames) totalFrames=\(sourceTotalFrames)")
            lastScheduleSkippedReason = "invalidSegment"
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        guard let segment else {
            lastScheduleSkippedReason = "copyFailed"
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        // Smooth PCM boundary discontinuities before scheduling.
        // Not applied to the diagnostic preview (which calls copySegment directly).
        applyEdgeFade(to: segment)

        // Interrupt only on direction change; same-direction grains queue smoothly.
        // Avoid interrupting every tiny platter update, because that can cancel audio
        // before the scheduled segment becomes audible.
        let opts: AVAudioPlayerNodeBufferOptions = (schedulingDirection != lastScheduledDirection) ? .interrupts : []
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
        lastScheduleTime = now
        lastPlatterSteps = steps
        lastScheduledSourceFrame = sourceFrame
        lastScheduledSegmentFrames = segmentFrames
        lastScheduledRate = rate
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = effectiveFrameDelta
        lastReversalCompensated = reversalCompensated
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
            self.lastScheduleSkippedReason = nil
            self.lastEffectiveFrameDelta = nil
            self.lastReversalCompensated = false
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

    private func copyReversedSegmentEnding(
        at endFrame: Int,
        frameCount: Int,
        from source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard endFrame >= 0,
              endFrame < sourceFrames,
              frameCount > 0 else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(endFrame) frames=\(frameCount) totalFrames=\(sourceFrames)")
            return nil
        }

        let actualCount = min(frameCount, endFrame + 1)
        let startFrame = endFrame - actualCount + 1
        guard startFrame >= 0,
              actualCount > 0,
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
            print("[ScratchSamplePlaybackController] schedule skipped · reason=unsupportedFormat sourceFrame=\(endFrame) frames=\(actualCount) totalFrames=\(sourceFrames)")
            return nil
        }

        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            let src = srcChannels[ch]
            let dst = dstChannels[ch]
            for i in 0..<actualCount {
                dst[i] = src[endFrame - i]
            }
        }
        return segment
    }
}
