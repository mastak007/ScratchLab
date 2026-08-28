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
import Synchronization

/// Keeps the platter-to-renderer control clock off the main actor. RANE CC6
/// traffic also drives live SwiftUI notation state, so sharing `.main` with
/// that bursty publication path makes the velocity sampling interval uneven
/// enough to modulate pitch. macOS confines the equivalent clock to its serial
/// audio queue; this is the minimal iOS counterpart.
private final class IOScratchMIDIControlLoop: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.scratchlab.ios.midi-scratch-control",
        qos: .userInteractive
    )
    private let latestPhaseBits = Atomic<UInt64>(Double.zero.bitPattern)

    // Accessed only on `queue`.
    private var drive = MIDIPlatterContinuousDrive()
    private var timer: DispatchSourceTimer?
    private var renderer: IOScratchRenderer?
    private var hotCuePhase: Double = 0

    func publish(phase: Double) {
        guard phase.isFinite else { return }
        latestPhaseBits.store(phase.bitPattern, ordering: .relaxed)
    }

    var latestPhase: Double {
        Double(bitPattern: latestPhaseBits.load(ordering: .relaxed))
    }

    func start(renderer: IOScratchRenderer, hotCuePhase: Double) {
        stop()
        queue.sync {
            drive.reset()
            self.renderer = renderer
            self.hotCuePhase = hotCuePhase

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(),
                repeating: 1.0 / 60.0,
                leeway: .milliseconds(1)
            )
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    /// Cancels and drains the serial queue before the renderer is reloaded or
    /// reset, so its single control writer can never overlap lifecycle work.
    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            renderer = nil
            drive.reset()
        }
    }

    private func tick() {
        guard let renderer else { return }
        let phase = Double(bitPattern: latestPhaseBits.load(ordering: .relaxed))
        let result = drive.tick(
            accumulatedSteps: Int(phase),
            now: CACurrentMediaTime()
        )
        renderer.update(
            relativePlatterSteps: phase - hotCuePhase,
            signedVelocityStepsPerSecond: result?.velocity ?? 0
        )
    }
}

/// Writes captured stereo Float32 frames to a WAV incrementally, off the
/// audio thread entirely — this only ever runs on `IOScratchCaptureTap`'s own
/// serial queue, never from `IOScratchRenderer.render(...)`. One writer per
/// recorded take; never shared or reused across takes.
private final class ScratchAudioCaptureWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    init(destination: URL, sampleRate: Double, channelCount: AVAudioChannelCount) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) else {
            throw NSError(
                domain: "IOScratchPlaybackEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to build a capture format."]
            )
        }
        self.format = format
        self.file = try AVAudioFile(forWriting: destination, settings: format.settings)
    }

    func append(left: [Float], right: [Float]) throws {
        guard !left.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { source in
            channels[0].update(from: source.baseAddress!, count: left.count)
        }
        if format.channelCount > 1 {
            right.withUnsafeBufferPointer { source in
                channels[1].update(from: source.baseAddress!, count: right.count)
            }
        }
        try file.write(from: buffer)
    }
}

