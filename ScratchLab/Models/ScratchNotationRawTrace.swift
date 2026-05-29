//  ScratchNotationRawTrace.swift
//  ScratchLab — raw progress trace for notation surfaces.
//
//  Pure, deterministic mapping from a list of bundled stroke segments
//  (`ScratchLabBabyScratchStrokeSegment`) to position-trace segments
//  (`ScratchNotationPositionTraceSegment`) that pass the JSON's
//  `startProgress` / `endProgress` through untouched.
//
//  This replaces `ScratchNotationPositionTrace.derive(...)` for Baby
//  Scratch. Baby's bundled JSON already encodes every stroke as a
//  full-sample sweep (forward 0 → 1, backward 1 → 0); the truthful
//  trace is those values directly, not a cursor walked through a
//  calibrated duration rate. The duration-proxy derivation (b40f1ac)
//  was an attempt to smooth a perceived monotony but it compressed
//  the cursor walk into a narrow band, producing a trace that
//  rendered as a shallow waveform wiggle (forensic on
//  `sl notation review 3.mp4`).
//
//  Per-scratch raw / derive choice:
//   - Baby Scratch: raw progress (this helper) — JSON is honest.
//   - Future scratch types whose JSON only carries direction +
//     duration: `ScratchNotationPositionTrace.derive(...)` with a
//     per-scratch movement rate. That helper and its tests remain in
//     the codebase for that purpose.

import Foundation

// MARK: - ScratchNotationRawTrace

enum ScratchNotationRawTrace {

    /// Builds a position trace by passing each stroke's
    /// `startProgress` / `endProgress` straight through. Skips
    /// `.neutral` segments because they are explicit holds, not
    /// scratches. No clamping, no rate, no cursor walk — same input
    /// → byte-identical output across calls.
    static func build(
        from segments: [ScratchLabBabyScratchStrokeSegment]
    ) -> [ScratchNotationPositionTraceSegment] {
        var trace: [ScratchNotationPositionTraceSegment] = []
        trace.reserveCapacity(segments.count)
        for segment in segments where segment.direction != .neutral {
            trace.append(
                ScratchNotationPositionTraceSegment(
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    startPosition: segment.startProgress,
                    endPosition: segment.endProgress,
                    direction: segment.direction
                )
            )
        }
        return trace
    }
}
