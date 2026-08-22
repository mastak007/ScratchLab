// IOScratchPlaybackEngine.swift
// ScratchLab — iOS Scratch Playback Engine (runtime boundary)
//
// iOS-specific scratch playback boundary. This is the platform-side sink for
// resolved hot-cue triggers: the iOS MIDI dispatch resolves an action and calls
// into this engine instead of owning audio itself.
//
// Phase 3 replaces the temporary AVAudioPlayer one-shot with an AVAudioEngine +
// AVAudioPlayerNode foundation. The public API is unchanged; only the internal
// audio implementation moved from AVAudioPlayer to the engine. Platter-driven
// scratching is a later phase.

import AVFoundation
import Foundation

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    /// The audio engine and player node that render one-shot hot-cue samples.
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The latest observed platter position. Stored only — Phase 2 is the
    /// data-flow boundary; no sample seeking or audio changes yet.
    private var currentPlatterPosition: PlatterPosition?

    #if DEBUG
    private var lastPlatterLogUptime: TimeInterval = -.infinity
    private let platterLogInterval: TimeInterval = 0.5
    #endif

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    /// Load a scratch sample by ID. Phase 1 stub — full scratch loading is a
    /// later phase; the current runtime only performs one-shot hot-cue playback.
    func load(sampleID: String) {
    }

    /// Play a hot-cue sample immediately (one-shot) through the AVAudioEngine
    /// player node. Preserves the previous behaviour: load once, play once.
    func playHotCue(sampleID: String) {
        #if DEBUG
        print("[MIDI-DEBUG] hotcue playback requested · sample=\(sampleID)")
        #endif

        guard let url = ScratchSampleResolver.url(for: sampleID) else {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=not found (\(sampleID))")
            #endif
            return
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                #if DEBUG
                print("[MIDI-DEBUG] sample playback failed · reason=buffer allocation")
                #endif
                return
            }
            try file.read(into: buffer)

            try startEngineIfNeeded()

            #if DEBUG
            print("[MIDI-DEBUG] sample loaded · \(sampleID)")
            #endif

            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            playerNode.play()

            #if DEBUG
            print("[MIDI-DEBUG] sample playback started · \(sampleID)")
            #endif
        } catch {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Stop the current hot-cue playback.
    func stop() {
        playerNode.stop()
    }

    /// Observe the latest platter position. Phase 2 stores it only — no sample
    /// seeking, no audio changes, no transport changes. Full scratch playback
    /// is a later phase.
    func updatePlatterPosition(_ position: PlatterPosition) {
        currentPlatterPosition = position
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPlatterLogUptime >= platterLogInterval {
            lastPlatterLogUptime = now
            print("[SCRATCH-DEBUG] platter position received · phase=\(position.phase) direction=\(position.direction) velocity=\(position.velocity)")
        }
        #endif
    }

    /// Start the audio engine once, idempotently.
    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }
}
