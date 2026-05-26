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
/// after inspecting `PlatterPositionTimeline.positionRange`. The
/// `.standard` defaults are chosen to match the local-only baby-scratch
/// fixture characterised in `AI_HANDOFF.md` (≈ 0.30-unit span over
/// ≈ 26.5 s with ≈ 9 sign-flips, giving mean speed magnitudes near
/// 0.2 unit/s). Tests use bespoke parameter values to crisply control
/// the classification boundaries and stay independent of these defaults.
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

    /// Defaults derived from the local-only baby-scratch fixture
    /// shape. Override per-call when working against a capture whose
    /// `positionRange` differs materially.
    static let standard = GrammarParameters(
        idleVelocityEpsilon: 0.02,
        minimumIdleDwell: 0.05,
        cuspVelocityThreshold: 0.10
    )
}
