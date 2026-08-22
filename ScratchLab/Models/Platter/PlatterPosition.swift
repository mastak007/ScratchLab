// PlatterPosition.swift
// ScratchLab - Shared Platter Position Model
//
// Formalizes the shared, platform-independent output of platter movement so iOS
// and macOS describe the same four things with one type. The tracking
// algorithms that compute these values remain platform-specific — this is the
// shared output shape only.

import Foundation

/// Shared representation of platter movement output.
///
/// - `phase`: where the platter is (record turns on iOS, accumulated CC6 steps
///   on macOS).
/// - `direction`: the motion direction (forward / backward / idle).
/// - `velocity`: the angular rate (radians/sec on iOS, steps/sec on macOS).
/// - `normalizedPosition`: the normalized sample position, 0.0 = sample
///   beginning, 1.0 = sample end.
struct PlatterPosition {
    let phase: Double
    let direction: PlatterDirection
    let velocity: Double
    let normalizedPosition: Double
}
