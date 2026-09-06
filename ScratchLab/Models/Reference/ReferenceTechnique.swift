// ReferenceTechnique — which techniques CXL may author a reference for, and
// what fader behaviour each one is EXPECTED to show.
//
// Two rules govern everything in this file.
//
// 1. No technique semantics are invented from a display name. A technique's
//    identity is `CaptureSessionScratchType`, the vocabulary the rest of the
//    app already uses. Flare is never "flare": it is `flare1Click`,
//    `flare2Click` or `flare3Click`, because the click count IS the technique,
//    and a generic label would let a 2-click take be filed as a 1-click
//    reference.
//
// 2. The fader expectations below are CONFIGURATION, not canon. They say what
//    evidence a take must contain to be plausible — "a transform must show
//    repeated cuts" — which is a checkable property of the recorded stream.
//    They do NOT define the gesture. `ScratchNotation.canonicalBeatPattern`
//    remains the only source of authored target semantics, and it still has
//    exactly one entry. A reference is only ever promoted by explicit operator
//    approval; nothing here promotes anything on its own.
//
// Foundation only. Pure value types.

import Foundation

// MARK: - Flare click count

/// The click count of a flare, as a first-class value.
///
/// A flare reference cannot be constructed without one: `ReferenceTechnique`
/// carries this as a non-optional associated value, so "a flare" is not a
/// representable state at the type level.
enum FlareClickCount: Int, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case oneClick = 1
    case twoClick = 2
    case threeClick = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneClick: return "1-Click Flare"
        case .twoClick: return "2-Click Flare"
        case .threeClick: return "3-Click Flare"
        }
    }

    var scratchType: CaptureSessionScratchType {
        switch self {
        case .oneClick: return .flare1Click
        case .twoClick: return .flare2Click
        case .threeClick: return .flare3Click
        }
    }

    /// Cut-family fader events one repetition of this flare must contain, at
    /// minimum. A click IS a cut, so the count is the click count.
    var minimumCutEventsPerRepetition: Int { rawValue }

    init?(scratchType: CaptureSessionScratchType) {
        switch scratchType {
        case .flare1Click: self = .oneClick
        case .flare2Click: self = .twoClick
        case .flare3Click: self = .threeClick
        default: return nil
        }
    }
}

// MARK: - Technique

/// A technique a reference performance may be authored for.
enum ReferenceTechnique: Codable, Equatable, Sendable, Hashable, Identifiable {
    case babyScratch
    /// A plain tear: same-direction travel interrupted by bounded stationary
    /// holds, performed with the fader parked open. The hold count is derived
    /// from the PLATTER stream (`ScratchNotation.GestureRecord.tearLabel`), so
    /// unlike flare this technique needs no click count in its identity.
    case tear
    case chirp
    case transform
    case flare(FlareClickCount)

    var id: String { scratchType.rawValue }

    var scratchType: CaptureSessionScratchType {
        switch self {
        case .babyScratch: return .babyScratch
        case .tear: return .tear
        case .chirp: return .chirp
        case .transform: return .transform
        case .flare(let clicks): return clicks.scratchType
        }
    }

    var displayName: String { scratchType.title }

    /// The minimum required set named in the authoring brief, in teaching
    /// order. Flare appears once per click count because they are distinct
    /// techniques, not one technique with a parameter.
    ///
    /// Deliberately UNCHANGED by the addition of `.tear`. This list is also
    /// what `ReferenceRegistry` reads as `trainingEnabledTechniques`, so
    /// adding a technique here would widen training eligibility as a side
    /// effect of making it authorable. Authorability and training eligibility
    /// are separate decisions; see `authorableSet`.
    static let minimumRequiredSet: [ReferenceTechnique] = [
        .babyScratch,
        .chirp,
        .transform,
        .flare(.oneClick),
        .flare(.twoClick),
        .flare(.threeClick)
    ]

    /// Every technique CXL may author a reference take for, in teaching order.
    ///
    /// This is the authoring picker's source. It is a superset of
    /// `minimumRequiredSet` and confers nothing beyond the ability to RECORD a
    /// draft: no entry here is published, installed, registered, or training
    /// eligible by virtue of appearing in it.
    static let authorableSet: [ReferenceTechnique] = [
        .babyScratch,
        .tear,
        .chirp,
        .transform,
        .flare(.oneClick),
        .flare(.twoClick),
        .flare(.threeClick)
    ]