/// Off-actor drain + write loop for the capture tap, structured exactly like
/// `IOScratchMIDIControlLoop` above: a dedicated serial queue is the sole
/// owner of the writer, the renderer reference, and the drain timer, so
/// `IOScratchPlaybackEngine` (MainActor) never touches file I/O or the
/// renderer's capture buffer directly — it only calls `start`/`stop`. This
/// is a consumer only; it never renders or plays audio itself.
private final class IOScratchCaptureTap: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.scratchlab.ios.scratch-capture-drain",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var writer: ScratchAudioCaptureWriter?
    private var renderer: IOScratchRenderer?

    /// Begins recording. `renderer.setCaptureTapEnabled(true)` is called
    /// before the timer starts so no drain tick can ever race a not-yet-armed
    /// producer.
    func start(renderer: IOScratchRenderer, destinationURL: URL, sampleRate: Double) throws {
        stop()
        let writer = try ScratchAudioCaptureWriter(
            destination: destinationURL,
            sampleRate: sampleRate,
            channelCount: 2
        )
        renderer.setCaptureTapEnabled(true)

        queue.sync {
            self.renderer = renderer
            self.writer = writer

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                self?.drainLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    /// Cancels the drain timer, performs one final drain to flush whatever
    /// was rendered since the last tick, then releases the writer (closing
    /// the file) and the renderer reference.
    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            renderer?.setCaptureTapEnabled(false)
            drainLocked()
            renderer = nil
            writer = nil
        }
    }

    /// Must only be called from `queue`.
    private func drainLocked() {
        guard let renderer, let writer else { return }
        let (left, right) = renderer.drainCapturedFrames()
        guard !left.isEmpty else { return }
        do {
            try writer.append(left: left, right: right)
            #if DEBUG
            let peak = (left + right).reduce(Float(0)) { max($0, abs($1)) }
            print("[AUDIO-CAPTURE-DEBUG] rendered scratch frames submitted count=\(left.count)")
            print("[AUDIO-CAPTURE-DEBUG] scratch recorder peak=\(peak)")
            #endif
        } catch {
            #if DEBUG
            print("[AUDIO-CAPTURE-DEBUG] scratch recorder write failed: \(error.localizedDescription)")
            #endif
        }
    }
}

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    private let engine = AVAudioEngine()
    private var renderer: IOScratchRenderer?
    private var outputConfiguration: OutputConfiguration?
    private let midiControlLoop = IOScratchMIDIControlLoop()
    private let captureTap = IOScratchCaptureTap()

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
    private func load(sampleID: String) async throws -> IOScratchRenderer? {
        // HC1's catalog ID is `ahhh`, but the padded ScratchSamples asset is
        // not platter-ready (345 ms leading silence and >3 s trailing silence).
        // iOS uses the same trimmed 1.047 s asset as the proven DVS path.
        let playbackSampleID = sampleID == "ahhh" ? "dvs_ahhh" : sampleID
        guard let url = ScratchSampleResolver.url(for: playbackSampleID) else { return nil }
        midiControlLoop.stop()
        let renderer = try await prepareRendererForCurrentRoute()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try file.read(into: buffer)
        renderer.load(buffer: buffer)
        return renderer
    }

    /// Load a hot-cue sample, arm the renderer at the top, and activate its
    /// output. The renderer does not run its own clock — it holds the current
    /// frame (silent at frame 0 until platter movement, via
    /// `updatePlatterPosition`, moves the playhead) rather than free-running.
    func playHotCue(sampleID: String) {
        #if DEBUG
        print("[MIDI-DEBUG] hotcue playback requested · sample=\(sampleID)")
        #endif

        Task {
            do {
                guard let renderer = try await load(sampleID: sampleID) else {
                    #if DEBUG
                    print("[MIDI-DEBUG] sample playback failed · reason=audio route unavailable")
                    #endif
                    return
                }
                hotCuePlatterPhase = midiControlLoop.latestPhase
                renderer.update(relativePlatterSteps: 0, signedVelocityStepsPerSecond: 0)
                try startEngineIfNeeded()
                renderer.activate()
                midiControlLoop.start(
                    renderer: renderer,
                    hotCuePhase: hotCuePlatterPhase ?? 0
                )
                #if DEBUG
                print("[MIDI-DEBUG] sample armed · \(sampleID)")
                #endif
            } catch {
                #if DEBUG
                print("[MIDI-DEBUG] sample playback failed · reason=\(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Applies the learned right-deck channel fader to scratch playback.
    func setRightUpfaderGain(_ normalizedGain: Double) {
        rightUpfaderGain = FaderCurveResponse.gain(
            forNormalizedPosition: normalizedGain,
            response: FaderCurveResponse(zeroAt: 0, oneAt: 1, shape: .linear)
        )
        publishUserMixerGain()
    }

    /// Applies the same sharp scratch cut-in curve used by macOS.
    func setCrossfaderPosition(_ normalizedPosition: Double) {
        crossfaderRightDeckGain = FaderCurveResponse.gain(
            forNormalizedPosition: normalizedPosition,
            response: FaderCurveResponse(
                zeroAt: 0,
                oneAt: MIDIFaderCurveConstants.sharpScratchCutInWidth,
                shape: .linear
            )
        )
        publishUserMixerGain()
    }

    /// Stop playback entirely and reset the playhead.
    func stop() {
        midiControlLoop.stop()
        renderer?.reset()
    }

    /// Begins recording the exact rendered scratch signal — the same
    /// samples already sent to the RANE for monitoring, tapped from the
    /// renderer's existing capture ring rather than a second renderer or an
    /// independently regenerated signal — into `url` for the duration of one
    /// Capture take. Brings the render graph up (idempotently, via the same
    /// route-preparation path `playHotCue` uses) even if no hot cue has been
    /// triggered yet, so the resulting file spans the full take with silence
    /// wherever nothing was played, matching how the take's other artifacts
    /// already span the full take duration. Safe to call whether or not a
    /// hot cue is armed; does not itself start or duplicate any playback.
    func startRecordingScratchAudio(to url: URL) async throws {
        let renderer = try await prepareRendererForCurrentRoute()
        try startEngineIfNeeded()
        try captureTap.start(
            renderer: renderer,
            destinationURL: url,
            sampleRate: IOScratchRenderer.captureSampleRate
        )
    }

    /// Stops recording and flushes the last captured frames to disk. Leaves
    /// live monitoring/playback untouched — only the capture tap is torn
    /// down.
    func stopRecordingScratchAudio() {
        captureTap.stop()
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

    /// CoreMIDI-thread publication surface for the audio-only absolute phase.
    /// The control loop owns the atomic handoff; no actor-isolated state is
    /// read or mutated here.
    nonisolated func publishRawPlatterPhase(_ phase: Double) {
        midiControlLoop.publish(phase: phase)
    }

    // MARK: - Internals

    /// Start the audio engine once, idempotently.
    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private var rightUpfaderGain: Double = 1
    private var crossfaderRightDeckGain: Double = 1

    private func publishUserMixerGain() {
        renderer?.setUserMixerGain(rightUpfaderGain * crossfaderRightDeckGain)
    }

    /// Builds the graph for the route observed at hot-cue load time. The RANE
    /// ONE MKII exposes Deck 1 on physical outputs 1/2 and Deck 2 on 3/4, so a
    /// four-channel discrete source writes only channels 2/3 (zero-based).
    /// Every other route retains the existing two-channel stereo graph.
    private func prepareRendererForCurrentRoute() async throws -> IOScratchRenderer {
        let session = AVAudioSession.sharedInstance()
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(true)
        }.value

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
        renderer.setUserMixerGain(rightUpfaderGain * crossfaderRightDeckGain)
        outputConfiguration = configuration

        #if DEBUG
        print("[SCRATCH-DEBUG] playback output configured · route=\(routeName) hardwareChannels=\(configuration.preferredHardwareChannelCount) channelMap=\(engine.outputNode.auAudioUnit.channelMap ?? [])")
        #endif
        return renderer
    }
}
