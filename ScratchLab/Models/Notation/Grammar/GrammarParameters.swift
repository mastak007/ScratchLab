import Foundation

// MARK: - GrammarParameters

/// Tunable thresholds for `derivePrimitives(from:parameters:)`.
///
/// All units are in the **unbounded signed platter-axis displacement**
/// space of `PlatterPositionTimeline.PlatterPositionSample.position` —
/// i.e. the integrated tracker-delta units described in
/// `PlatterPositionTimeline.swift`. They are not calibrated to
/// revolutions; the renderer normalises into `0…1` at draw time.
///
/// Because the absolute unit is session-dependent, callers driving the
/// derivation from real captures may want to override these values
/// after inspecting `PlatterPositionTimeline.positionRange`. Tests use
/// bespoke parameter values to crisply control the classification
/// boundaries and stay independent of these defaults.
///
/// **Defaults are tuned to the local-only baby-scratch fixture's
/// per-interval velocity distribution**, not to any "perceived stroke"
/// count. The fixture's `|v|` distribution (computed from
/// sample-to-sample forward differences) is:
///
///     p10 ≈ 0.045   p25 ≈ 0.090   p50 ≈ 0.131
///     p75 ≈ 0.203   p90 ≈ 0.288   max ≈ 1.328
///
/// `idleVelocityEpsilon` sits between p10 and p25 so the slowest tail
/// of the distribution classifies as idle while genuine motion above
/// p25 keeps its sign. `cuspVelocityThreshold` sits near p75 so cusp
/// classification is reserved for the faster half of motion on both
/// sides of a reversal. The midpoint-crossing count quoted in
/// `AI_HANDOFF.md` (≈ 9 for this fixture) measures a different signal
/// — large-scale crossings of the position midline — and is **not**
/// the target of these defaults; click-anchor seams in the fixture's
/// linearly-interpolated samples drive derivative-sign-flips at a
/// granularity well above that count, and the grammar reports that
/// granular truth honestly rather than smoothing toward a perceptual
/// number.
///
/// **BPM-agnostic.** No field carries beat, bar, or subdivision
/// information; the grammar is strictly motion-shaped.
struct GrammarParameters: Equatable, Sendable, Codable {
    /// Speed magnitude (position-units / second) at or below which a
    /// pairwise sample interval is classified as idle. Must be > 0.
    let idleVelocityEpsilon: Double

    /// Minimum continuous below-epsilon duration (seconds) required to
    /// emit an `IdleHold` instead of merging the sub-epsilon run into
    /// adjacent direction segments. Must be > 0.
    let minimumIdleDwell: TimeInterval

    /// Speed-magnitude threshold (position-units / second) for cusp
    /// classification at a direct (non-idle) reversal. The reversal is
    /// classified `.cusp` only when **both** adjacent direction
    /// segments' peak speeds exceed this threshold; otherwise `.round`.
    /// Reversals bracketed by a valid `IdleHold` are always `.round`.
    /// Must be > 0.
    let cuspVelocityThreshold: Double

    init(idleVelocityEpsilon: Double,
         minimumIdleDwell: TimeInterval,
         cuspVelocityThreshold: Double) {
        self.idleVelocityEpsilon = idleVelocityEpsilon
        self.minimumIdleDwell = minimumIdleDwell
        self.cuspVelocityThreshold = cuspVelocityThreshold
    }

    /// Defaults tuned to the local-only baby-scratch fixture's
    /// per-interval velocity distribution (see the type-level doc).
    /// Override per-call when working against a capture whose
    /// `positionRange` or sampling cadence differs materially.
    static let standard = GrammarParameters(
        idleVelocityEpsilon: 0.05,
        minimumIdleDwell: 0.05,
        cuspVelocityThreshold: 0.20
    )
}
