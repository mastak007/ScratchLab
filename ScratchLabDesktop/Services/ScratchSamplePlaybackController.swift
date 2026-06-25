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
    private var reversedBuffer: AVAudioPCMBuffer?
    private var totalFrames: Int = 0
    private var lastScheduledSteps: Int = 0
    private var lastScheduledDirection: ScratchPlatterDirection?
    private var lastScheduleTime: Double = 0

    // MARK: - Rate-limit / segment constants (unchanged)

    /// Minimum interval between scheduleBuffer calls (seconds).
    private let minScheduleInterval: Double = 1.0 / 60.0

    /// Segment duration scheduled per position update (seconds).
    private let segmentDuration: Double = 0.050

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
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            DispatchQueue.main.async { [weak self] in
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
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            print("[ScratchSamplePlaybackController] failed to open \(sampleID): \(error)")
            DispatchQueue.main.async { [weak self] in
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
        reversedBuffer = reverseBuffer(buffer)
        loadedSampleID = sampleID
        lastScheduledSteps = 0
        lastScheduledDirection = nil
        lastScheduleTime = 0

        ensureEngineRunning()

        let duration = Double(totalFrames) / buffer.format.sampleRate
        print("[ScratchSamplePlaybackController] loaded \(sampleID) · \(totalFrames) frames · \(String(format: "%.2f", duration))s")
        DispatchQueue.main.async { [weak self] in
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

        // Don't reschedule if position hasn't changed since last schedule.
        guard steps != lastScheduledSteps || direction != lastScheduledDirection else {
            return
        }

        guard let forward = forwardBuffer, totalFrames > 0 else { return }

        let frameIndex = sampleFrame(for: steps)

        let sourceBuffer: AVAudioPCMBuffer
        let sourceFrame: Int

        switch direction {
        case .backward:
            guard let reversed = reversedBuffer else { return }
            sourceBuffer = reversed
            sourceFrame = totalFrames - 1 - frameIndex
        case .forward, nil:
            sourceBuffer = forward
            sourceFrame = frameIndex
        }

        let remainingFrames = totalFrames - sourceFrame
        let segmentFrames = min(
            Int(sourceBuffer.format.sampleRate * segmentDuration),
            max(1, remainingFrames)
        )

        guard let segment = copySegment(
            from: sourceBuffer,
            startFrame: sourceFrame,
            frameCount: segmentFrames
        ) else {
            return
        }

        // Schedule with .interrupts to stop any currently playing segment.
        playerNode.scheduleBuffer(segment, at: nil, options: .interrupts)
        if !playerNode.isPlaying {
            playerNode.play()
        }

        lastScheduledSteps = steps
        lastScheduledDirection = direction
        lastScheduleTime = now
    }

    /// Stop playback (e.g. when platter is idle).
    func pausePlayback() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playerNode.pause()
            self.lastScheduledDirection = nil
            let id = self.loadedSampleID
            DispatchQueue.main.async { [weak self] in
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
            self.reversedBuffer = nil
            self.loadedSampleID = nil
            self.totalFrames = 0
            self.lastScheduledSteps = 0
            self.lastScheduledDirection = nil
            print("[ScratchSamplePlaybackController] unloaded")
            DispatchQueue.main.async { [weak self] in
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
            self.playerNode.volume = normalized
            let raw = value
            DispatchQueue.main.async { [weak self] in
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
        let raw = (steps * totalFrames) / stepsPerFullSample
        var wrapped = raw % totalFrames
        if wrapped < 0 { wrapped += totalFrames }
        return wrapped
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            print("[ScratchSamplePlaybackController] read error: \(error)")
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

        guard let srcChannels = source.floatChannelData,
              let dstChannels = reversed.floatChannelData else {
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
        let actualCount = min(frameCount, Int(source.frameLength) - startFrame)
        guard actualCount > 0,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(actualCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(actualCount)

        guard let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
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
}
