// ScratchDetectedNotationLaneAdapter — DEBUG bridge from detected-notation sidecar to lane
// preview model. Reads a SessionExportNotationDocument (take-NNN_detected_notation.json) and
// maps recordMovementEvents → ScratchNotationLanePreviewModel directly.
//
// Fallback: when recordMovementEvents is empty, extracts RANE ONE MKII / MIDI CC6 platter
// data from mixerMidiEvents and segments raw CC6 values into strokes via unwrap + direction-
// change detection. This is a DEBUG CC6 platter proxy — NOT production notation.
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
    /// The document has zero record movement events and no usable MIDI CC6 platter data.
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

        // Path 1: recordMovementEvents (camera hand-tracking pipeline).
        let recordEvents = document.recordMovementEvents
        if !recordEvents.isEmpty {
            let strokes = strokesFromRecordMovementEvents(recordEvents)
            guard !strokes.isEmpty else {
                throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
            }
            return ScratchNotationLanePreviewModel(strokes: strokes, warnings: [])
        }

        // Path 2: fallback to MIDI CC6 platter data from mixerMidiEvents.
        if let cc6Events = document.mixerMidiEvents?.filter({ $0.controller == 6 }),
           !cc6Events.isEmpty {
            let strokes = try strokesFromCC6Events(cc6Events)
            return ScratchNotationLanePreviewModel(strokes: strokes, warnings: [])
        }

        throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
    }

    // MARK: - Path 1: recordMovementEvents → strokes (existing, unchanged)

    private static func strokesFromRecordMovementEvents(
        _ events: [DetectedNotationDTO.MovementEventDTO]
    ) -> [ScratchNotationLanePreviewModel.Stroke] {
        events.compactMap { event in
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
    }

    // MARK: - Path 2: MIDI CC6 platter events → strokes (DEBUG CC6 platter proxy)

    /// DEBUG CC6 platter proxy — raw MIDI CC6 values unwrapped to signed position.
    /// Segment into strokes by direction changes. Travel is accumulated CC6 delta / 127.
    /// This is NOT production notation — it is a CXL testing bridge only.
    ///
    /// - Parameter events: CC6 events already filtered to `controller == 6`, sorted by time.
    /// - Throws: `.emptyMovementEvents` if no strokes were produced.
    private static func strokesFromCC6Events(
        _ events: [DetectedNotationDTO.MixerMidiEventDTO]
    ) throws -> [ScratchNotationLanePreviewModel.Stroke] {
        // Sort defensively by time (events should arrive in order, but guarantee it).
        let sorted = events.sorted { $0.takeRelativeTime < $1.takeRelativeTime }
        guard sorted.count >= 2 else {
            throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
        }

        // Constants — DEBUG thresholds, not production.
        let minStrokeDuration: Double = 0.015   // 15ms minimum stroke duration
        let minStrokeTravel: Int = 2            // minimum accumulated CC6 delta per stroke
        let jitterSteps: Int = 3               // micro-reversals < this many steps are jitter
        let wrapThreshold: Int = 64             // half the 0..127 range for wrap detection

        var strokes: [ScratchNotationLanePreviewModel.Stroke] = []

        var currentDirection: ScratchStrokeDirection = .forward
        var strokeStartTime = sorted[0].takeRelativeTime
        var accumulatedDelta = 0
        var prevValue = sorted[0].value
        var prevTime = sorted[0].takeRelativeTime
        var isFirstDirection = true

        // Jitter tracking: when direction reverses briefly, accumulate opposite travel.
        // If it exceeds jitterSteps, confirm the direction change; otherwise merge it.
        var pendingReverseDelta = 0
        var pendingReverseStartTime = 0.0
        var inPendingReverse = false

        for i in 1..<sorted.count {
            let event = sorted[i]
            var delta = event.value - prevValue

            // Unwrap: handle MIDI CC6 127→0 and 0→127 boundaries.
            if delta > wrapThreshold {
                delta -= 128   // forward wrap (e.g., 127→0 = real +1)
            } else if delta < -wrapThreshold {
                delta += 128   // backward wrap (e.g., 0→127 = real -1)
            }

            let deltaSign: ScratchStrokeDirection = delta >= 0 ? .forward : .reverse

            if isFirstDirection {
                currentDirection = deltaSign
                isFirstDirection = false

            } else if deltaSign != currentDirection {
                // Direction reversal detected. Accumulate in the pending opposite-direction buffer.
                if !inPendingReverse {
                    inPendingReverse = true
                    pendingReverseDelta = delta
                    pendingReverseStartTime = prevTime
                } else {
                    // Continue in the opposite direction.
                    pendingReverseDelta += delta
                }

                // Check if this reverse has become significant.
                if abs(pendingReverseDelta) >= jitterSteps {
                    // Confirm the reversal — finalize the previous stroke.
                    if abs(accumulatedDelta) >= minStrokeTravel,
                       (prevTime - strokeStartTime) >= minStrokeDuration {
                        strokes.append(ScratchNotationLanePreviewModel.Stroke(
                            direction: currentDirection,
                            startTime: strokeStartTime,
                            endTime: prevTime,
                            travelPercent: Double(abs(accumulatedDelta)) / 127.0,
                            audibleState: .unknown
                        ))
                    }

                    // Start new stroke from when the reversal began.
                    currentDirection = deltaSign
                    strokeStartTime = pendingReverseStartTime
                    accumulatedDelta = pendingReverseDelta
                    inPendingReverse = false
                    pendingReverseDelta = 0
                }

                prevValue = event.value
                prevTime = event.takeRelativeTime
                continue
            }

            // Same direction continued, or jitter absorbed.
            if inPendingReverse {
                // The reversal was jitter — discard it and merge back into the main stroke.
                accumulatedDelta += pendingReverseDelta + delta
                inPendingReverse = false
                pendingReverseDelta = 0
            } else {
                accumulatedDelta += delta
            }

            prevValue = event.value
            prevTime = event.takeRelativeTime
        }

        // Finalize the last stroke (including any pending reversal that was the last thing).
        if inPendingReverse {
            if abs(pendingReverseDelta) >= minStrokeTravel,
               (prevTime - pendingReverseStartTime) >= minStrokeDuration {
                strokes.append(ScratchNotationLanePreviewModel.Stroke(
                    direction: currentDirection == .forward ? .reverse : .forward,
                    startTime: pendingReverseStartTime,
                    endTime: prevTime,
                    travelPercent: Double(abs(pendingReverseDelta)) / 127.0,
                    audibleState: .unknown
                ))
            }
        } else if abs(accumulatedDelta) >= minStrokeTravel,
                  (prevTime - strokeStartTime) >= minStrokeDuration {
            strokes.append(ScratchNotationLanePreviewModel.Stroke(
                direction: currentDirection,
                startTime: strokeStartTime,
                endTime: prevTime,
                travelPercent: Double(abs(accumulatedDelta)) / 127.0,
                audibleState: .unknown
            ))
        }

        guard !strokes.isEmpty else {
            throw ScratchDetectedNotationLaneAdapterError.emptyMovementEvents
        }

        return strokes
    }

    // MARK: - Private Codable DTO (minimal mirror of SessionExportNotationDocument)

    /// Decodes only the fields needed by this adapter. This is a small private DTO —
    /// it does NOT duplicate the full production `SessionExportNotationDocument`.
    private struct DetectedNotationDTO: Decodable {
        let schemaVersion: String
        let recordMovementEvents: [MovementEventDTO]
        let mixerMidiEvents: [MixerMidiEventDTO]?

        struct MovementEventDTO: Decodable {
            let direction: String?
            let startTime: Double?
            let endTime: Double?
            let startPosition: Double?
            let endPosition: Double?
            let confidence: Double?
            let source: String?
        }

        /// Mirrors only the fields needed for CC6 unwrap. Controller-only filter
        /// (not device-specific) — works with any MIDI controller that maps platter
        /// to CC6, not just RANE ONE MKII.
        struct MixerMidiEventDTO: Decodable {
            let takeRelativeTime: Double
            let controller: Int
            let value: Int
        }
    }
}
