//  CoachCopy.swift
//  ScratchLab — single source of truth for user-facing coaching, results,
//  and preview strings. Every string here must pass the PROFILE.md vocab
//  audit: no "AI detects", no "deep learning", no "real-time AI coach",
//  no "perfectly detects". Audio-derived metrics carry the "(preview)"
//  suffix and the canonical not-saved-exported-scored disclaimer.

import Foundation

enum CoachCopy {

    // MARK: Practice assist modes

    enum AssistMode {
        static let autoCutExplainer = "Animates the target pattern as a looping visual preview. App audio is coming later — for now, no playback."
        static let demoExplainer    = "ScratchLab plays the demo audio and moves the notation in time — watch and listen; this run isn't scored."
        static let guidedExplainer  = "ScratchLab shows upcoming cut cues while you move the fader."
        static let coachedExplainer = "Target pattern loops in time. Mic listens for your scratches; in-session comparison is coming."
        static let openExplainer    = "Static target reference. Mic listens; freestyle freely. No beat unless you turn one on."
    }

    // MARK: Session tips

    enum Tip {
        static let comboCleared     = "Phrase cleared. Hold onto the same clean motion."
        static let comboInProgress  = "Chain four clean baby hits before the phrase window resets."
        static let guided           = "Follow the cue card and hit each move on time."
        static let defaultExecution = "Focus on clean execution"

        // Phase C contextual practice tips. Each string is declarative,
        // observational, and free of grading or celebration verbs —
        // matching the PROFILE.md uncertainty vocabulary in Section X
        // of the master roadmap.
        static let contextualFirstSession =
            "First time on this one — move slowly through the pattern. Speed comes after the motion clicks."
        static let contextualReturning =
            "Coming back to this one — walk through it slowly once before pushing the tempo."
        static let contextualActiveStreak =
            "Same beat, same window. Hold onto what is already working."
    }

    // MARK: Results overlay

    enum Results {
        static let mastery        = "MASTERY!"
        static let goodJob        = "GOOD JOB!"
        static let keepPracticing = "KEEP PRACTICING!"

        static let emojiMastery        = "🔥"
        static let emojiGoodJob        = "👏"
        static let emojiKeepPracticing = "💪"

        static let scoreLabel        = "Score"
        static let attemptsLabel     = "Attempts"
        static let bestStreakLabel   = "Best Streak"
        static let backToLevel       = "Back to Level"
        static let primaryMetricLabel = "On Beat"

        static let progressToPhraseClear = "Progress to Phrase Clear"
        static let progressToMastery     = "Progress to Mastery"

        static func phraseClearProgress(percentRemaining: Int) -> String {
            "\(percentRemaining)% more to clear the phrase"
        }
        static func masteryProgress(percentRemaining: Int) -> String {
            "\(percentRemaining)% more to master"
        }
    }

    // MARK: Progression

    enum Progression {
        static let streakStart = "Start a streak"
        static func streakDay(_ n: Int) -> String {
            "Day \(n)"
        }

        // Phase B4 — progression visibility. Copy stays declarative and
        // avoids the PROFILE.md-forbidden progression vocabulary — the
        // ladder simply shows what is mastered today and what is
        // available next.

        static let availableNextHeader = "AVAILABLE NEXT"
        static let inSessionMomentumLabel = "Session progress"

        static func ladderMasteredAccessibility(name: String) -> String {
            "\(name) mastered"
        }
        static func ladderAvailableAccessibility(name: String) -> String {
            "\(name) available"
        }
        static func ladderInProgressAccessibility(name: String, count: Int) -> String {
            "\(name), \(count) practiced"
        }
    }

    // MARK: Per-scratch progress (LevelSelectView cards)

    enum ScratchCard {
        static let bestRunLabel = "Best Run"
        static let takesLabel   = "Takes"
        static let mastered     = "Mastered"
    }

    // MARK: Recent sessions strip (LevelSelectView)

