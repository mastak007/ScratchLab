// ScratchSamplePlaybackController.swift
// ScratchLab Desktop — Platter-Driven Scratch Sample Playback
//
// AVAudioEngine-based sample playback driven by CC6 platter position.
// Loads bundled WAVs into PCM buffers; maps accumulated platter steps to
// sample position; schedules short audio segments for forward/backward scratch.
//
// Owned by MacCaptureEngine. Output = system default audio device.
// No MIDI routing. No scoring. No Rane audio device routing.

import AVFoundation
import Foundation

/// Drives sample playback from a `ScratchPlatterTracker` position.
/// - Hot cue press: loads the corresponding bundled WAV.
/// - Platter CC6 movement: updates playback position and schedules audio.
/// - No motion: audio stops after the current short segment plays out.
final class ScratchSamplePlaybackController {

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // MARK: - Loaded sample state

    /// Sample ID currently loaded (nil if no sample loaded).
    private(set) var loadedSampleID: String?

    /// PCM buffer of the loaded sample (forward direction).
    private var forwardBuffer: AVAudioPCMBuffer?

    /// Pre-reversed PCM buffer for backward scratch.
    private var reversedBuffer: AVAudioPCMBuffer?

    /// Total frames in the loaded buffer.
    private var totalFrames: Int = 0

    /// Accumulated steps snapshot at last schedule time.
    private var lastScheduledSteps: Int = 0

    /// Last direction used for scheduling.
    private var lastScheduledDirection: ScratchPlatterDirection?

    /// Timestamp of last schedule (CACurrentMediaTime).
    private var lastScheduleTime: Double = 0

    /// Minimum interval between schedule calls (seconds).
    private let minScheduleInterval: Double = 1.0 / 60.0

    /// Segment duration scheduled per position update (seconds).
    private let segmentDuration: Double = 0.050   // 50 ms

    /// CC6 steps per full sample traversal. Maps platter rotation to sample length.
    /// Rane ONE MKII: ~3932 steps/rev. Default: 1 rev = 1 sample pass.
    private let stepsPerFullSample: Int = 3932

    // MARK: - Engine state

    private var engineStarted = false
    private let engineLock = NSLock()

    /// Diagnostic label for the UI.
    @Published var statusLabel: String = "idle"

    /// Crossfader gate value (0.0 = fully closed/cut, 1.0 = fully open).
    /// Applied as `playerNode.volume`. Default 1.0 (open) so audio passes
    /// before the first crossfader event arrives.
    @Published var crossfaderGate: Float = 1.0

    /// Last raw crossfader CC8 value (0–127), or nil if no event received yet.
    @Published var lastCrossfaderRawValue: Int? = nil

    // MARK: - Lifecycle

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        stopEngine()
    }

    // MARK: - Engine start/stop

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
    /// - Parameter sampleID: Scratch bank sample ID (e.g. "ahhh", "fresh").
    /// - Returns: True if the sample was loaded successfully.
    @discardableResult
    func load(sampleID: String) -> Bool {
        // Resolve WAV from bundle.
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel = "missing: \(sampleID)"
            }
            return false
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            print("[ScratchSamplePlaybackController] failed to open \(sampleID): \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel = "error: \(sampleID)"
            }
            return false
        }

        guard let buffer = readIntoBuffer(file) else {
            print("[ScratchSamplePlaybackController] failed to read PCM for \(sampleID)")
            return false
        }

        forwardBuffer = buffer
        totalFrames = Int(buffer.frameLength)

        // Pre-reverse for backward scratch.
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
        return true
    }

    // MARK: - Position-driven playback

    /// Called when platter position changes. Schedules audio from the computed
    /// frame position. Rate-limited to ~60 Hz.
    /// - Parameters:
    ///   - steps: Current accumulated CC6 steps from tracker.
    ///   - direction: Direction of recent movement.
    func positionDidChange(steps: Int, direction: ScratchPlatterDirection?) {
        let now = CACurrentMediaTime()

        // Rate-limit to avoid scheduling at CC6 event rate (~800 Hz).
        guard now - lastScheduleTime >= minScheduleInterval else { return }

        // Don't reschedule if position hasn't changed since last schedule.
        guard steps != lastScheduledSteps || direction != lastScheduledDirection else {
            return
        }

        guard let forward = forwardBuffer, totalFrames > 0 else { return }

        let frameIndex = sampleFrame(for: steps)

        // Determine which buffer to use based on direction.
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
        let segmentFrames = min(Int(sourceBuffer.format.sampleRate * segmentDuration), max(1, remainingFrames))

        guard let segment = copySegment(from: sourceBuffer, startFrame: sourceFrame, frameCount: segmentFrames) else {
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
        playerNode.pause()
        lastScheduledDirection = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.loadedSampleID else { return }
            self.statusLabel = "loaded: \(id) · paused"
        }
    }

    /// Resume after pause.
    func resumePlayback() {
        guard loadedSampleID != nil else { return }
        playerNode.play()
    }

    /// Unload the current sample and stop audio.
    func unload() {
        playerNode.stop()
        forwardBuffer = nil
        reversedBuffer = nil
        loadedSampleID = nil
        totalFrames = 0
        lastScheduledSteps = 0
        lastScheduledDirection = nil
        // Reset crossfader gate to open on unload.
        crossfaderGate = 1.0
        lastCrossfaderRawValue = nil
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel = "idle"
        }
        print("[ScratchSamplePlaybackController] unloaded")
    }

    // MARK: - Crossfader gate

    /// Apply crossfader CC8 value as audio gate.
    ///
    /// Rane ONE MKII: ch=15 CC8, range 0–127.
    ///   - 0   → fully closed (cut, volume 0.0)
    ///   - 127 → fully open (volume 1.0)
    ///
    /// Applied as `playerNode.volume`. Linear for the proof; deck-specific
    /// cut model can replace this later without changing the call site.
    ///
    /// Safe to call from any thread — dispatches audio work synchronously.
    func setCrossfader(value: Int) {
        let normalized = Float(value) / 127.0
        playerNode.volume = normalized
        let raw = value
        DispatchQueue.main.async { [weak self] in
            self?.crossfaderGate = normalized
            self?.lastCrossfaderRawValue = raw
        }
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
              let reversed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
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

    private func copySegment(from source: AVAudioPCMBuffer, startFrame: Int, frameCount: Int) -> AVAudioPCMBuffer? {
        let format = source.format
        let actualCount = min(frameCount, Int(source.frameLength) - startFrame)
        guard actualCount > 0,
              let segment = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(actualCount)) else {
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
