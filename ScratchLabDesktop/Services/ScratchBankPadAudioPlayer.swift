// ScratchBankPadAudioPlayer.swift
// ScratchLab Desktop — Scratch Bank Pad Audio Player
//
// Lightweight AVAudioPlayer-based sample player for macOS.
// Resolves scratch bank sample IDs to bundled WAV files and plays them.
// No MIDI routing. No scoring. No audio output routing.
//
// Owned by MacCaptureEngine; lives on the MIDI receive thread.

import AVFoundation
import Foundation

/// Plays scratch bank sample WAVs from the app bundle using AVAudioPlayer.
/// Designed as an injectable callback target for `MacCaptureEngine.scratchBankPadPreviewCallback`.
final class ScratchBankPadAudioPlayer {

    /// Sample ID → WAV filename lookup (mirrors ScratchBankDefaultAssignments).
    private static let sampleFileNames: [String: String] = [
        "ahhh":          "ahhh.wav",
        "fresh":         "fresh.wav",
        "ah_yeah":       "ah_yeah.wav",
        "check_it_out":  "check_it_out.wav",
    ]

    /// Bundle resource root for resolving WAV URLs.
    private let resourceRoot: URL?

    /// Most recent player (kept alive by the player itself during playback).
    private var currentPlayer: AVAudioPlayer?

    // MARK: - Init

    init(resourceRoot: URL? = Bundle.main.resourceURL) {
        self.resourceRoot = resourceRoot
    }

    // MARK: - Playback

    /// Plays the WAV for a scratch bank sample ID. No-ops silently when the
    /// sample ID is unknown or the file is missing — never crashes.
    func play(sampleID: String) {
        guard let url = wavURL(for: sampleID) else {
            #if DEBUG
            print("[ScratchBankPadAudioPlayer] WAV not found for sample ID: \(sampleID)")
            #endif
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            currentPlayer = player
        } catch {
            #if DEBUG
            print("[ScratchBankPadAudioPlayer] Error playing \(sampleID): \(error)")
            #endif
        }
    }

    /// Stops any currently playing sample.
    func stop() {
        currentPlayer?.stop()
        currentPlayer = nil
    }

    // MARK: - URL resolution (internal for testing)

    func wavURL(for sampleID: String) -> URL? {
        guard let fileName = Self.sampleFileNames[sampleID],
              let root = resourceRoot else { return nil }
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var knownSampleIDs: Set<String> {
        Set(sampleFileNames.keys)
    }
}
