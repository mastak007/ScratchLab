//  ScratchReviewHint.swift
//  ScratchLab — Phase C6b "needs review" derived hint.
//
//  Pure, deterministic picker that decides whether a previously-
//  mastered scratch is worth revisiting. Read-time-only — never
//  modifies `isMastered` or any other ProgressManager state. Replaces
//  mastery decay (which would touch persistence) with a soft nudge
//  derived entirely from values already in memory.

import Foundation

// MARK: - ScratchReviewHint

/// The derived hint state for one scratch on Level Select. `nil` cases
/// are absent from the type; callers use `Optional<ScratchReviewHint>`
/// so the absence (no hint) is the default.
enum ScratchReviewHint: Equatable, Sendable {
    /// Mastery was set long enough ago that revisiting is worthwhile.
    case stale(daysSinceMastered: Int)

    /// Recent accuracies have trended below the historical best by
    /// enough that revisiting is worthwhile.
    case regression
}

// MARK: - ScratchReviewHintPicker

/// Pure, deterministic selector. Reads only fields already on
/// `ScratchProgress` plus an injected `now` (so tests can lock
/// specific time scenarios). Never writes back, never affects
/// scoring, never flips `isMastered`.
enum ScratchReviewHintPicker {

    /// Days since `masteredDate` past which the hint fires. 14 days
    /// is generous — the hint is a nudge, not a penalty.
    static let staleAfterDays: Int = 14

    /// How many of the most recent accuracies are sampled to decide
    /// whether the user is regressing.
    static let regressionSampleCount: Int = 5

    /// Percentage-point drop below `bestAccuracy` (out of 100) that
    /// counts as regression. 15 points keeps the bar high — small
    /// fluctuations should not fire the hint.
    static let regressionThreshold: Double = 15.0

    struct Context: Equatable {
        let isMastered: Bool
        let masteredDate: Date?
        let bestAccuracy: Double
        let recentAccuracies: [Double]
        let now: Date
    }

    /// Picks at most one hint state. Returns `nil` when the scratch is
    /// not mastered (no hint applies pre-mastery) or when neither the
    /// stale nor the regression rule fires. Silence is the default
    /// per the Phase C silence rule.
    static func pick(from context: Context) -> ScratchReviewHint? {
        guard context.isMastered else { return nil }

        // Stale trigger
        if let mastered = context.masteredDate {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: mastered, to: context.now).day ?? 0
            if days >= staleAfterDays {
                return .stale(daysSinceMastered: days)
            }
        }

        // Regression trigger
        let recent = context.recentAccuracies.suffix(regressionSampleCount)
        guard recent.count >= regressionSampleCount else { return nil }
        let average = recent.reduce(0, +) / Double(recent.count)
        if context.bestAccuracy - average >= regressionThreshold {
            return .regression
        }

        return nil
    }
}
