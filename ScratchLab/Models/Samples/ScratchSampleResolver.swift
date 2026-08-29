// ScratchSampleResolver.swift
// ScratchLab - Shared Sample ID → URL Resolver
//
// Single pure resolver that maps a scratch sample ID to its playable bundle URL.
// Consolidates the bundled-sample lookup previously duplicated across macOS
// (`ScratchSamplePlaybackController.wavURL`) and iOS
// (`IOSMIDIControllerDispatcher.sampleURL`). No playback, no audio, no MIDI.
//
// Scope guardrails (deliberate):
// - Self-contained. `SampleManager` is iOS-only, so this resolver does NOT
//   reference it; most bundled `ScratchSamples/*.wav` are flattened into the
//   bundle root and resolve directly as `<id>.wav` on both platforms.
// - Custom/imported samples (iOS `SampleManager`'s Documents/ScratchSamples)
//   are not resolved here — neither of the consolidated call sites handled them.

import Foundation

enum ScratchSampleResolver {

    /// Sample IDs whose bundle path is not the flattened `<id>.wav` form.
    /// Both Ahhh entry points intentionally use the approved Virtual Platter
    /// recording so an older flattened resource cannot win bundle lookup.
    private static let subdirectoryPaths: [String: String] = [
        "ahhh": "VirtualPlatter/ahhh.wav",
        "dvs_ahhh": "VirtualPlatter/ahhh.wav",
    ]

    /// Resolves a scratch sample ID to a playable bundle URL, or nil when the
    /// sample is unknown. The common case is a direct `<id>.wav` lookup against
    /// the flattened bundle root; a small set of IDs live in a subdirectory.
    static func url(for sampleID: String) -> URL? {
        guard !sampleID.isEmpty else { return nil }

        if let path = Self.subdirectoryPaths[sampleID],
           let root = Bundle.main.resourceURL {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let url = Bundle.main.url(forResource: sampleID, withExtension: "wav") {
            return url
        }

        return nil
    }
}
