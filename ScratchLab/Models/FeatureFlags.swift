//  FeatureFlags.swift
//  ScratchLab — Phase A polish flag registry.

import Foundation

enum FeatureFlags {

    // MARK: Phase A polish flags

    static var streakChipEnabled: Bool      { isOn("STREAK_CHIP",      releaseDefault: true) }
    static var recentSessionsEnabled: Bool  { isOn("RECENT_SESSIONS",  releaseDefault: true) }
    static var beatPulseEnabled: Bool       { isOn("BEAT_PULSE",       releaseDefault: true) }
    static var inputBreathingEnabled: Bool  { isOn("INPUT_BREATHING",  releaseDefault: true) }
    static var sessionCompletePolishEnabled: Bool { isOn("SESSION_COMPLETE_POLISH", releaseDefault: true) }
    static var honestFailureResultsCalloutEnabled: Bool { isOn("HONEST_FAILURE_RESULTS_CALLOUT", releaseDefault: true) }

    // Stub accessors for the slices in docs/planning/*.md. Every flag below is
    // release-default-false AND DEBUG-default-false until its owning slice opts
    // in. No behavior change lands with this scaffolding — accessors exist so
    // later slices can wire them without touching this file again.

    // MARK: Phase B — notation feels like a game

    static var laneJudgmentTintEnabled: Bool   { isOn("LANE_JUDGMENT_TINT",   releaseDefault: false, debugDefault: false) }
    static var lanePhraseTintEnabled: Bool     { isOn("LANE_PHRASE_TINT",     releaseDefault: false, debugDefault: false) }
    static var laneMicroFeedbackEnabled: Bool  { isOn("LANE_MICRO_FEEDBACK",  releaseDefault: false, debugDefault: false) }
    static var phraseMomentumHUDEnabled: Bool  { isOn("PHRASE_MOMENTUM_HUD",  releaseDefault: false, debugDefault: false) }
    static var unlockLadderEnabled: Bool       { isOn("UNLOCK_LADDER",        releaseDefault: false, debugDefault: false) }
    static var inSessionMomentumEnabled: Bool  { isOn("IN_SESSION_MOMENTUM",  releaseDefault: false, debugDefault: false) }
    static var sessionReplayEnabled: Bool      { isOn("SESSION_REPLAY",       releaseDefault: false, debugDefault: false) }

    // MARK: Phase C — coach intelligence + structured training

    static var contextualTipsEnabled: Bool          { isOn("CONTEXTUAL_TIPS",          releaseDefault: false, debugDefault: false) }
    static var coachingEventsPipelineEnabled: Bool  { isOn("COACHING_EVENTS_PIPELINE",  releaseDefault: false, debugDefault: false) }
    static var resultsDriftCoachingEnabled: Bool    { isOn("RESULTS_DRIFT_COACHING",    releaseDefault: false, debugDefault: false) }
    static var phraseCoachingSurfaceEnabled: Bool   { isOn("PHRASE_COACHING_SURFACE",   releaseDefault: false, debugDefault: false) }
    static var structuredDrillsEnabled: Bool        { isOn("STRUCTURED_DRILLS",         releaseDefault: false, debugDefault: false) }
    static var nextUpSuggestionEnabled: Bool        { isOn("NEXT_UP_SUGGESTION",        releaseDefault: false, debugDefault: false) }
    static var lastTakeReplayEnabled: Bool          { isOn("LAST_TAKE_REPLAY",          releaseDefault: false, debugDefault: false) }
    static var focusOfTheDayEnabled: Bool           { isOn("FOCUS_OF_THE_DAY",          releaseDefault: false, debugDefault: false) }
    static var milestonesEnabled: Bool              { isOn("MILESTONES",                releaseDefault: false, debugDefault: false) }
    static var needsReviewHintEnabled: Bool         { isOn("NEEDS_REVIEW_HINT",         releaseDefault: false, debugDefault: false) }

    // MARK: Phase D foundation — Studio Mode

    static var studioModeEnabled: Bool { isOn("STUDIO_MODE", releaseDefault: false, debugDefault: false) }

    // MARK: Phase D-A — analysis

    static var studioScrubEnabled: Bool           { isOn("STUDIO_SCRUB",           releaseDefault: false, debugDefault: false) }
    static var studioArchaeologyEnabled: Bool     { isOn("STUDIO_ARCHAEOLOGY",     releaseDefault: false, debugDefault: false) }
    static var studioAnnotationsEnabled: Bool     { isOn("STUDIO_ANNOTATIONS",     releaseDefault: false, debugDefault: false) }
    static var studioMultiTakeEnabled: Bool       { isOn("STUDIO_MULTITAKE",       releaseDefault: false, debugDefault: false) }
    static var studioDrillAuthoringEnabled: Bool  { isOn("STUDIO_DRILL_AUTHORING", releaseDefault: false, debugDefault: false) }
    static var studioWorkbenchEnabled: Bool       { isOn("STUDIO_WORKBENCH",       releaseDefault: false, debugDefault: false) }
    static var studioExportEnabled: Bool          { isOn("STUDIO_EXPORT",          releaseDefault: false, debugDefault: false) }

    // MARK: Phase D-X — cinematic export

    static var exportNotationOverlayVideoEnabled: Bool { isOn("EXPORT_NOTATION_OVERLAY_VIDEO", releaseDefault: false, debugDefault: false) }
    static var exportPhraseComparisonEnabled: Bool     { isOn("EXPORT_PHRASE_COMPARISON",      releaseDefault: false, debugDefault: false) }
    static var exportCinematicReplayEnabled: Bool      { isOn("EXPORT_CINEMATIC_REPLAY",       releaseDefault: false, debugDefault: false) }
    static var ndiFeedsEnabled: Bool                   { isOn("NDI_FEEDS",                     releaseDefault: false, debugDefault: false) }
    static var exportWorkbenchEnabled: Bool            { isOn("EXPORT_WORKBENCH",              releaseDefault: false, debugDefault: false) }

    // MARK: Phase D-S — spatial replay / AR

    static var spatialReplayIOSEnabled: Bool       { isOn("SPATIAL_REPLAY_IOS",       releaseDefault: false, debugDefault: false) }
    static var spatialGhostTakeEnabled: Bool       { isOn("SPATIAL_GHOST_TAKE",       releaseDefault: false, debugDefault: false) }
    static var spatialPhraseChaptersEnabled: Bool  { isOn("SPATIAL_PHRASE_CHAPTERS",  releaseDefault: false, debugDefault: false) }
    static var spatialReplayVisionOSEnabled: Bool  { isOn("SPATIAL_REPLAY_VISIONOS",  releaseDefault: false, debugDefault: false) }
    static var spatialArchaeologyEnabled: Bool     { isOn("SPATIAL_ARCHAEOLOGY",      releaseDefault: false, debugDefault: false) }

    // MARK: Phase E — instructor network

    static var instructorModeEnabled: Bool { isOn("INSTRUCTOR_MODE", releaseDefault: false, debugDefault: false) }

    // MARK: Phase F — long-term AR (no concrete flag names yet; sketch only)

    // MARK: Resolution

    static func isOn(
        _ key: String,
        releaseDefault: Bool = false,
        debugDefault: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let override = envOverride(key, environment: environment) { return override }
        #if DEBUG
        return debugDefault
        #else
        return releaseDefault
        #endif
    }

    static func envOverride(
        _ key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment["SCRATCHLAB_FF_\(key)"]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes", "on":  return true
        case "0", "false", "no", "off": return false
        default:                        return nil
        }
    }
}
