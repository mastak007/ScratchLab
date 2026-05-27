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
    }

    // MARK: Results overlay

    enum Results {
        static let mastery        = "MASTERY!"
        static let goodJob        = "GOOD JOB!"
        static let keepPracticing = "KEEP PRACTICING!"

        static let emojiMastery        = "🔥"
        static let emojiGoodJob        = "👏"
        static let emojiKeepPracticing = "💪"

        static let scoreLabel      = "Score"
        static let attemptsLabel   = "Attempts"
        static let bestStreakLabel = "Best Streak"
        static let backToLevel     = "Back to Level"

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
