//  PracticeMilestone.swift
//  ScratchLab — Phase C6a milestone catalog and picker.
//
//  Pure, deterministic selector that decides whether a just-completed
//  practice session crossed a recognised milestone (first saved
//  session, seven-day streak, hundred takes of a scratch). Read-only
//  consumption of values already in `ProgressManager`; never persists,
//  never writes, never affects scoring or capture.

import Foundation

// MARK: - PracticeMilestone

/// A milestone the app may surface in the Results overlay. Cases are
/// deliberately sparse — each one fires at most once across a user's
/// practice journey for a given scratch. No XP, no currency, no
/// leaderboards. Calm acknowledgement, not an achievement economy.
enum PracticeMilestone: Equatable, Sendable {
    /// User's first ever practice session (totalScratchAttempts == 1
    /// after recording).
    case firstSession

    /// Practice streak reached a recognised day milestone. Today only
    /// 7-day fires; future tiers can be added without touching call
    /// sites.
    case streakDay(Int)

    /// Practice count for the active scratch crossed a recognised
    /// total. Today only 100 fires.
    case scratchPracticeCount(scratchName: String, count: Int)
}

// MARK: - PracticeMilestonePicker

/// Pure, deterministic selector. Reads only values already in
/// `ProgressManager` and the active scratch; no Date, no clock, no
/// I/O, no UI. Same context → byte-identical output across calls.
enum PracticeMilestonePicker {

    /// Streak day-counts that trigger a milestone. Single tier today
    /// to keep the surface restrained — adding tiers later is a
    /// data-only change.
    static let streakDayMilestones: Set<Int> = [7]

    /// Per-scratch session counts that trigger a milestone. Single
    /// tier today.
    static let scratchPracticeCountMilestones: Set<Int> = [100]

    struct Context: Equatable {
        /// `ProgressManager.totalScratchAttempts` *after* the just-
        /// finished session has been recorded. Counts sessions, not
        /// raw mic attempts (`recordScratchAttempt` increments this
        /// once per session).
        let totalScratchAttempts: Int

        /// `ProgressManager.currentStreak` after the just-finished
        /// session.
        let currentStreak: Int

        /// Display name of the active scratch. `nil` when no scratch
        /// is selected (defensive).
        let scratchName: String?

        /// `scratchProgress.practiceCount` for the active scratch
        /// after the just-finished session. `nil` when no per-scratch
        /// entry exists yet.
        let scratchPracticeCount: Int?
    }

    /// Picks at most one milestone for the just-finished session. Order
    /// of priority:
    ///   1. First saved session (only fires when the total is exactly 1).
    ///   2. Streak day milestone.
    ///   3. Per-scratch practice-count milestone.
    /// Returns `nil` when none of the milestones apply — silence is
    /// the default, matching the Phase C silence rule.
    static func pick(from context: Context) -> PracticeMilestone? {
        if context.totalScratchAttempts == 1 {
            return .firstSession
        }
        if streakDayMilestones.contains(context.currentStreak) {
            return .streakDay(context.currentStreak)
        }
        if let count = context.scratchPracticeCount,
           let name = context.scratchName,
           scratchPracticeCountMilestones.contains(count) {
            return .scratchPracticeCount(scratchName: name, count: count)
        }
        return nil
    }
}