    /// Recover a technique from a persisted scratch-type token.
    ///
    /// Returns `nil` for every type outside the authorable set, including a
    /// bare `"flare"` token — an ambiguous flare label is rejected rather than
    /// defaulted to 1-click.
    init?(scratchType: CaptureSessionScratchType) {
        switch scratchType {
        case .babyScratch: self = .babyScratch
        case .tear: self = .tear
        case .chirp: self = .chirp
        case .transform: self = .transform
        case .flare1Click: self = .flare(.oneClick)
        case .flare2Click: self = .flare(.twoClick)
        case .flare3Click: self = .flare(.threeClick)
        default: return nil
        }
    }

    init?(scratchTypeID: String) {
        let trimmed = scratchTypeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let type = CaptureSessionScratchType(rawValue: trimmed) else { return nil }
        self.init(scratchType: type)
    }
}

// MARK: - Fader expectation

/// Where a technique requirement came from, and therefore how much authority
/// it has.
///
/// ScratchLab does not know what a correct chirp looks like. It has never been
/// shown one: every take recorded so far is a test capture, not reference
/// material. So a requirement it ships with is a PROPOSAL — surfaced to the
/// operator in review, never a reason to fail a take on its own. Only after
/// CXL confirms the requirement for a technique does a violation of it block
/// approval.
enum ReferenceRequirementSource: Codable, Equatable, Sendable {
    /// Shipped default. Advisory only.
    case provisionalDefault
    /// Confirmed for this technique by a named operator.
    case operatorConfirmed(by: String, at: Date)

    var isOperatorConfirmed: Bool {
        if case .operatorConfirmed = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .provisionalDefault:
            return "Provisional (advisory only)"
        case .operatorConfirmed(let by, _):
            return "Confirmed by \(by)"
        }
    }
}

/// What the crossfader must be doing for a take of this technique to be
/// plausible evidence.
///
/// Every field is a checkable property of the RECORDED stream. None of them
/// describes hand mechanics, and none is derived from a recorded take — no
/// recorded take is valid reference material yet, so tuning these to one would
/// encode a mistake as the definition of the technique.
///
/// `source` decides whether a violation blocks approval or merely informs it.
/// Shipped values are `.provisionalDefault`.
struct ReferenceFaderExpectation: Equatable, Sendable, Codable {

    /// Whether the deck must stay in its calibrated open zone for the whole
    /// phrase. True only for techniques performed with the fader open.
    let requiresContinuouslyOpenFader: Bool
    /// Minimum cut-family events (cut / pulse / transformPulse) required per
    /// repetition. `0` means the technique does not require fader activity.
    let minimumCutEventsPerRepetition: Int
    /// Maximum share of derived fader events this build may leave `unknown`
    /// and still allow publication.
    let maximumUnknownEventRatio: Double
    /// Whether platter movement evidence is required.
    let requiresPlatterMotion: Bool
    /// Always true: no reference is canonical without an explicit human
    /// decision, whatever the automated checks say.
    let requiresOperatorApproval: Bool
    /// Whether the TECHNIQUE-SHAPE fields above (open-throughout, cut counts)
    /// carry enough authority to fail a take. Capture-integrity checks are
    /// unaffected — those never depend on knowing the technique.
    let source: ReferenceRequirementSource

    init(
        requiresContinuouslyOpenFader: Bool,
        minimumCutEventsPerRepetition: Int,
        maximumUnknownEventRatio: Double,
        requiresPlatterMotion: Bool = true,
        requiresOperatorApproval: Bool = true,
        source: ReferenceRequirementSource = .provisionalDefault
    ) {
        self.requiresContinuouslyOpenFader = requiresContinuouslyOpenFader
        self.minimumCutEventsPerRepetition = minimumCutEventsPerRepetition
        self.maximumUnknownEventRatio = maximumUnknownEventRatio
        self.requiresPlatterMotion = requiresPlatterMotion
        self.requiresOperatorApproval = requiresOperatorApproval
        self.source = source
    }

