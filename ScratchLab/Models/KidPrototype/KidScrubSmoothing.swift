// KidScrubSmoothing.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1.5, Part A).
//
// Pure, deterministic gain ramp used by KidScrubAudioPlayer to de-click the
// scrub output. The audio render previously hard-gated the output to 0 when the
// read head was still, which steps the waveform from a nonzero sample straight
// to silence (and back) — an audible click at every start, stop, reversal, and
// threshold toggle. This ramp replaces that binary gate: the player multiplies
// each output sample by a gain that glides toward a target (1.0 when moving,
// 0.0 when idle) over a short fade, turning those steps into short fades.
//
// No SwiftUI / AVFoundation / capture / notation / scoring dependency. Branch-
// free, allocation-free, finite-safe — safe to advance on the audio thread.
// Part B (read-rate / target smoothing) is intentionally NOT implemented here.

import Foundation

struct KidGainRamp: Equatable, Sendable {

    /// Current gain, always clamped to `0.0...1.0`.
    private(set) var gain: Double

    /// Per-sample step toward the target, always `>= 0` and finite. A full
    /// 0 -> 1 fade takes `ceil(1 / step)` samples.
    private(set) var step: Double

    /// Build a ramp from a fade length in seconds at a given sample rate.
    /// A `fadeSeconds` of ~0.005–0.008 s at 44.1 kHz yields a click-free,
    /// latency-light fade. Non-finite / non-positive arguments fall back to an
    /// instantaneous (step = 1) ramp rather than producing NaN/inf.
    init(fadeSeconds: Double, sampleRate: Double, initialGain: Double = 0) {
        let fadeSamples = (fadeSeconds.isFinite && sampleRate.isFinite && fadeSeconds > 0 && sampleRate > 0)
            ? fadeSeconds * sampleRate
            : 0
        self.step = fadeSamples >= 1 ? 1.0 / fadeSamples : 1.0
        self.gain = KidGainRamp.clampGain(initialGain)
    }

    /// Directly construct from a per-sample step (mainly for tests).
    init(step: Double, initialGain: Double = 0) {
        self.step = (step.isFinite && step > 0) ? min(1.0, step) : 1.0
        self.gain = KidGainRamp.clampGain(initialGain)
    }

    /// Advance one sample toward `target` (clamped to `0...1`), moving by at
    /// most `step`. Monotonic toward the target, never overshoots, never leaves
    /// `0...1`, and snaps exactly to the target once within one step so idle
    /// reaches true `0.0`. Returns the new gain for convenience.
    @discardableResult
    mutating func advance(toward target: Double) -> Double {
        let goal = KidGainRamp.clampGain(target)
        let delta = goal - gain
        if abs(delta) <= step {
            gain = goal
        } else {
            gain += delta > 0 ? step : -step
        }
        return gain
    }

    static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }
}
