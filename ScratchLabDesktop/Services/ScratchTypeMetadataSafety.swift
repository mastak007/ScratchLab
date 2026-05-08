import Foundation

/// Guard rails that ensure scratch-type metadata about to land in the
/// UI, in an exported manifest, or in a session payload only ever
/// carries safe, app-review-friendly tokens. The detection layer can
/// freely add new `CaptureSessionScratchType` cases (Chirp, Flare,
/// Transform, …); these helpers guarantee that no banned source /
/// vendor / rights string slips out alongside them.
enum ScratchTypeMetadataSafety {
    /// Tokens that must never appear in any scratch-type id, name, or
    /// notes field that surfaces in the UI or in an exported package.
    /// Ordered for readability; matched case-insensitively.
    static let bannedSubstrings: [String] = [
        "/Users/",
        "MakeMKV",
        "processed_makemkv",
        "sourceMKV",
        "sourceDVD",
        "QBERT",
        "SXRATCH",
        "rightsStatus",
        "reviewStatus",
    ]

    /// Returns `true` when `value` is safe to surface in app-facing
    /// metadata. `nil` and empty strings are treated as safe — callers
    /// validate presence separately.
    static func isSafe(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return true }
        let lowered = value.lowercased()
        for token in bannedSubstrings {
            if lowered.contains(token.lowercased()) {
                return false
            }
        }
        return true
    }

    /// Returns `value` unchanged if it is safe; otherwise returns
    /// `nil`. Use this on the boundary just before writing to a UI
    /// label or an export payload.
    static func sanitized(_ value: String?) -> String? {
        guard isSafe(value) else { return nil }
        return value
    }

    /// Maps an arbitrary input string to the matching
    /// `CaptureSessionScratchType` enum case, accepting both the raw
    /// case name (`"babyScratch"`) and the canonical token form
    /// (`"baby_scratch"`). Returns `nil` when the input is not a
    /// known canonical scratch type. This mirrors the Python
    /// normalizer in `scripts/dataset_processor/process_dataset.py`
    /// at the boundary between offline labels and the in-app enum.
    static func canonicalScratchType(forIdentifier identifier: String?) -> CaptureSessionScratchType? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = CaptureSessionScratchType(rawValue: trimmed) {
            return direct
        }
        let lowered = trimmed.lowercased()
        if let lowercased = CaptureSessionScratchType(rawValue: lowered) {
            return lowercased
        }
        for type in CaptureSessionScratchType.allCases {
            if type.title.lowercased() == lowered {
                return type
            }
        }
        return nil
    }
}
