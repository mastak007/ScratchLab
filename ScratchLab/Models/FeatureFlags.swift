//  FeatureFlags.swift
//  ScratchLab — Phase A polish flag registry.

import Foundation

enum FeatureFlags {
    // Phase A flags land here, e.g. `static var streakChipEnabled: Bool { isOn("STREAK_CHIP") }`.

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
