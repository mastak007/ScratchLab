import Foundation

// MARK: - ScratchFamily

/// The semantic vocabulary of scratch families recognised at the
/// notation layer.
///
/// **Vocabulary only.** This type is a stable set of names. It does
/// not infer, classify, score, or otherwise claim that a captured take
/// "is" a particular family — that work belongs to layers above and
/// is intentionally out of scope here. `.unknown` is an explicit
/// fallback for cases where a label has not been assigned (manual or
/// otherwise); it is **not** a confidence proxy.
///
/// Independence from existing types: this enum is unrelated to the
/// ML layer's `ScratchClassLabel`. The ML enum is the classifier's
/// own vocabulary (research-only per `PROFILE.md`); this enum is the
/// notation layer's product-facing vocabulary and is the one to use
/// when describing family identity outside of classifier code.
///
/// Raw values are stable, lowercase, single-word identifiers safe for
/// persistence. Strict decoding: an unknown raw value throws a
/// `DecodingError`, it does **not** silently fall back to `.unknown`.
enum ScratchFamily: String, CaseIterable, Equatable, Sendable, Codable {
    case baby
    case scribble
    case chirp
    case flare
    case transform
    case tear
    case orbit
    case crab
    case unknown
}

// MARK: - ScratchFamilyLabel

/// A user-safe label record for a `ScratchFamily`. Carries the
/// product-facing `displayName` and a `isResearchOnly` flag that the
/// app may consult before surfacing this family in product copy.
///
/// `isResearchOnly == true` indicates the family is **not** ready for
/// user-facing claims at this stage of development — only `.baby` and
/// `.unknown` are flagged research-safe in this slice, consistent with
/// `PROFILE.md`'s "ML labels must not be used as truth in
/// Practice/Review yet" rule. Future slices may flip individual
/// families to research-safe once they are validated end-to-end.
struct ScratchFamilyLabel: Equatable, Sendable, Codable {
    let family: ScratchFamily
    let displayName: String
    let isResearchOnly: Bool
}

// MARK: - ScratchFamilyCatalog

/// Deterministic, in-memory lookup table for `ScratchFamilyLabel`s.
///
/// The catalog is purely declarative — no classifier, no clock, no
/// I/O. `all` is ordered exactly as `ScratchFamily.allCases`, so the
/// catalog and the enum stay in lock-step.
enum ScratchFamilyCatalog {

    /// All labels in `ScratchFamily.allCases` order.
    ///
    /// The list is built from `ScratchFamily.allCases` rather than
    /// hard-coded so a future case added to the enum must also be
    /// represented here (failure mode: `displayName(for:)` /
    /// `isResearchOnly(for:)` would need a switch case extension, and
    /// the corresponding test cases would fail). Today every case is
    /// covered.
    static let all: [ScratchFamilyLabel] = ScratchFamily.allCases.map { family in
        ScratchFamilyLabel(
            family: family,
            displayName: displayName(for: family),
            isResearchOnly: isResearchOnly(for: family)
        )
    }

    /// Look up the catalog label for a given family. Always returns a
    /// fresh `ScratchFamilyLabel`; never `nil`, never throws.
    static func label(for family: ScratchFamily) -> ScratchFamilyLabel {
        ScratchFamilyLabel(
            family: family,
            displayName: displayName(for: family),
            isResearchOnly: isResearchOnly(for: family)
        )
    }

    // MARK: Private metadata

    private static func displayName(for family: ScratchFamily) -> String {
        switch family {
        case .baby:      return "Baby Scratch"
        case .scribble:  return "Scribble"
        case .chirp:     return "Chirp"
        case .flare:     return "Flare"
        case .transform: return "Transform"
        case .tear:      return "Tear"
        case .orbit:     return "Orbit"
        case .crab:      return "Crab"
        case .unknown:   return "Unknown"
        }
    }

    private static func isResearchOnly(for family: ScratchFamily) -> Bool {
        switch family {
        case .baby, .unknown:
            return false
        case .scribble, .chirp, .flare, .transform, .tear, .orbit, .crab:
            return true
        }
    }
}