    enum Recent {
        static let header     = "RECENT"
        static let emptyState = "Your recent sessions will appear here"
        static let today      = "Today"
        static let yesterday  = "Yesterday"
        static func daysAgo(_ n: Int) -> String { "\(n)d ago" }
    }

    // MARK: Live practice (LevelSelectView header)

    enum Practice {
        static let liveTitle           = "LIVE PRACTICE"
        static let liveSubtitle        = "Pick a scratch first, then open the existing live setup with optional beat guidance and ScratchLab Coach."
        static let selectScratchHeader = "SELECT A SCRATCH"
    }

    // MARK: Combo challenge (Baby Flow card)

    enum Combo {
        static let babyFlowTitle  = "BABY FLOW"
        static let babyFlowBody   = "Visual combo challenge: lock 4 baby scratches in one loop at 100 BPM with optional beat guidance or live audio only."
        static let cuesVisualNote = "The cue stays visual here too, so the analyzer keeps following your live input without loading a beat."

        static let badgeCleared = "CLEARED"
        static let badgeLive    = "LIVE"

        static let bestRunLabel = "Best Run"
        static let statusLabel  = "Status"

        static let statusCleared = "Challenge cleared"
        static let statusNoClean = "No clean loop yet"
        static let valueCleared  = "Cleared"
        static let valueBuilding = "Building"
        static let valueFresh    = "Fresh"

        static func bestRunPercent(_ percent: Int) -> String {
            "Best run \(percent)%"
        }
    }

    // MARK: Phrase momentum HUD (Phase B3)
    //
    // Visual-only chip in PracticeModeView. Tracks consecutive phrases
    // landed within the timing window — never affects any score or
    // attempt counter. Copy stays declarative: a small numeric badge
    // plus a static label, no celebratory verbs and no PROFILE.md-
    // forbidden adjectives.

    enum PhraseMomentum {
        static let chipLabel = "Phrases in a row"
        static func chipValue(_ count: Int) -> String {
            "\(count)"
        }
    }

    // MARK: Structured drill summary (Phase C3)
    //
    // Visible at the end of a structured-drill (combo) session when
    // FeatureFlags.structuredDrillsEnabled is on. Three honest counters
    // plus one named subskill — never any grading verbs. Repetitions
    // are loops actually completed; landed attempts are the best run's
    // confirmed steps; the subskill is the active scratch's display
    // name.

    enum DrillSummaryCopy {
        static let header              = "DRILL SUMMARY"
        static let repetitionsLabel    = "Repetitions"
        static let landedLabel         = "Landed within window"
        static let subskillLabel       = "Subskill"

        static func landedFraction(landed: Int, expected: Int) -> String {
            "\(landed)/\(max(1, expected))"
        }
    }

    // MARK: Honest-failure callouts (results overlay)
    //
    // Advisory copy that follows the PROFILE.md vocab discipline: no
    // "failed" / "wrong" / "AI" / "classifier" / "accuracy". Each string
    // describes what was observed and proposes a concrete next step.

    enum LowSignal {
        static let noAttempts  = "We didn't pick up any attempts on this take. Check your input and run it again when you're ready."
        static let fewAttempts = "Only a few attempts came through on this take. Run it again when you're ready."
    }

    // MARK: Practice-timing preview card
    //
    // PROFILE.md-compliant preview surface. Required vocab: "on-device audio
    // onsets", "(preview)", "aren't saved, exported, or scored". No
    // classifier names, no confidence numbers.

    enum TimingPreview {
        static let header          = "PRACTICE TIMING · PREVIEW"
        static let takeLengthLabel = "Take length"
        static let attemptsLabel   = "Attempts on mic"
        static let onBeatLabel     = "On-beat estimate"
        static let avgTimingLabel  = "Avg timing"
        static let previewSuffix   = "(preview)"
        static let disclaimer      = "Timing estimates are based on on-device audio onsets. They aren't saved, exported, or scored."
    }
}
