//  PracticeTipPicker.swift
//  ScratchLab — Phase C contextual practice-tip rotation.
//
//  Pure, deterministic selector. Replaces the random `tips.randomElement()`
//  pick in PracticeModeView.startSession when FeatureFlags.contextualTipsEnabled
//  is on. Reads only values already in ProgressManager and the active scratch;
//  no new persistence, no scoring, no ML, no UI.

import Foundation

enum PracticeTipPicker {

    /// Context passed in by the call site. All fields are already in
    /// memory in ProgressManager / the active Scratch; the picker never
    /// touches storage on its own.
    struct Context {
        let scratchTips: [String]
        let defaultTip: String
        let lastSession: SessionResult?
        let currentStreak: Int
        let lastPracticeDate: Date?
        let practiceCount: Int
        let now: Date
    }

    /// Stage tag the picker resolves to before choosing copy. Exposed
    /// for unit-test coverage of the boundary conditions.
    enum Stage: Equatable {
        case firstSession
        case returningAfterBreak
        case activeStreak
        case standardRotation
    }

    /// Threshold (in days) above which the picker treats the session
    /// as "returning after a break". Whole days; matches the streak
    /// model used elsewhere in ProgressManager.
    static let returningGapDays: Int = 3

    /// Minimum `currentStreak` value (in days) at which the picker
    /// treats the session as an active streak.
    static let activeStreakThreshold: Int = 2

    static func stage(for context: Context) -> Stage {
        if context.practiceCount == 0 { return .firstSession }
        if let last = context.lastPracticeDate {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: last, to: context.now).day ?? 0
            if days >= returningGapDays { return .returningAfterBreak }
        }
        if context.currentStreak >= activeStreakThreshold { return .activeStreak }
        return .standardRotation
    }

    /// Resolves a single tip string for the given context. Pure: same
    /// input → identical output across calls, no randomness.
    static func pick(context: Context) -> String {
        switch stage(for: context) {
        case .firstSession:
            return CoachCopy.Tip.contextualFirstSession
        case .returningAfterBreak:
            return CoachCopy.Tip.contextualReturning
        case .activeStreak:
            return CoachCopy.Tip.contextualActiveStreak
        case .standardRotation:
            return rotation(
                tips: context.scratchTips,
                defaultTip: context.defaultTip,
                index: context.practiceCount
            )
        }
    }

    /// Deterministic rotation through `tips` keyed off `index`. Returns
    /// `defaultTip` only when no scratch tips are available.
    private static func rotation(tips: [String], defaultTip: String, index: Int) -> String {
        guard !tips.isEmpty else { return defaultTip }
        let safeIndex = abs(index) % tips.count
        return tips[safeIndex]
    }
}
