// IOScratchPlaybackEngine.swift
// ScratchLab — iOS Scratch Playback Engine (runtime boundary)
//
// iOS-specific scratch playback boundary. This is the platform-side sink for
// resolved hot-cue triggers: the iOS MIDI dispatch resolves an action and calls
// into this engine instead of owning audio itself.
//
// Phase 4B routes the audio through a continuous `IOScratchRenderer`
// (AVAudioSourceNode render callback) instead of the temporary AVAudioPlayerNode
// buffer-switching. The public API is unchanged; only the internal renderer
// changed.

import AVFoundation
import Foundation

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    private let engine = AVAudioEngine()
    private let renderer = IOScratchRenderer()

    /// The latest observed platter position.
    private var currentPlatterPosition: PlatterPosition?

    #if DEBUG
    private var lastPlatterLogUptime: TimeInterval = -.infinity
    private let platterLogInterval: TimeInterval = 0.5
    #endif

    init() {
        // Best-effort: request a clean 2-channel output route instead of
        // exposing the RANE ONE MKII's full multichannel output surface
        // (14 channels) to the graph. Independent of input channel count
        // (preferredInputNumberOfChannels is untouched elsewhere, so DVS
        // capture's full-channel-set input behaviour is unaffected).
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(2)

        engine.attach(renderer.sourceNode)
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
            channels: 2
        )
        // Explicit stereo format end to end. `format: nil` on the source →
        // mixer connection already carries the source node's own 2-channel
        // format through, but the mixer → output connection is otherwise
        // left to AVAudioEngine's automatic default wiring, which adopts
        // the hardware's full (multichannel) output format. Against an
        // untagged >2-channel discrete output bus, AVAudioMixerNode's pan
        // logic has nothing to pan the stereo signal onto and only channel
        // 0 reaches the output — the left-channel-only bug this fixes.
        // Connecting explicitly with a 2-channel format instead makes the
        // engine insert a plain channel-count converter (ch0→hw0, ch1→hw1)
        // rather than routing through that pan logic.
        engine.connect(renderer.sourceNode, to: engine.mainMixerNode, format: renderer.sourceNode.outputFormat(forBus: 0))
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)
    }

    /// Load a scratch sample by ID into the renderer's PCM buffer.
    func load(sampleID: String) {
        guard let url = ScratchSampleResolver.url(for: sampleID) else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try file.read(into: buffer)
            renderer.load(buffer: buffer)
        } catch {
            #if DEBUG
            print("[SCRATCH-DEBUG] sample load failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Load a hot-cue sample, arm the renderer at the top, and activate its
    /// output. The renderer does not run its own clock — it holds the current
    /// frame (silent at frame 0 until platter movement, via
    /// `updatePlatterPosition`, moves the playhead) rather than free-running.
    func playHotCue(sampleID: String) {
        #if DEBUG
        print("[MIDI-DEBUG] hotcue playback requested · sample=\(sampleID)")
        #endif

        load(sampleID: sampleID)
        do {
            try startEngineIfNeeded()
            renderer.activate()
            #if DEBUG
            print("[MIDI-DEBUG] sample armed · \(sampleID)")
            #endif
        } catch {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=\(error.localizedDescription)")
            #endif
        }
    }

    /// Stop playback entirely and reset the playhead.
    func stop() {
        renderer.reset()
    }

    /// Observe the latest platter position and drive scratch playback:
    /// forward → play forward, backward → reverse, idle → freeze (silence).
    func updatePlatterPosition(_ position: PlatterPosition) {
        currentPlatterPosition = position
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPlatterLogUptime >= platterLogInterval {
            lastPlatterLogUptime = now
            print("[SCRATCH-DEBUG] platter position received · phase=\(position.phase) direction=\(position.direction) velocity=\(position.velocity)")
        }
        #endif
        renderer.update(position: position)
    }

    // MARK: - Internals

    /// Start the audio engine once, idempotently.
    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }
}
