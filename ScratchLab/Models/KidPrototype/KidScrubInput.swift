// KidScrubInput.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1, Slice 2).
//
// Pure, dependency-free model that converts drag/touch deltas into a
// normalized scratch position, signed velocity, and a direction. This is the
// prototype's ONE input pipeline (see analysis/kid_mode/
// KID_MODE_EXPERIMENT_PROTOCOL_V1.md §0): later presentation modes
// (ribbon / agent / hybrid) are a view-layer switch over this same data.
//
// No SwiftUI, no AVFoundation, no capture / notation / scoring dependency.
// Everything here is deterministic and finite by construction so it can be
// unit-tested in isolation (ScratchLabDesktopTests/KidScrubInputTests.swift).
//
// To remove the prototype: delete the ScratchLab/Models/KidPrototype folder,
// KidPrototypeView.swift, the KidScrubInputTests, and the
// FeatureFlags.kidPrototypeEnabled flag — production is then byte-identical.

import Foundation

struct KidScrubInput: Equatable, Sendable {

    enum Direction: Equatable, Sendable {
        case forward
        case backward
        case idle
    }

    /// Normalized platter position, always clamped to `0.0...1.0`.
    private(set) var position: Double

    /// Signed normalized-position units per second. Positive = forward,
    /// negative = backward, `0` when idle. Always finite.
    private(set) var velocity: Double

    /// Forward / backward / idle, derived from the latest delta.
    private(set) var direction: Direction

    /// Per-update deltas whose magnitude is below this read as a held finger
    /// (idle), not a scrub. Chosen small enough that any deliberate drag
    /// registers, large enough that sensor jitter does not.
    static let idleDeltaThreshold: Double = 1e-4

    init(position: Double = 0.5) {
        self.position = KidScrubInput.clampPosition(position)
        self.velocity = 0
        self.direction = .idle
    }

    /// Return to a known resting state. Defaults to the centre of the platter.
    mutating func reset(to position: Double = 0.5) {
        self.position = KidScrubInput.clampPosition(position)
        self.velocity = 0
        self.direction = .idle
    }

    /// Advance the model by a normalized position `delta` observed over
    /// `deltaTime` seconds. Deterministic and finite for any input: NaN/inf
    /// deltas or non-positive/!finite times never produce NaN/inf state.
    mutating func update(delta: Double, deltaTime: TimeInterval) {
        let safeDelta = delta.isFinite ? delta : 0
        let hasValidTime = deltaTime.isFinite && deltaTime > 0

        position = KidScrubInput.clampPosition(position + safeDelta)

        if abs(safeDelta) < KidScrubInput.idleDeltaThreshold || !hasValidTime {
            velocity = 0
            direction = .idle
            return
        }

        let computed = safeDelta / deltaTime
        velocity = computed.isFinite ? computed : 0
        direction = safeDelta > 0 ? .forward : .backward
    }

    /// Clamp to the valid normalized range, finite-safe (NaN/inf → centre).
    static func clampPosition(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1.0, max(0.0, value))
    }
}
