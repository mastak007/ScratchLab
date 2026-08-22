// IOScratchPlaybackEngine.swift
// ScratchLab — iOS Scratch Playback Engine (runtime boundary)
//
// iOS-specific scratch playback boundary. This is the platform-side sink for
// resolved hot-cue triggers: the iOS MIDI dispatch resolves an action and calls
// into this engine instead of owning audio itself.
//
// Phase 3 moved the one-shot from AVAudioPlayer onto an AVAudioEngine +
// AVAudioPlayerNode foundation. Phase 4 connects PlatterPosition to that
// engine so platter movement now drives forward/reverse/freeze playback.

import AVFoundation
import Foundation

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    /// The audio engine and player node that render hot-cue samples.
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The loaded scratch sample and its reversed copy (for backward playback).
    private var sampleBuffer: AVAudioPCMBuffer?
    private var reversedBuffer: AVAudioPCMBuffer?
    private var totalFrames: AVAudioFrameCount = 0

    /// Playhead state, tracked from the latest PlatterPosition.
    private var currentFrame: Double = 0
    private var currentDirection: PlatterDirection = .idle
    private var isPlaying = false

    /// The latest observed platter position.
    private var currentPlatterPosition: PlatterPosition?

    #if DEBUG
    private var lastPlatterLogUptime: TimeInterval = -.infinity
    private let platterLogInterval: TimeInterval = 0.5
    #endif

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    /// Load a scratch sample by ID into memory (forward + reversed copies).
    func load(sampleID: String) {
        guard let url = ScratchSampleResolver.url(for: sampleID) else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try file.read(into: buffer)
            sampleBuffer = buffer
            reversedBuffer = Self.reversed(buffer)
            totalFrames = buffer.frameLength
            currentFrame = 0
            currentDirection = .idle
            isPlaying = false
        } catch {
            #if DEBUG
            print("[SCRATCH-DEBUG] sample load failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Start a hot-cue sample from the top (forward). Platter movement then
    /// takes over direction/freeze via `updatePlatterPosition`.
    func playHotCue(sampleID: String) {
        #if DEBUG
        print("[MIDI-DEBUG] hotcue playback requested · sample=\(sampleID)")
        #endif

        load(sampleID: sampleID)
        guard let buffer = sampleBuffer, totalFrames > 0 else {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=not found or unreadable")
            #endif
            return
        }

        do {
            try startEngineIfNeeded()
            #if DEBUG
            print("[MIDI-DEBUG] sample loaded · \(sampleID)")
            #endif
            currentFrame = 0
            currentDirection = .forward
            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            playerNode.play()
            isPlaying = true
            #if DEBUG
            print("[MIDI-DEBUG] sample playback started · \(sampleID)")
            #endif
        } catch {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Stop playback entirely and reset the playhead.
    func stop() {
        playerNode.stop()
        isPlaying = false
        currentDirection = .idle
        currentFrame = 0
    }

    /// Observe the latest platter position and drive scratch playback:
    /// forward → play forward, backward → play reversed, idle → freeze.
    func updatePlatterPosition(_ position: PlatterPosition) {
        currentPlatterPosition = position
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPlatterLogUptime >= platterLogInterval {
            lastPlatterLogUptime = now
            print("[SCRATCH-DEBUG] platter position received · phase=\(position.phase) direction=\(position.direction) velocity=\(position.velocity)")
        }
        #endif

        guard totalFrames > 0 else { return }
        currentFrame = position.normalizedPosition * Double(totalFrames)

        switch position.direction {
        case .idle:
            if isPlaying {
                playerNode.pause()
                isPlaying = false
            }
        case .forward, .backward:
            if position.direction != currentDirection || !isPlaying {
                play(direction: position.direction)
            }
        }
        currentDirection = position.direction
    }

    // MARK: - Internals

    /// Play the loaded sample in `direction` (forward buffer or reversed buffer).
    private func play(direction: PlatterDirection) {
        guard let buffer = direction == .forward ? sampleBuffer : reversedBuffer else { return }
        do {
            try startEngineIfNeeded()
            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            playerNode.play()
            isPlaying = true
            currentDirection = direction
        } catch {
            #if DEBUG
            print("[SCRATCH-DEBUG] playback failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Start the audio engine once, idempotently.
    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Reverse a Float32 PCM buffer (per-channel, sample order).
    private static func reversed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard let reversed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData,
              let dst = reversed.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            for i in 0..<frames {
                dst[ch][i] = src[ch][frames - 1 - i]
            }
        }
        reversed.frameLength = buffer.frameLength
        return reversed
    }
}
