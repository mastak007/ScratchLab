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
import QuartzCore

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    private let engine = AVAudioEngine()
    private var renderer: IOScratchRenderer?
    private var outputConfiguration: OutputConfiguration?
    private var midiContinuousDrive = MIDIPlatterContinuousDrive()
    private var midiCoalescingTimer: DispatchSourceTimer?

    private struct OutputConfiguration: Equatable {
        let preferredHardwareChannelCount: Int
        let usesDeck2ChannelMap: Bool
        let routeName: String
    }

    /// The latest observed platter position.
    private var currentPlatterPosition: PlatterPosition?
    /// Absolute RANE step phase at the most recent hotcue press. Playback is
    /// always derived relative to this origin so HC1 means audible frame zero.
    private var hotCuePlatterPhase: Double?

    #if DEBUG
    private var lastPlatterLogUptime: TimeInterval = -.infinity
    private let platterLogInterval: TimeInterval = 0.5
    #endif

    init() {}

    /// Load a scratch sample by ID into the renderer's PCM buffer.
    func load(sampleID: String) {
        // HC1's catalog ID is `ahhh`, but the padded ScratchSamples asset is
        // not platter-ready (345 ms leading silence and >3 s trailing silence).
        // iOS uses the same trimmed 1.047 s asset as the proven DVS path.
        let playbackSampleID = sampleID == "ahhh" ? "dvs_ahhh" : sampleID
        guard let url = ScratchSampleResolver.url(for: playbackSampleID) else { return }
        do {
            let renderer = try prepareRendererForCurrentRoute()
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
        guard let renderer else {
            #if DEBUG
            print("[MIDI-DEBUG] sample playback failed · reason=audio route unavailable")
            #endif
            return
        }
        hotCuePlatterPhase = currentPlatterPosition?.phase ?? 0
        midiContinuousDrive.reset()
        renderer.update(relativePlatterSteps: 0, signedVelocityStepsPerSecond: 0)
        do {
            try startEngineIfNeeded()
            renderer.activate()
            startMIDIControlLoop()
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
        midiCoalescingTimer?.setEventHandler {}
        midiCoalescingTimer?.cancel()
        midiCoalescingTimer = nil
        midiContinuousDrive.reset()
        renderer?.reset()
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
    }

    // MARK: - Internals

    /// Start the audio engine once, idempotently.
    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Match the macOS direct-MIDI drive: sample the accumulated CC6 position
    /// at a bounded cadence and derive signed velocity from real monotonic
    /// elapsed time. This avoids pitch modulation from per-packet timing and
    /// from the tracker's diagnostic fixed-rate velocity estimate.
    private func startMIDIControlLoop() {
        midiCoalescingTimer?.setEventHandler {}
        midiCoalescingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: 1.0 / 60.0,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.publishMIDIControlTick()
        }
        midiCoalescingTimer = timer
        timer.resume()
    }

    private func publishMIDIControlTick() {
        guard let renderer,
              let position = currentPlatterPosition,
              let hotCuePlatterPhase else { return }
        let tick = midiContinuousDrive.tick(
            accumulatedSteps: Int(position.phase),
            now: CACurrentMediaTime()
        )
        renderer.update(
            relativePlatterSteps: position.phase - hotCuePlatterPhase,
            signedVelocityStepsPerSecond: tick?.velocity ?? 0
        )
    }

    /// Builds the graph for the route observed at hot-cue load time. The RANE
    /// ONE MKII exposes Deck 1 on physical outputs 1/2 and Deck 2 on 3/4, so a
    /// four-channel discrete source writes only channels 2/3 (zero-based).
    /// Every other route retains the existing two-channel stereo graph.
    private func prepareRendererForCurrentRoute() throws -> IOScratchRenderer {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)

        let routeName = session.currentRoute.outputs.first?.portName ?? "System Output"
        let normalizedRouteName = routeName.lowercased()
        let isRaneOne = normalizedRouteName.contains("rane") && normalizedRouteName.contains("one")
        let supportsDeck2Pair = session.maximumOutputNumberOfChannels >= 4
        let configuration = OutputConfiguration(
            preferredHardwareChannelCount: isRaneOne && supportsDeck2Pair ? 4 : 2,
            usesDeck2ChannelMap: isRaneOne && supportsDeck2Pair,
            routeName: routeName
        )
        if configuration == outputConfiguration, let renderer {
            return renderer
        }

        engine.stop()
        if let renderer {
            engine.disconnectNodeOutput(renderer.sourceNode)
            engine.detach(renderer.sourceNode)
        }
        engine.disconnectNodeOutput(engine.mainMixerNode)

        try session.setPreferredOutputNumberOfChannels(configuration.preferredHardwareChannelCount)
        let renderer = IOScratchRenderer()
        engine.attach(renderer.sourceNode)
        let stereoFormat = renderer.sourceNode.outputFormat(forBus: 0)
        engine.connect(
            renderer.sourceNode,
            to: engine.mainMixerNode,
            format: stereoFormat
        )
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)

        // The output unit's channel map is destination-indexed. Preserve the
        // renderer's proven stereo graph and place it on the RANE's four-channel
        // hardware surface as: Deck 1 L/R = silence, Deck 2 L/R = source L/R.
        // Generic routes clear the override and retain ordinary stereo output.
        engine.outputNode.auAudioUnit.channelMap = configuration.usesDeck2ChannelMap
            ? [-1, -1, 0, 1]
            : nil
        self.renderer = renderer
        outputConfiguration = configuration

        #if DEBUG
        print("[SCRATCH-DEBUG] playback output configured · route=\(routeName) hardwareChannels=\(configuration.preferredHardwareChannelCount) channelMap=\(engine.outputNode.auAudioUnit.channelMap ?? [])")
        #endif
        return renderer
    }
}