    /// The same expectation, confirmed by an operator. Only then do its
    /// technique-shape fields block approval.
    func confirmed(by operatorName: String, at date: Date) -> ReferenceFaderExpectation {
        ReferenceFaderExpectation(
            requiresContinuouslyOpenFader: requiresContinuouslyOpenFader,
            minimumCutEventsPerRepetition: minimumCutEventsPerRepetition,
            maximumUnknownEventRatio: maximumUnknownEventRatio,
            requiresPlatterMotion: requiresPlatterMotion,
            requiresOperatorApproval: requiresOperatorApproval,
            source: .operatorConfirmed(by: operatorName, at: date)
        )
    }
}

extension ReferenceTechnique {

    /// The PROVISIONAL expectation for this technique.
    ///
    /// Two different kinds of number live here, and they are governed
    /// differently:
    ///
    /// - `maximumUnknownEventRatio` is a CAPTURE-INTEGRITY threshold. It asks
    ///   "could ScratchLab read this fader stream?", which is answerable
    ///   without knowing what the technique is, so it blocks approval on its
    ///   own. 0.10 is a deliberately strict engineering choice, not a
    ///   measurement.
    /// - `requiresContinuouslyOpenFader` and `minimumCutEventsPerRepetition`
    ///   are TECHNIQUE-SHAPE claims. ScratchLab has never been shown a correct
    ///   chirp, transform or flare, so these ship as `.provisionalDefault` and
    ///   are advisory until CXL confirms them. They exist to give the operator
    ///   something concrete to agree or disagree with in review, not to
    ///   adjudicate technique.
    var defaultFaderExpectation: ReferenceFaderExpectation {
        switch self {
        case .babyScratch:
            return ReferenceFaderExpectation(
                requiresContinuouslyOpenFader: true,
                minimumCutEventsPerRepetition: 0,
                maximumUnknownEventRatio: 0.0
            )
        case .tear:
            // A plain tear is performed with the fader PARKED OPEN: its
            // subdivisions are made by stopping the PLATTER, not by cutting.
            // So it owes the same evidence a Baby Scratch owes — proof the
            // fader was open — and requires no cut events at all. Counting
            // fader clicks as tear holds is explicitly forbidden by
            // `ScratchNotation.GestureRecord`, and nothing here does it.
            return ReferenceFaderExpectation(
                requiresContinuouslyOpenFader: true,
                minimumCutEventsPerRepetition: 0,
                maximumUnknownEventRatio: 0.0
            )
        case .chirp:
            // A chirp is defined by coordinated fader transitions. How many,
            // and of what shape, is NOT asserted here beyond "at least one per
            // repetition", and even that is advisory until confirmed.
            return ReferenceFaderExpectation(
                requiresContinuouslyOpenFader: false,
                minimumCutEventsPerRepetition: 1,
                maximumUnknownEventRatio: 0.10
            )
        case .transform:
            // A transform is repeated cuts against sustained platter motion.
            // Two per repetition is the weakest claim that still distinguishes
            // it from a single-cut take; advisory until confirmed.
            return ReferenceFaderExpectation(
                requiresContinuouslyOpenFader: false,
                minimumCutEventsPerRepetition: 2,
                maximumUnknownEventRatio: 0.10
            )
        case .flare(let clicks):
            return ReferenceFaderExpectation(
                requiresContinuouslyOpenFader: false,
                minimumCutEventsPerRepetition: clicks.minimumCutEventsPerRepetition,
                maximumUnknownEventRatio: 0.10
            )
        }
    }

    /// `true` when the technique cannot be evidenced without a calibrated
    /// crossfader. Calibration is mandatory before recording any of these.
    var requiresCalibratedCrossfader: Bool { true }

    /// Whether an authored canonical target pattern exists for this technique
    /// today.
    ///
    /// Reads the existing canonical registry rather than asserting anything of
    /// its own, so this stays true to `ScratchNotation.canonicalBeatPatterns`
    /// as that list grows. Performance comparison is gated on this being
    /// `true`; a reference may be RECORDED and PLAYED for every technique, but
    /// scored only where verified target semantics exist.
    var hasVerifiedTargetSemantics: Bool {
        ScratchNotation.canonicalBeatPattern(forScratchID: scratchType.rawValue) != nil
    }
}
