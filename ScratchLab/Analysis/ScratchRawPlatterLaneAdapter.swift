// ScratchRawPlatterLaneAdapter — DEBUG bridge from raw platter-position timeline
// debug export to lane preview model. Reads a raw_platter_debug.json file written
// alongside the session (by MacAnalyzerView or SessionExportCoordinator) and segments
// normalized position samples into directional strokes for the Travel Lane Debug view.
//
// This is a DEBUG diagnostic tool only — NOT production notation. The raw platter
// timeline carries unbounded signed platter-axis displacement from the hand tracker,
// normalised to 0…1 at write time. Strokes are segmented by direction changes on
// consecutive samples; no jitter threshold is applied (samples are sparse).
//
// Pure value transformation, deterministic, Foundation-only. No SwiftUI, no
// geometry/pixels, no I/O, no C++/bridge, no MIDI/audio/realtime.

import Foundation

// MARK: - Debug export DTO

/// The on-disk format of a `take-NNN_raw_platter_debug.json` file.
/// Written by `MacAnalyzerView` at export time (DEBUG-only) and copied into the
/// export bundle by `SessionExportCoordinator`. Read by this adapter for lane preview.
struct RawPlatterDebugExport: Codable, Equatable {
    let schemaVersion: String
    let takeID: String
    let takeNumber: Int
    let source: String
    let sampleCount: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let sampleRate: Double
    let positionSpan: Double
    let lowDensity: Bool
    let notPromoted: Bool
    let rendererEligibility: String
    let samples: [Sample]

    struct Sample: Codable, Equatable {
        let time: TimeInterval
        /// Position normalised 0…1 across the timeline's position span.
        /// 0 = minimum observed position, 1 = maximum.
        let normalizedPosition: Double
    }
}

// MARK: - Adapter

/// DEBUG bridge: `RawPlatterDebugExport` → `ScratchNotationLanePreviewModel`.
/// Segments normalised position samples into directional strokes for lane preview.
/// Does NOT depend on C++ analysis, cc6Step events, or the classifier pipeline.
enum ScratchRawPlatterLaneAdapter {

    /// Decode a raw platter debug export and produce a lane preview model.
    /// - Parameter data: Raw JSON bytes of a `take-NNN_raw_platter_debug.json` file.
    /// - Throws: On schema mismatch, empty samples, or decode failure.
    /// - Returns: A preview model ready for `ScratchNotationLaneDisplayAdapter`.
    static func previewModel(from data: Data) throws -> ScratchNotationLanePreviewModel {
        let export: RawPlatterDebugExport
        do {
            export = try JSONDecoder().decode(RawPlatterDebugExport.self, from: data)
        } catch {
            throw ScratchRawPlatterLaneAdapterError.decodeFailed(
                "Raw platter debug decode failed: \(error)")
        }

        guard export.schemaVersion.hasPrefix("scratchlab_raw_platter_debug") else {
            throw ScratchRawPlatterLaneAdapterError.decodeFailed(
                "Unexpected schemaVersion: \(export.schemaVersion)")
        }

        guard export.samples.count >= 2 else {
            throw ScratchRawPlatterLaneAdapterError.tooFewSamples(export.samples.count)
        }

        let strokes = strokesFromSamples(export.samples)
        guard !strokes.isEmpty else {
            throw ScratchRawPlatterLaneAdapterError.noStrokesProduced
        }

        return ScratchNotationLanePreviewModel(strokes: strokes, warnings: [])
    }

    // MARK: - Sample segmentation

    /// Segment normalised position samples into direction-based strokes.
    ///
    /// Algorithm: for each consecutive sample pair, compute
    /// `delta = normalizedPosition[i] - normalizedPosition[i-1]`.
    /// Positive delta → forward, negative → reverse, zero → same as
    /// previous. When direction changes, finalise the accumulated stroke.
    ///
    /// No jitter threshold — raw platter samples are sparse (typically
    /// 4–30 Hz) and every reversal is assumed intentional. Minimum
    /// stroke duration is 15 ms (matching the CC6 fallback guard).
    ///
    /// `travelPercent` = accumulated absolute normalised delta.
    /// Since position is already 0…1, this is the fraction of the full
    /// position span that the stroke traversed.
    private static func strokesFromSamples(
        _ samples: [RawPlatterDebugExport.Sample]
    ) -> [ScratchNotationLanePreviewModel.Stroke] {
        let minStrokeDuration: Double = 0.015

        var strokes: [ScratchNotationLanePreviewModel.Stroke] = []
        var currentDirection: ScratchStrokeDirection = .forward
        var strokeStartTime = samples[0].time
        var accumulatedDelta: Double = 0
        var prevPosition = samples[0].normalizedPosition
        var prevTime = samples[0].time
        var isFirstDirection = true

        for i in 1..<samples.count {
            let sample = samples[i]
            let delta = sample.normalizedPosition - prevPosition
            let deltaSign: ScratchStrokeDirection = delta >= 0 ? .forward : .reverse

            if isFirstDirection {
                currentDirection = deltaSign
                isFirstDirection = false
            } else if deltaSign != currentDirection {
                // Direction change — finalise previous stroke.
                let strokeDuration = prevTime - strokeStartTime
                if strokeDuration >= minStrokeDuration, accumulatedDelta > 0 {
                    strokes.append(ScratchNotationLanePreviewModel.Stroke(
                        direction: currentDirection,
                        startTime: strokeStartTime,
                        endTime: prevTime,
                        travelPercent: accumulatedDelta,
                        audibleState: .unknown
                    ))
                }
                // Start new stroke.
                currentDirection = deltaSign
                strokeStartTime = prevTime
                accumulatedDelta = abs(delta)
                prevPosition = sample.normalizedPosition
                prevTime = sample.time
                continue
            }

            accumulatedDelta += abs(delta)
            prevPosition = sample.normalizedPosition
            prevTime = sample.time
        }

        // Finalise last stroke.
        let finalDuration = prevTime - strokeStartTime
        if finalDuration >= minStrokeDuration, accumulatedDelta > 0 {
            strokes.append(ScratchNotationLanePreviewModel.Stroke(
                direction: currentDirection,
                startTime: strokeStartTime,
                endTime: prevTime,
                travelPercent: accumulatedDelta,
                audibleState: .unknown
            ))
        }

        return strokes
    }
}

// MARK: - Errors

enum ScratchRawPlatterLaneAdapterError: Error, Equatable {
    /// JSON is not a raw platter debug export (wrong schema, decode failure).
    case decodeFailed(String)
    /// The export has fewer than 2 samples — can't determine direction.
    case tooFewSamples(Int)
    /// No strokes were produced from the samples.
    case noStrokesProduced
}
