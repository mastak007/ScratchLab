// IOScratchPlaybackEngine.swift
// ScratchLab — iOS Scratch Playback Engine (runtime boundary)
//
// iOS-specific scratch playback boundary. This is the platform-side sink for
// resolved hot-cue triggers: the iOS MIDI dispatch resolves an action and calls
// into this engine instead of owning audio itself. Phase 1 keeps the current
// one-shot AVAudioPlayer implementation behind this interface unchanged.
//
// NOT the final scratch engine — only the runtime boundary. Full scratch
// playback (platter-driven, position-following) is a later phase.

import AVFoundation
import Foundation

@MainActor
final class IOScratchPlaybackEngine: ObservableObject {

    /// The active hot-cue player. Retained so playback is not cut short when a
    /// fresh `AVAudioPlayer` would otherwise deallocate at the end of the call.
    private var hotCuePlayer: AVAudioPlayer?

    /// The latest observed platter position. Stored only — Phase 2 is the
    /// data-flow boundary; no sample seeking or audio changes yet.
    private var currentPlatterPosition: PlatterPosition?

    #if DEBUG
    private var lastPlatterLogUptime: TimeInterval = -.infinity
    private let platterLogInterval: TimeInterval = 0.5
    #endif

    /// Load a scratch sample by ID. Phase 1 stub — full scratch loading is a
    /// later phase; the current runtime only performs one-shot hot-cue playback.
    func load(sampleID: String) {
    }

    /// Play a hot-cue sample immediately (one-shot). Current AVAudioPlayer-backed
    /// implementation, unchanged in behaviour — just moved behind this boundary.
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
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            hotCuePlayer = player
            #if DEBUG
            print("[MIDI-DEBUG] sample loaded · \(sampleID)")
            #endif
            guard player.play() else {
                #if DEBUG
                print("[MIDI-DEBUG] sample playback failed · reason=play returned false")
                #endif
                return
            }
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
        hotCuePlayer?.stop()
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
}
