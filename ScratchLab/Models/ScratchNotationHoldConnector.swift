//  ScratchNotationHoldConnector.swift
//  ScratchLab — hold-connector geometry for notation surfaces.
//
//  Pure, deterministic helper that walks a list of derived position
//  trace segments and emits the horizontal "hold" segments that should
//  paint between consecutive strokes inside the same active phrase.
//
//  The position trace (`ScratchNotationPositionTrace`) already carries
//  the cursor forward across reversals — segment N+1's `startPosition`
//  equals segment N's `endPosition` by construction. But the renderer
//  only paints during `[startTime, endTime]` of each segment, so the
//  hold gap between strokes appears as blank canvas. That reads as
//  disconnected note marks, not as continuous scratch motion. This
//  helper fills the gaps with explicit hold segments so the renderer
//  has something to paint there.
//
//  Critically, hold segments are NOT emitted across inter-phrase
//  silence gaps. The same `silenceThreshold` the phrase gate uses
//  (default 1.5 s) decides whether a gap is intra-phrase (bridge) or
//  inter-phrase (suppress).
//
//  Tied to `ScratchNotationPhraseGate.defaultSilenceThreshold` so the
//  two helpers always agree on what counts as a silence boundary.

import Foundation

// MARK: - ScratchNotationHoldConnectorSegment

/// One horizontal hold segment to paint between two consecutive trace
/// segments. The position is the carried cursor value (segment N's
/// `endPosition`, equal to segment N+1's `startPosition`).
struct ScratchNotationHoldConnectorSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let position: Double
}

// MARK: - ScratchNotationHoldConnector

/// Pure mapper from a position trace to a list of hold connectors.
/// Same input → byte-identical output. No clock, no I/O, no UI.
enum ScratchNotationHoldConnector {

    /// Emits hold connectors for each gap between consecutive trace
    /// segments whose duration is `> 0` and `≤ silenceThreshold`.
    /// Skips zero-length gaps (back-to-back segments produce nothing
    /// visible). Skips gaps above the threshold (those are
    /// inter-phrase silences and must remain blank).
    static func connectors(
        from trace: [ScratchNotationPositionTraceSegment],
        silenceThreshold: TimeInterval = ScratchNotationPhraseGate.defaultSilenceThreshold
    ) -> [ScratchNotationHoldConnectorSegment] {
        guard trace.count >= 2 else { return [] }
        let safeThreshold = silenceThreshold.isFinite ? max(0, silenceThreshold) : 0
        var connectors: [ScratchNotationHoldConnectorSegment] = []
        connectors.reserveCapacity(trace.count - 1)
        for index in 0..<(trace.count - 1) {
            let current = trace[index]
            let next = trace[index + 1]
            let gap = next.startTime - current.endTime
            // Skip zero-length and negative-overlap gaps — nothing to
            // render. Skip above-threshold gaps — those are silences.
            guard gap > 0, gap <= safeThreshold else { continue }
            connectors.append(
                ScratchNotationHoldConnectorSegment(
                    startTime: current.endTime,
                    endTime: next.startTime,
                    position: current.endPosition
                )
            )
        }
        return connectors
    }
}

// MARK: - MacBabyScratchPracticeGuideRate

/// Calibration constants for the Mac Baby Scratch practice guide's
/// duration-proxy trace. Lives next to the helper that produces it so
/// renderers and tests share one source of truth.
///
/// **Rate semantics:** cursor units moved per second of stroke.
/// `1.0` would mean a 1-second stroke walks the full lane (0 → 1).
/// Baby Scratch strokes in the bundled JSON average ~0.4 s — at rate
/// 1.0 each stroke moves the cursor by 40 % of the lane and saturates
/// within one or two repeats. Rate 0.25 gives a visible walk across
/// the eleven-stroke phrase while still letting deliberately long
/// strokes approach the lane boundary.
///
/// **Why a constant, not data:** the bundled
/// `baby_scratch_strokes.json` encodes only direction + duration
/// (`startProgress` / `endProgress` are always 0 or 1). Real sample
/// position is not in the source data today, so the trace is a
/// duration-proxy. Per-scratch calibration is the honest interim
/// fix; the long-term answer is a JSON that ships real platter
/// position, at which point this constant becomes irrelevant.
enum MacBabyScratchPracticeGuideRate {
    /// Cursor units per second of stroke, calibrated for the bundled
    /// Baby Scratch demo. Empirically chosen so phrase 1's first five
    /// backward strokes walk visibly from 0.5 down without all pinning
    /// at the lane bottom, and so the climactic forward stroke at the
    /// end of each phrase reads clearly above the rest.
    static let calibratedBabyRate: Double = 0.25
}

// MARK: - MacBabyScratchPracticeGuideMarkers

/// Marker constants for the Mac Baby Scratch trace renderer.
///
/// **Honesty rule:** a marker dot must never imply an extra scratch
/// note. It exists only to anchor the *end* of a real stroke so the
/// cursor's resting value reads cleanly even on short strokes — not
/// to flag a separate event. The deliberate **absence** of a
/// `startDot…` constant on this enum is itself part of the contract.
///
/// **History:** b0e0336 enlarged the endpoint dot from 3.0 → 4.5 and
/// added a 4.5 px start-of-stroke dot at 0.95 alpha to anchor
/// reversals. Frame-by-frame review (`sl notation review 2.mp4`)
/// showed the combination of bright start dot + larger end dot +
/// hold connectors read as discrete "notes" at every catch
/// boundary. With hold connectors in place, the connector → slope
/// transition is itself the reversal marker — no start dot is
/// needed. These constants restore the pre-b0e0336 end-dot style.
enum MacBabyScratchPracticeGuideMarkers {
    /// End-of-stroke dot radius, in points. Subtle enough that the
    /// dot reads as an anchor and not as a note event.
    static let endDotRadius: Double = 3.0
    /// End-of-stroke dot colour alpha multiplier (applied on top of
    /// the direction colour).
    static let endDotAlpha: Double = 0.85
}
