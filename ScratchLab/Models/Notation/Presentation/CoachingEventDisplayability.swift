import Foundation

// MARK: - CoachingEventDisplayability

/// Presentation-layer projection that decides whether (and how
/// strongly) a coaching event should appear on a user-facing surface.
///
/// **Why a presentation-layer projection.** `CoachingEvent`'s contract
/// is "manual metadata only, no inference, no thresholding" — adding
/// numeric confidence to the value type would leak into export and
/// violate the contract. Confidence therefore lives here, derived at
/// the adapter level from existing signals.
///
/// **Three states:**
///
/// - `.hidden` — the surface must not display this event at all.
///   Silence is a valid coaching state.
/// - `.display(.advisory)` — show the event with verb-softened copy
///   ("appears to," "may have"), with the AR honesty-grammar hint that
///   the band thins / opacity drops.
/// - `.display(.primary)` — show the event with catalog copy verbatim,
///   at the renderer's primary thickness / opacity.
///
/// **AR-prep contract** (Phase D-S consumer): the spatial replay
/// renderer reads the same tier and applies the same `coefficient`
/// numeric so 2D `Canvas` and 3D `Mesh` surfaces share one honesty
/// grammar.
enum CoachingEventDisplayability: Equatable, Sendable {
    case hidden
    case display(Tier)

    enum Tier: String, Equatable, Sendable, Codable {
        case advisory
        case primary
    }

    /// Numeric thickness / opacity coefficient consumed by 2D and 3D
    /// renderers without forking the model layer. Pure projection of
    /// the case + tier; no flag, no env override.
    var coefficient: Double {
        switch self {
        case .hidden:                  return 0.0
        case .display(.advisory):      return 0.4
        case .display(.primary):       return 1.0
        }
    }

    /// `true` iff the renderer should draw something for this event.
    var isVisible: Bool {
        switch self {
        case .hidden:    return false
        case .display:   return true
        }
    }
}

// MARK: - CoachingEventDisplayabilityResolver

/// Pure, deterministic resolver from `(descriptor, paced, surfaceTier)`
/// to a `CoachingEventDisplayability`.
///
/// Inputs:
///
/// - `descriptor` — the catalog descriptor for the event's kind. The
///   resolver consults `descriptor.isResearchOnly` and hides the event
///   when it is `true`, so research-only kinds never reach the user.
/// - `passedPacer` — `true` when the event survived the
///   `CoachingEventPacer` pass; `false` means the pacer suppressed it
///   for spacing or same-kind reasons and the resolver must hide it.
/// - `surfaceTier` — the tier the adapter has computed for this event
///   (e.g., single drift occurrence → `.advisory`, repeated across a
///   phrase → `.primary`). The resolver echoes this back when the
///   other gates pass.
///
/// Same inputs → identical output across calls. No clock, no I/O, no
/// SwiftUI, no AVFoundation.
enum CoachingEventDisplayabilityResolver {

    struct Inputs: Equatable {
        let descriptor: CoachingEventDescriptor
        let passedPacer: Bool
        let surfaceTier: CoachingEventDisplayability.Tier

        init(
            descriptor: CoachingEventDescriptor,
            passedPacer: Bool,
            surfaceTier: CoachingEventDisplayability.Tier
        ) {
            self.descriptor = descriptor
            self.passedPacer = passedPacer
            self.surfaceTier = surfaceTier
        }
    }

    static func resolve(_ inputs: Inputs) -> CoachingEventDisplayability {
        guard inputs.passedPacer else { return .hidden }
        if inputs.descriptor.isResearchOnly { return .hidden }
        return .display(inputs.surfaceTier)
    }
}
