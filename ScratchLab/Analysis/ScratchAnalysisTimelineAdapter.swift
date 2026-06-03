// ScratchAnalysisTimelineAdapter — offline proof against the REAL ScratchSampleTimeline shape.
//
// Decodes a local Codable mirror of `ScratchSampleTimelineEvent` (the RANE scratch-sample
// timeline format used on the rane branch) into the C++ core's input contract, then runs
// `ScratchAnalysis.analyze(...)`. This proves the analysis path is ready for the real
// capture shape WITHOUT importing any playback/render code:
//
// - It mirrors only the fields the analysis needs (`timeSeconds`, `cc6Step`, `crossfader`),
//   using the real property names as JSON keys, and ignores everything else by omission:
//   `position`, `velocity`, `muted`, all pitch-bend fields (`rawPitchBend`, `pitchBendDelta`,
//   `pitchBendAgeSeconds`), and all playback/render/zone fields (`mapperSampleSeconds`,
//   `audioRenderSeconds`, `audioMapperDriftSeconds`, `zoneAudioMode`, `zoneTargetSeconds`,
//   `zoneScrubRate`). Pitch bend stays diagnostic-only — never used for analysis.
// - The timeline already carries `cc6Step` (a signed step), so NO raw-CC6 ring-delta
//   derivation is needed or performed here.
// - The timeline JSON carries no calibration, so `stepsPerRevolution` / `crossfaderCutWidth`
//   are supplied explicitly by the caller (no hidden default).
//
// Deliberately narrow (Slice 4): only the timeline event shape is supported. The
// RaneDiagnostic raw-cc6 schema (which would need ring-delta) is intentionally NOT handled.

import Foundation

/// Errors raised while decoding a timeline. Decode/validation only — the C++ core's own
/// advisories (emptyInput, invalidCalibration, nonUnitStep) surface as warnings in the output.
enum ScratchAnalysisTimelineError: Error, Equatable {
    /// The JSON could not be decoded into the expected timeline shape (e.g. missing `events`).
    case decodeFailed(String)
}

enum ScratchAnalysisTimelineAdapter {
    /// Decode timeline JSON into wrapper-ready Swift values (no analysis yet).
    ///
    /// - `cc6Step`-bearing events become platter events; position-only samples (nil
    ///   `cc6Step`) are skipped — they carry no platter movement for the analysis core.
    /// - `crossfader`-bearing events become crossfader events; samples with nil `crossfader`
    ///   are skipped. If no event carries a crossfader value, the crossfader array is empty
    ///   and the C++ core reports `.unknown`.
    static func decodeTimelineInput(
        data: Data,
        calibration: ScratchAnalysisCalibration
    ) throws -> ScratchAnalysisFixtureInput {
        let document: TimelineDocument
        do {
            document = try JSONDecoder().decode(TimelineDocument.self, from: data)
        } catch {
            throw ScratchAnalysisTimelineError.decodeFailed(String(describing: error))
        }

        let platter: [ScratchAnalysisPlatterEvent] = document.events.compactMap { event in
            guard let step = event.cc6Step else { return nil }
            return ScratchAnalysisPlatterEvent(timeSeconds: event.timeSeconds, cc6Step: step)
        }
        let crossfader: [ScratchAnalysisCrossfaderEvent] = document.events.compactMap { event in
            guard let value = event.crossfader else { return nil }
            return ScratchAnalysisCrossfaderEvent(timeSeconds: event.timeSeconds, value: value)
        }
        return ScratchAnalysisFixtureInput(
            calibration: calibration, platter: platter, crossfader: crossfader)
    }

    /// Decode a timeline and run it through the Swift wrapper -> Obj-C++ bridge -> C++ core.
    static func analyzeTimeline(
        data: Data,
        calibration: ScratchAnalysisCalibration
    ) throws -> ScratchAnalysisOutput {
        let input = try decodeTimelineInput(data: data, calibration: calibration)
        return ScratchAnalysis.analyze(
            platter: input.platter,
            crossfader: input.crossfader,
            calibration: input.calibration
        )
    }

    // MARK: - Local Codable mirror of the real timeline shape (decode-only)

    /// Mirrors `ScratchSampleTimeline`'s encoded top level. Only `events` is read; other
    /// keys (`muteCrossfaderBelow`, `didReachCapacity`) are ignored by omission.
    private struct TimelineDocument: Decodable {
        let events: [TimelineEventDTO]
    }

    /// Mirrors the subset of `ScratchSampleTimelineEvent` the analysis needs. Field names
    /// match the real property names so real exports decode unchanged; every other key
    /// (position, velocity, muted, pitch bend, mapper/audio/zone fields) is ignored.
    private struct TimelineEventDTO: Decodable {
        let timeSeconds: Double
        let cc6Step: Int?
        let crossfader: Double?
    }
}
