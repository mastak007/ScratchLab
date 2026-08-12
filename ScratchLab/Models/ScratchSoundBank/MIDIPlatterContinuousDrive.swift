// MIDIPlatterContinuousDrive.swift
// ScratchLab — Direct-MIDI Continuous Platter Drive (2026-08-09)
//
// Pure-logic velocity estimator for driving the continuous vinyl renderer
// (`DVSContinuousVinylRenderer`) from the right-deck Rane ONE MKII platter's
// coalesced CC6 accumulated-step reading. No audio, no MIDI, no threading —
// deterministic and directly unit-testable.
//
// Model: the caller samples `ScratchPlatterTracker.accumulatedSteps(for:)`
// at a bounded cadence (the existing ~60 Hz control-side coalescing rate
// already established for MIDI scheduling) rather than per raw CC6 event,
// so this type's only job is turning two consecutive coalesced samples into
// a signed velocity (steps/second) from REAL elapsed monotonic time — never
// event count, never a fixed guessed interval. The full signed step delta
// is always returned so the caller can advance its own phase anchor
// losslessly even on ticks where no sane velocity can be derived (priming,
// sanitized/stall ticks) — mirrors the DVS control path's own split between
// "the phase anchor always advances by the real delta" and "the velocity
// estimate is what gets sanitized/capped."

import Foundation

/// One coalesced control tick's result.
struct MIDIPlatterContinuousDriveTick: Equatable {
    /// Full signed CC6 step delta since the previous sample — always exact,
    /// never dropped, so the caller's phase anchor never loses motion even
    /// when `velocity` is sanitized to 0.
    let deltaSteps: Double
    /// Signed steps/second, sanitized to 0 for stall / non-finite / zero /
    /// negative elapsed windows, and for genuinely no motion. 0 means the
    /// caller should settle to idle rather than publish a velocity.
    let velocity: Double
}

/// Deterministic signed-velocity estimator for the right-deck MIDI
/// continuous drive. One instance owns the running "last sample" state;
/// `reset()` clears it (used on ownership handoff so a stale delta/time
/// pair from a previous ownership window can never be diffed against a
/// fresh reading — no catch-up burst on resume).
struct MIDIPlatterContinuousDrive {

    /// Ticks whose real elapsed time exceeds this are treated as a stall
    /// (thread/queue delay, app suspension, or a genuine long pause) —
    /// mirrors the DVS control path's `maximumDVSControlWindow` philosophy:
    /// a stale window is never divided down into an inflated catch-up
    /// velocity. The step delta still counts in full toward the caller's
    /// phase anchor; only the derived velocity is suppressed for that tick.
    static let maximumControlWindow: TimeInterval = 0.25

    private var lastSteps: Int?
    private var lastTime: TimeInterval?

    /// Advances the estimator with the latest coalesced reading.
    /// - Parameters:
    ///   - accumulatedSteps: `ScratchPlatterTracker.accumulatedSteps(for:)`
    ///     for the owning deck, sampled at the caller's coalescing cadence.
    ///   - now: monotonic time (e.g. `CACurrentMediaTime()`).
    /// - Returns: `nil` only on the first (priming) call, when there is no
    ///   previous sample to diff against.
    mutating func tick(accumulatedSteps: Int, now: TimeInterval) -> MIDIPlatterContinuousDriveTick? {
        defer {
            lastSteps = accumulatedSteps
            if now.isFinite { lastTime = now }
        }
        guard let previousSteps = lastSteps, let previousTime = lastTime else {
            return nil
        }
        let deltaSteps = Double(accumulatedSteps - previousSteps)
        guard now.isFinite else {
            return MIDIPlatterContinuousDriveTick(deltaSteps: deltaSteps, velocity: 0)
        }
        let elapsed = now - previousTime
        guard elapsed.isFinite, elapsed > 0, elapsed <= Self.maximumControlWindow else {
            // Zero/negative/non-finite, or an abnormally long stall: the
            // real step delta above is still returned intact, but no sane
            // velocity can be derived from this window.
            return MIDIPlatterContinuousDriveTick(deltaSteps: deltaSteps, velocity: 0)
        }
        guard deltaSteps != 0 else {
            return MIDIPlatterContinuousDriveTick(deltaSteps: 0, velocity: 0)
        }
        return MIDIPlatterContinuousDriveTick(deltaSteps: deltaSteps, velocity: deltaSteps / elapsed)
    }

    /// Clears all history so the next `tick` is treated as priming.
    mutating func reset() {
        lastSteps = nil
        lastTime = nil
    }
}
