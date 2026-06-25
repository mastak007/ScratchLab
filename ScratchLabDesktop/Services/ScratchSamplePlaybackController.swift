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
    private(set) var lastScheduleSkippedReason: String?

    // MARK: - Rate-limit / segment constants (unchanged)

    /// Minimum interval between scheduleBuffer calls (seconds).
    private let minScheduleInterval: Double = 1.0 / 60.0

    /// Segment duration scheduled per position update (seconds).
    private let segmentDuration: Double = 1.0 / 60.0

    /// CC6 steps per full sample traversal.
    private let stepsPerFullSample: Int = 3932

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
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
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
        framesPerStep = max(1, Double(totalFrames) / Double(stepsPerFullSample))
        lastScheduledSourceFrame = nil
        lastScheduledSegmentFrames = nil
        lastScheduleSkippedReason = nil

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
        print("[ScratchSamplePlaybackController] ready for platter · sampleID=\(sampleID) totalFrames=\(totalFrames)")
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

        // Guard: direction/delta sign mismatch. Skip when the declared direction
        // contradicts the step delta sign — this happens transiently when the
        // platter tracker's direction lags a reversal. Skipping avoids scheduling
        // a segment in the wrong direction. Only checked when no overflow occurred;
        // with overflow the sign is ambiguous so the declared direction is trusted.
        if !deltaResult.overflow {
            let signMismatch: Bool
            switch direction {
            case .forward:  signMismatch = deltaSteps < 0
            case .backward: signMismatch = deltaSteps > 0
            }
            if signMismatch {
                lastScheduleSkippedReason = "directionDeltaMismatch"
                lastPlatterSteps = steps
                print("[ScratchSamplePlaybackController] schedule skipped · reason=directionDeltaMismatch steps=\(steps) deltaSteps=\(deltaSteps) direction=\(directionDescription(direction))")
                return
            }
        }

        // Guard: boundary. When currentSampleFrame is already pinned at the sample
        // start (backward) or end (forward), additional motion in the same direction
        // would produce 1-frame segments → audible chatter. Skip scheduling and
        // update lastPlatterSteps so future deltas remain stable after reversal.
        switch direction {
        case .backward where currentSampleFrame <= 0:
            lastScheduleSkippedReason = "boundaryStart"
            lastPlatterSteps = steps
            print("[ScratchSamplePlaybackController] schedule skipped · reason=boundaryStart steps=\(steps) currentFrame=\(currentSampleFrame)")
            return
        case .forward where currentSampleFrame >= totalFrames - 1:
            lastScheduleSkippedReason = "boundaryEnd"
            lastPlatterSteps = steps
            print("[ScratchSamplePlaybackController] schedule skipped · reason=boundaryEnd steps=\(steps) currentFrame=\(currentSampleFrame)")
            return
        default:
            break
        }

        let sourceTotalFrames = Int(forward.frameLength)
        let frameDeltaDouble = min(Double(sourceTotalFrames), (deltaStepMagnitude * framesPerStep).rounded())
        let frameDelta = max(1, Int(frameDeltaDouble))
        let requestedFrames = Int(forward.format.sampleRate * segmentDuration)
        let sourceFrame: Int
        let segmentFrames: Int
        let segment: AVAudioPCMBuffer?

        switch direction {
        case .forward:
            sourceFrame = currentSampleFrame
            let remainingFrames = sourceTotalFrames - sourceFrame
            segmentFrames = min(requestedFrames, remainingFrames)
            segment = copySegment(
                from: forward,
                startFrame: sourceFrame,
                frameCount: segmentFrames
            )
            currentSampleFrame = clampedSampleFrame(currentSampleFrame + frameDelta)
        case .backward:
            sourceFrame = currentSampleFrame
            let availableFrames = sourceFrame + 1
            segmentFrames = min(requestedFrames, availableFrames)
            segment = copyReversedSegmentEnding(
                at: sourceFrame,
                frameCount: segmentFrames,
                from: forward
            )
            currentSampleFrame = clampedSampleFrame(currentSampleFrame - frameDelta)
        }

        print("[ScratchSamplePlaybackController] platter state · steps=\(steps) deltaSteps=\(deltaSteps) direction=\(directionDescription(direction)) currentFrame=\(currentSampleFrame) frameDelta=\(frameDelta) totalFrames=\(sourceTotalFrames)")
        print("[ScratchSamplePlaybackController] schedule input · steps=\(steps) direction=\(directionDescription(direction)) sourceFrame=\(sourceFrame) segmentFrames=\(segmentFrames) totalFrames=\(sourceTotalFrames)")

        let isValidSegment: Bool
        switch direction {
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

        // Interrupt only on direction change; same-direction grains queue smoothly.
        // Avoid interrupting every tiny platter update, because that can cancel audio
        // before the scheduled segment becomes audible.
        let opts: AVAudioPlayerNodeBufferOptions = (direction != lastScheduledDirection) ? .interrupts : []
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
        lastScheduledDirection = direction
        lastScheduleTime = now
        lastPlatterSteps = steps
        lastScheduledSourceFrame = sourceFrame
        lastScheduledSegmentFrames = segmentFrames
        lastScheduleSkippedReason = nil
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
            self.lastScheduleSkippedReason = nil
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
    /// traverses the entire sample.
    func sampleFrame(for steps: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        let scaled = (Double(steps) * Double(totalFrames)) / Double(stepsPerFullSample)
        var wrapped = scaled.truncatingRemainder(dividingBy: Double(totalFrames))
        if wrapped < 0 { wrapped += Double(totalFrames) }
        return min(max(Int(wrapped), 0), totalFrames - 1)
    }

    private func clampedSampleFrame(_ frame: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        return min(max(frame, 0), totalFrames - 1)
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
