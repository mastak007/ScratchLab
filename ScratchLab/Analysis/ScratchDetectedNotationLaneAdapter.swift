// ScratchDetectedNotationLaneAdapter — DEBUG bridge from detected-notation sidecar to lane
// preview model. Reads a SessionExportNotationDocument (take-NNN_detected_notation.json) and
// maps recordMovementEvents → ScratchNotationLanePreviewModel directly.
//
// This bypasses the C++ analysis pipeline (which requires raw cc6Step events). Position delta
// (abs(endPosition - startPosition)) is used as a DEBUG hand-movement proxy for travelPercent.
// This is NOT production platter travel — it is a CXL testing bridge only.
//
// Pure value transformation, deterministic, Foundation-only. No SwiftUI, no geometry, no I/O,
// no C++/bridge, no MIDI/audio/realtime, no production renderer change.

import Foundation

/// Errors raised by the detected-notation adapter. Decode/validation only.
enum ScratchDetectedNotationLaneAdapterError: Error, Equatable {
    /// JSON is not a detected-notation document (wrong schema, missing fields).
    case notDetectedNotationFormat(String)
    /// The document has zero record movement events — nothing to display.
    case emptyMovementEvents
}

/// DEBUG bridge: SessionExportNotationDocument → ScratchNotationLanePreviewModel.
/// Does NOT depend on C++ analysis or cc6Step events. Position delta is a hand-movement proxy.
enum ScratchDetectedNotationLaneAdapter {

    /// Decode a detected-notation sidecar and produce a lane preview model.
    /// - Parameter data: Raw JSON bytes of a `take-NNN_detected_notation.json` file.
    /// - Throws: `ScratchDetectedNotationLaneAdapterError` on schema mismatch or empty events.
    /// - Returns: A preview model ready for `ScratchNotationLaneDisplayAdapter`.
    static func previewModel(from data: Data) throws -> ScratchNotationLanePreviewModel {
        let document: DetectedNotationDTO
        do {
            document = try JSONDecoder().decode(DetectedNotationDTO.self, from: data)
        } catch {
            throw ScratchDetectedNotationLaneAdapterError.notDetectedNotationFormat(
                "Decode failed: \(error)")
        }

        guard document.schemaVersion.hasPrefix("scratchlab_detected_notation") else {
            throw ScratchDetectedNotationLaneAdapterError.notDetectedNotationFormat(
                "Unexpected schemaVersion: \(document.schemaVersion)")
        }

        let events = document.recordMovementEvents
        guard !events.isEmpty else {
            throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
        }

        let strokes: [ScratchNotationLanePreviewModel.Stroke] = events.compactMap { event in
            guard let direction = event.direction, !direction.isEmpty,
                  let startTime = event.startTime,
                  let endTime = event.endTime,
                  endTime > startTime,
                  let startPos = event.startPosition,
                  let endPos = event.endPosition else {
                return nil  // skip malformed events
            }

            let strokeDirection: ScratchStrokeDirection = direction == "backward" ? .reverse : .forward

            // DEBUG hand-movement proxy: position delta in normalized (0–1) hand-tracking space.
            // This is NOT platter cc6Step travel. It is a CXL testing visualisation only.
            let travelDelta = abs(endPos - startPos)

            // Derive audible state from event confidence and source.
            let audible: ScratchAudibleState
            if let confidence = event.confidence, let source = event.source {
                audible = (source == "fused" || source == "detected") && confidence >= 0.45
                    ? .audible : .unknown
            } else {
                audible = .unknown
            }

            return ScratchNotationLanePreviewModel.Stroke(
                direction: strokeDirection,
                startTime: startTime,
                endTime: endTime,
                travelPercent: travelDelta,
                audibleState: audible
            )
        }

        guard !strokes.isEmpty else {
            throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
        }

        return ScratchNotationLanePreviewModel(strokes: strokes, warnings: [])
    }

    // MARK: - Private Codable DTO (minimal mirror of SessionExportNotationDocument)

    /// Decodes only the fields needed by this adapter. This is a small private DTO —
    /// it does NOT duplicate the full production `SessionExportNotationDocument`.
    private struct DetectedNotationDTO: Decodable {
        let schemaVersion: String
        let recordMovementEvents: [MovementEventDTO]

        struct MovementEventDTO: Decodable {
            let direction: String?
            let startTime: Double?
            let endTime: Double?
            let startPosition: Double?
            let endPosition: Double?
            let confidence: Double?
            let source: String?
        }
    }
}
