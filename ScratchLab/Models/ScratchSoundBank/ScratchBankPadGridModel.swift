// ScratchBankPadGridModel.swift
// ScratchLab - Scratch Bank Pad Grid Model
// Data-only types shared between iOS views and macOS desktop tests.
// No MIDI routing. No live hardware triggering. No scoring.

import Foundation

// MARK: - Scratch Bank Default Assignments

/// Default 4-pad scratch bank assignment catalog.
/// Pads 1–4 map to bundled scratch samples by sample ID.
/// These are display-only defaults; no MIDI or audio routing yet.
enum ScratchBankDefaultAssignments {
    /// Ordered pad assignments (pad 1 … pad 4).
    /// Pads 5–8 are intentionally absent from this slice.
    static let defaultPadSampleIDs: [String] = [
        "ahhh",          // Pad 1
        "fresh",         // Pad 2
        "ah_yeah",       // Pad 3
        "check_it_out"   // Pad 4
    ]

    /// Resolve sample ID for a 0-based pad index.
    static func sampleID(for padIndex: Int) -> String? {
        guard (0..<defaultPadSampleIDs.count).contains(padIndex) else { return nil }
        return defaultPadSampleIDs[padIndex]
    }
}

// MARK: - Scratch Bank Pad Grid View Model

/// Lightweight observable intent model so tests can verify preview actions
/// without hitting AVAudioPlayer.
final class ScratchBankPadGridViewModel: ObservableObject {
    /// The last sample ID that was requested for preview.
    /// Nil if no preview has been requested yet.
    @Published var lastPreviewedSampleID: String?

    /// The last sample ID that was selected (assigned to the active slot).
    @Published var lastSelectedSampleID: String?

    func recordPreview(_ sampleID: String) {
        lastPreviewedSampleID = sampleID
    }

    func recordSelection(_ sampleID: String) {
        lastSelectedSampleID = sampleID
    }
}
