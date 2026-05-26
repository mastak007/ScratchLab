import Foundation

// MARK: - CoachingEventKind

/// The pure vocabulary of coaching-event kinds recognised at the
/// notation layer.
///
/// **Metadata only.** This type is a stable set of names. It does
/// not infer, detect, threshold, score, or otherwise claim that a
/// captured take "is" a particular coaching event — that work belongs
/// to layers above and is intentionally out of scope here. `.unknown`
/// is an explicit fallback for cases where a kind has not been
/// assigned; it is **not** a confidence proxy.
///
/// Raw values are stable, camelCase identifiers safe for persistence.
/// Strict decoding: an unknown raw value throws a `DecodingError`, it
/// does **not** silently fall back to `.unknown`.
enum CoachingEventKind: String, CaseIterable, Equatable, Sendable, Codable {
    case lateReversal
    case earlyReversal
    case unstableTiming
    case clippedMotion
    case incompletePhrase
    case noSignal
    case unknown
}

// MARK: - CoachingEventSeverity

/// Severity tier for a coaching event descriptor.
///
/// Metadata only — severity here is a tag, not a threshold. The app
/// may consult this when deciding how (or whether) to surface a
/// descriptor, but this enum does not itself classify or score
/// anything.
///
/// Raw values are stable, lowercase identifiers safe for persistence.
/// Strict decoding: an unknown raw value throws a `DecodingError`.
enum CoachingEventSeverity: String, CaseIterable, Equatable, Sendable, Codable {
    case info
    case notice
    case warning
}

// MARK: - CoachingEventDescriptor

/// A user-safe descriptor record for a `CoachingEventKind`. Carries
/// the product-facing `displayName`, an explanatory `body`, a
/// `severity` tier, and an `isResearchOnly` flag that the app may
/// consult before surfacing this event in product copy.
///
/// `isResearchOnly == true` indicates the descriptor is **not** ready
/// for user-facing claims at this stage of development, consistent
/// with `PROFILE.md`'s overclaim guidance. Future slices may flip
/// individual descriptors to research-safe once they are validated
/// end-to-end.
struct CoachingEventDescriptor: Equatable, Sendable, Codable {
    let kind: CoachingEventKind
    let severity: CoachingEventSeverity
    let displayName: String
    let body: String
    let isResearchOnly: Bool
}

// MARK: - CoachingEventCatalog

/// Deterministic, in-memory lookup table for
/// `CoachingEventDescriptor`s.
///
/// The catalog is purely declarative — no classifier, no clock, no
/// I/O, no thresholds. `all` is ordered exactly as
/// `CoachingEventKind.allCases`, so the catalog and the enum stay in
/// lock-step.
enum CoachingEventCatalog {

    /// All descriptors in `CoachingEventKind.allCases` order.
    ///
    /// The list is built from `CoachingEventKind.allCases` rather than
    /// hard-coded so a future case added to the enum must also be
    /// represented here (failure mode: `descriptor(for:)` would need a
    /// switch case extension, and the corresponding test cases would
    /// fail). Today every case is covered.
    static let all: [CoachingEventDescriptor] = CoachingEventKind.allCases.map(descriptor(for:))

    /// Look up the descriptor for a given kind. Always returns a fresh
    /// `CoachingEventDescriptor`; never `nil`, never throws.
    static func descriptor(for kind: CoachingEventKind) -> CoachingEventDescriptor {
        switch kind {
        case .lateReversal:
            return CoachingEventDescriptor(
                kind: .lateReversal,
                severity: .notice,
                displayName: "Late reversal",
                body: "The reversal appears after the expected timing point.",
                isResearchOnly: false
            )
        case .earlyReversal:
            return CoachingEventDescriptor(
                kind: .earlyReversal,
                severity: .notice,
                displayName: "Early reversal",
                body: "The reversal appears before the expected timing point.",
                isResearchOnly: false
            )
        case .unstableTiming:
            return CoachingEventDescriptor(
                kind: .unstableTiming,
                severity: .warning,
                displayName: "Unstable timing",
                body: "The timing varies across the phrase.",
                isResearchOnly: false
            )
        case .clippedMotion:
            return CoachingEventDescriptor(
                kind: .clippedMotion,
                severity: .warning,
                displayName: "Clipped motion",
                body: "The motion appears shortened before the phrase completes.",
                isResearchOnly: true
            )
        case .incompletePhrase:
            return CoachingEventDescriptor(
                kind: .incompletePhrase,
                severity: .notice,
                displayName: "Incomplete phrase",
                body: "The phrase appears to stop before the expected ending.",
                isResearchOnly: false
            )
        case .noSignal:
            return CoachingEventDescriptor(
                kind: .noSignal,
                severity: .info,
                displayName: "No usable signal",
                body: "ScratchLab could not find enough usable timing evidence.",
                isResearchOnly: false
            )
        case .unknown:
            return CoachingEventDescriptor(
                kind: .unknown,
                severity: .info,
                displayName: "Unknown",
                body: "ScratchLab does not have a specific coaching event for this case.",
                isResearchOnly: false
            )
        }
    }
}
