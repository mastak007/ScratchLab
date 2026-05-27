//  FeatureFlags.swift
//  ScratchLab — Phase A polish flag registry.

import Foundation

enum FeatureFlags {

    // MARK: Phase A polish flags

    static var streakChipEnabled: Bool      { isOn("STREAK_CHIP",      releaseDefault: true) }
    static var recentSessionsEnabled: Bool  { isOn("RECENT_SESSIONS",  releaseDefault: true) }

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
