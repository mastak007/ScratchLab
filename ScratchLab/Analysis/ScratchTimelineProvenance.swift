// ScratchTimelineProvenance — a pure composition helper that turns a recorded ScratchTimeline
// JSON payload (as `Data`) into a `ScratchNotationLaneDisplayModel`, by chaining the existing,
// already-proven adapters:
//
//   Data → ScratchAnalysisTimelineAdapter.analyzeTimeline → ScratchAnalysisNotationAdapter
//        → ScratchNotationLaneDisplayAdapter
//
// It accepts `Data`, NOT a URL — it performs NO file I/O. (File reading, when it happens at all,
// lives only in a DEBUG-only macOS surface that hands this helper the bytes.) Calibration and the
// display full-scale are caller-supplied; there is no magic default. Deterministic, Foundation-only.
//
// This is "interpret a recorded timeline," not live capture: no MIDI, no realtime engine, no
// playback. Decode/validation failures surface as the existing `ScratchAnalysisTimelineError`.

import Foundation

enum ScratchTimelineProvenance {
    /// Decode + analyze a recorded ScratchTimeline JSON payload into a lane display model.
    /// - Throws: `ScratchAnalysisTimelineError.decodeFailed` if the payload is not a valid timeline.
    static func displayModel(
        from data: Data,
        calibration: ScratchAnalysisCalibration,
        fullScaleTravelPercent: Double
    ) throws -> ScratchNotationLaneDisplayModel {
        let output = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data, calibration: calibration)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        return ScratchNotationLaneDisplayAdapter.displayModel(
            from: ScratchNotationLanePreviewAdapter.preview(from: intent),
            fullScaleTravelPercent: fullScaleTravelPercent)
    }
}
