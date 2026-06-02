import Foundation

// Pro-DJ MIDI registry layer (future-facing): the guided-verification plan/result models
// and the user override / calibration model.
//
// Scope guardrails (deliberate):
// - Pure value types + pure functions only. No Core MIDI, no audio, no playback, no UI.
// - Verification here is "confirm a KNOWN profile's specific bindings by asking the user
//   to move each control and counting matching MIDI events" — distinct from the existing
//   experimental discovery flow. It reuses the pure `ParsedMIDIMessage`/binding matcher
//   and never drives capture or playback in this slice.
// - The user override model lets a user correct/extend a base profile and record a
//   verified-calibration stamp WITHOUT overwriting the (read-only) base profile.

// MARK: - Verification checks

/// A first-class, intended pro-DJ verification check. These describe WHAT should be
/// confirmed about a control, independent of any live MIDI ingestion. Pure value model:
/// nothing here reads Core MIDI, audio, or playback — a future live layer computes the
/// outcomes; this slice only encodes the checks and their pass/fail results.
enum MIDIVerificationCheck: String, Codable, CaseIterable {
    /// Platter rotated forward produces forward motion.
    case platterForwardMotion
    /// Platter rotated backward produces backward motion.
    case platterBackwardMotion
    /// One full physical revolution measures a stable ticks-per-revolution.
    case platterFullRotationCalibration
    /// Platter motion is clean — no aliasing / spurious-direction noise.
    case platterNoAliasingNoise
    /// Crossfader reaches both extremes (min and max).
    case crossfaderMinMax
    /// Crossfader orientation is correct (not inverted), or inversion is detected.
    case crossfaderInversion
    /// Crossfader cut-in threshold (hard-cut point) is identified.
    case crossfaderCutThreshold
    /// Crossfader can perform quick cuts (rapid open/close transitions).
    case crossfaderQuickCuts

    var displayName: String {
        switch self {
        case .platterForwardMotion: return "Platter forward motion"
        case .platterBackwardMotion: return "Platter backward motion"
        case .platterFullRotationCalibration: return "One full rotation calibration"
        case .platterNoAliasingNoise: return "No aliasing / noise"
        case .crossfaderMinMax: return "Crossfader min / max"
        case .crossfaderInversion: return "Crossfader inversion"
        case .crossfaderCutThreshold: return "Crossfader cut threshold"
        case .crossfaderQuickCuts: return "Crossfader quick cuts"
        }
    }
}

// MARK: - Typed measured values

// Codex follow-up: measured verification/calibration values are TYPED here rather than
// carried as free-form `detail` strings. These are pure Codable value carriers — they
// store what was measured; deriving them from live MIDI is a later slice (this slice does
// not compute them and `MIDIVerificationResult.evaluate` leaves measurements nil).

/// Whether forward platter rotation actually read as forward motion.
enum MIDIPlatterDirectionResult: String, Codable, Equatable {
    /// Forward rotation read forward (correct).
    case correct
    /// Forward rotation read as reverse (inverted).
    case inverted
    /// Direction could not be determined from the measurement.
    case undetermined
}

/// Whether the crossfader's reported orientation matches its physical travel.
enum MIDICrossfaderOrientation: String, Codable, Equatable {
    /// Open/closed map the expected way.
    case normal
    /// Open/closed are reversed.
    case inverted
    /// Orientation could not be determined.
    case undetermined
}

/// A measured full-rotation calibration: steps counted over `sampleRevolutions` turns.
struct MIDIPlatterRotationMeasurement: Codable, Equatable {
    /// Measured platter ticks/steps per single physical revolution.
    var measuredStepsPerRevolution: Int
    /// How many revolutions the measurement was taken over (for averaging confidence).
    var sampleRevolutions: Int

    init(measuredStepsPerRevolution: Int, sampleRevolutions: Int = 1) {
        self.measuredStepsPerRevolution = measuredStepsPerRevolution
        self.sampleRevolutions = sampleRevolutions
    }

    /// True when the measurement is usable (positive steps over at least one revolution).
    var isValid: Bool { measuredStepsPerRevolution > 0 && sampleRevolutions > 0 }
}

/// Platter aliasing / noise metrics over a measured motion sample.
struct MIDIPlatterNoiseMetrics: Codable, Equatable {
    /// Total platter events seen during the sample.
    var totalEvents: Int
    /// Events whose per-event delta indicated aliasing / spurious direction.
    var aliasedEventCount: Int
    /// Largest per-event delta observed (in the control's native units).
    var maxPerEventDelta: Int

    init(totalEvents: Int, aliasedEventCount: Int, maxPerEventDelta: Int) {
        self.totalEvents = totalEvents
        self.aliasedEventCount = aliasedEventCount
        self.maxPerEventDelta = maxPerEventDelta
    }

    /// Fraction of events flagged as aliased (0 when no events were seen).
    var aliasFraction: Double {
        totalEvents > 0 ? Double(aliasedEventCount) / Double(totalEvents) : 0
    }
}

/// Measured raw crossfader travel extremes.
struct MIDICrossfaderRange: Codable, Equatable {
    /// Lowest raw value observed.
    var rawMin: Int
    /// Highest raw value observed.
    var rawMax: Int

    init(rawMin: Int, rawMax: Int) {
        self.rawMin = rawMin
        self.rawMax = rawMax
    }

    /// Raw span of the throw (clamped at 0 if min/max are crossed).
    var span: Int { max(0, rawMax - rawMin) }
    /// True when the range is well-formed (max strictly above min).
    var isValid: Bool { rawMax > rawMin }
}

/// Measured crossfader hard-cut threshold — where the cut engages along the throw.
struct MIDICrossfaderCutThreshold: Codable, Equatable {
    /// Position fraction (0...1 of throw) at which the hard cut engages.
    var positionFraction: Double
    /// Raw value at the cut point, when known.
    var rawValue: Int?

    init(positionFraction: Double, rawValue: Int? = nil) {
        self.positionFraction = positionFraction
        self.rawValue = rawValue
    }

    /// True when the cut fraction is within the unit interval.
    var isInUnitRange: Bool { positionFraction >= 0 && positionFraction <= 1 }
}

/// Quick-cut performance metrics over a measured burst of rapid open/close transitions.
struct MIDIQuickCutMetrics: Codable, Equatable {
    /// Number of distinct cuts counted.
    var cutCount: Int
    /// Fastest single open→close (or close→open) time in seconds, when measured.
    var fastestCutSeconds: Double?
    /// Median cut time in seconds, when measured.
    var medianCutSeconds: Double?

    init(cutCount: Int, fastestCutSeconds: Double? = nil, medianCutSeconds: Double? = nil) {
        self.cutCount = cutCount
        self.fastestCutSeconds = fastestCutSeconds
        self.medianCutSeconds = medianCutSeconds
    }
}

/// A typed measured value attached to a verification check outcome. Synthesized Codable
/// (same enum-with-associated-values pattern as `MIDIControlSignalType`).
enum MIDIVerificationMeasurement: Codable, Equatable {
    case platterDirection(MIDIPlatterDirectionResult)
    case platterRotation(MIDIPlatterRotationMeasurement)
    case platterNoise(MIDIPlatterNoiseMetrics)
    case crossfaderRange(MIDICrossfaderRange)
    case crossfaderOrientation(MIDICrossfaderOrientation)
    case crossfaderCutThreshold(MIDICrossfaderCutThreshold)
    case quickCut(MIDIQuickCutMetrics)
}

/// The pass/fail outcome of a single intended check. Measured values are carried in the
/// typed `measurement`; `detail` is for human-readable prose ONLY (never measured numbers).
/// Pure value model — constructed by a future live layer or directly in tests.
struct MIDIVerificationCheckOutcome: Codable, Equatable {
    let check: MIDIVerificationCheck
    let passed: Bool
    /// The typed measured value behind this outcome, when one was measured.
    let measurement: MIDIVerificationMeasurement?
    /// Optional human-readable prose only (e.g. a hint). NOT a place for measured values.
    let detail: String?

    init(
        check: MIDIVerificationCheck,
        passed: Bool,
        measurement: MIDIVerificationMeasurement? = nil,
        detail: String? = nil
    ) {
        self.check = check
        self.passed = passed
        self.measurement = measurement
        self.detail = detail
    }
}

// MARK: - Verification plan

/// One step of guided verification: exercise a single control, confirm liveness (matching
/// MIDI events arrived), and the intended pro-DJ checks for that control.
struct MIDIVerificationStep: Codable, Equatable {
    /// The binding being verified.
    let binding: MIDIControlBinding
    /// The instruction shown to the user.
    let instruction: String
    /// Minimum matching events required for the liveness gate (did we see the control?).
    let requiredEventCount: Int
    /// The intended pro-DJ checks for this control (forward/backward/calibration/…).
    let checks: [MIDIVerificationCheck]

    init(binding: MIDIControlBinding, instruction: String, requiredEventCount: Int, checks: [MIDIVerificationCheck] = []) {
        self.binding = binding
        self.instruction = instruction
        self.requiredEventCount = requiredEventCount
        self.checks = checks
    }

    /// The role under test (convenience).
    var role: MIDIControlRole { binding.role }
}

/// An ordered plan to verify a known profile's bindings. Built purely from a profile;
/// diagnostic-only bindings are skipped (the user is never asked to exercise them).
struct MIDIVerificationPlan: Codable, Equatable {
    /// Identifier of the profile this plan verifies.
    let profileIdentifier: String
    /// The steps, in profile binding order.
    let steps: [MIDIVerificationStep]

    /// Required event count for a role kind — relative platters need several ticks to be
    /// convincing; faders a couple; buttons/pads a single press.
    static func requiredEventCount(for kind: MIDIControlRole.Kind) -> Int {
        switch kind {
        case .platterMovement, .platterAbsolute, .needleStrip: return 4
        case .crossfader, .channelFader, .tempo: return 2
        case .button, .pad, .transport, .deckSelect, .unknown: return 1
        }
    }

    /// The intended pro-DJ checks for a role kind: platters get forward/backward/full-
    /// rotation/no-aliasing; crossfaders get min-max/inversion/cut-threshold/quick-cuts;
    /// other roles have no specialised checks yet (liveness only).
    static func defaultChecks(for kind: MIDIControlRole.Kind) -> [MIDIVerificationCheck] {
        switch kind {
        case .platterMovement, .platterAbsolute:
            return [.platterForwardMotion, .platterBackwardMotion,
                    .platterFullRotationCalibration, .platterNoAliasingNoise]
        case .crossfader:
            return [.crossfaderMinMax, .crossfaderInversion,
                    .crossfaderCutThreshold, .crossfaderQuickCuts]
        case .channelFader, .tempo, .needleStrip, .button, .pad,
             .transport, .deckSelect, .unknown:
            return []
        }
    }

    /// Builds a verification plan for a profile, one step per verifiable (non-diagnostic)
    /// binding, using each role's default instruction, liveness threshold, and checks.
    static func make(for profile: MIDIControllerProfile) -> MIDIVerificationPlan {
        let steps = profile.verifiableBindings.map { binding in
            MIDIVerificationStep(
                binding: binding,
                instruction: binding.role.defaultInstruction,
                requiredEventCount: requiredEventCount(for: binding.role.kind),
                checks: defaultChecks(for: binding.role.kind)
            )
        }
        return MIDIVerificationPlan(profileIdentifier: profile.identifier, steps: steps)
    }
}

// MARK: - Verification result

/// The outcome of verifying a single step: the liveness gate (did we see the control?)
/// plus the intended pro-DJ check outcomes.
struct MIDIVerificationStepResult: Codable, Equatable {
    /// The role that was tested.
    let role: MIDIControlRole
    /// The signal that was expected for this role.
    let expectedSignal: MIDIControlSignalType
    /// Matching events observed while the user exercised the control.
    let observedEventCount: Int
    /// Events that were required for the liveness gate.
    let requiredEventCount: Int
    /// Outcomes of the intended checks for this control (empty when none/not yet computed).
    let checkOutcomes: [MIDIVerificationCheckOutcome]

    init(
        role: MIDIControlRole,
        expectedSignal: MIDIControlSignalType,
        observedEventCount: Int,
        requiredEventCount: Int,
        checkOutcomes: [MIDIVerificationCheckOutcome] = []
    ) {
        self.role = role
        self.expectedSignal = expectedSignal
        self.observedEventCount = observedEventCount
        self.requiredEventCount = requiredEventCount
        self.checkOutcomes = checkOutcomes
    }

    /// Whether enough matching activity was seen (the control is live).
    var livenessPassed: Bool { observedEventCount >= requiredEventCount }
    /// Whether every intended check passed (vacuously true when none were computed).
    var checksPassed: Bool { checkOutcomes.allSatisfy(\.passed) }
    /// The step passes only when the control is live AND all its checks pass.
    var passed: Bool { livenessPassed && checksPassed }
}

/// The outcome of verifying a whole plan: per-step results plus derived summaries. Pure
/// and deterministic — identical inputs give identical results.
struct MIDIVerificationResult: Codable, Equatable {
    /// Identifier of the verified profile.
    let profileIdentifier: String
    /// Per-step results, in plan order.
    let stepResults: [MIDIVerificationStepResult]

    init(profileIdentifier: String, stepResults: [MIDIVerificationStepResult]) {
        self.profileIdentifier = profileIdentifier
        self.stepResults = stepResults
    }

    /// Whether every step passed (vacuously true for an empty plan).
    var allPassed: Bool { stepResults.allSatisfy(\.passed) }
    /// Number of steps that passed.
    var passedCount: Int { stepResults.filter(\.passed).count }
    /// Number of steps that failed.
    var failedCount: Int { stepResults.count - passedCount }
    /// Roles whose step failed.
    var failedRoles: [MIDIControlRole] { stepResults.filter { !$0.passed }.map(\.role) }

    /// A short human summary, e.g. "3/4 controls verified".
    var summary: String {
        "\(passedCount)/\(stepResults.count) controls verified"
    }

    /// All intended-check outcomes across every step.
    var allCheckOutcomes: [MIDIVerificationCheckOutcome] { stepResults.flatMap(\.checkOutcomes) }
    /// Number of intended checks that passed.
    var passedCheckCount: Int { allCheckOutcomes.filter(\.passed).count }
    /// The intended checks that failed.
    var failedChecks: [MIDIVerificationCheck] { allCheckOutcomes.filter { !$0.passed }.map(\.check) }
    /// A short human summary of intended checks, e.g. "6/8 checks passed".
    var checkSummary: String { "\(passedCheckCount)/\(allCheckOutcomes.count) checks passed" }

    /// Evaluates a plan's LIVENESS gate against a stream of parsed MIDI messages, counting
    /// matches per step. Pure: it inspects messages only and mutates nothing. This computes
    /// the "was the control seen?" gate; the intended pro-DJ check outcomes are NOT derived
    /// from a simple event count and are left empty here — a future live layer fills them.
    static func evaluate(plan: MIDIVerificationPlan, messages: [ParsedMIDIMessage]) -> MIDIVerificationResult {
        let results = plan.steps.map { step -> MIDIVerificationStepResult in
            let count = messages.filter { step.binding.matches($0) }.count
            return MIDIVerificationStepResult(
                role: step.role,
                expectedSignal: step.binding.signal,
                observedEventCount: count,
                requiredEventCount: step.requiredEventCount,
                checkOutcomes: []
            )
        }
        return MIDIVerificationResult(profileIdentifier: plan.profileIdentifier, stepResults: results)
    }
}

// MARK: - User override / calibration

/// User-measured calibration values for a controller, held as TYPED optional values — only
/// what was actually measured is recorded (a nil field means "not measured", distinct from
/// a measured zero/false). Does not itself drive playback in this slice.
struct MIDICalibration: Codable, Equatable {
    /// Measured full-rotation steps-per-revolution.
    var platterRotation: MIDIPlatterRotationMeasurement?
    /// Measured platter direction result (correct / inverted / undetermined).
    var platterDirection: MIDIPlatterDirectionResult?
    /// Measured platter aliasing / noise metrics.
    var platterNoise: MIDIPlatterNoiseMetrics?
    /// Measured crossfader raw min/max range.
    var crossfaderRange: MIDICrossfaderRange?
    /// Measured crossfader orientation (normal / inverted / undetermined).
    var crossfaderOrientation: MIDICrossfaderOrientation?
    /// Measured crossfader hard-cut threshold.
    var crossfaderCutThreshold: MIDICrossfaderCutThreshold?
    /// Measured quick-cut metrics.
    var quickCut: MIDIQuickCutMetrics?

    init(
        platterRotation: MIDIPlatterRotationMeasurement? = nil,
        platterDirection: MIDIPlatterDirectionResult? = nil,
        platterNoise: MIDIPlatterNoiseMetrics? = nil,
        crossfaderRange: MIDICrossfaderRange? = nil,
        crossfaderOrientation: MIDICrossfaderOrientation? = nil,
        crossfaderCutThreshold: MIDICrossfaderCutThreshold? = nil,
        quickCut: MIDIQuickCutMetrics? = nil
    ) {
        self.platterRotation = platterRotation
        self.platterDirection = platterDirection
        self.platterNoise = platterNoise
        self.crossfaderRange = crossfaderRange
        self.crossfaderOrientation = crossfaderOrientation
        self.crossfaderCutThreshold = crossfaderCutThreshold
        self.quickCut = quickCut
    }

    /// True when no field has been measured yet.
    var isEmpty: Bool {
        platterRotation == nil && platterDirection == nil && platterNoise == nil
            && crossfaderRange == nil && crossfaderOrientation == nil
            && crossfaderCutThreshold == nil && quickCut == nil
    }
}

/// A user's corrections layered over a base (built-in) profile, plus an optional verified
/// calibration stamp. The base profile is referenced by identifier and never mutated, so a
/// certified profile stays read-only while the user keeps their own overrides. Schema is
/// versioned and fails closed on decode.
struct MIDIUserOverrideProfile: Codable, Equatable {
    /// Schema version this build writes and accepts. Bumped 1 → 2 when `MIDICalibration`
    /// was restructured to hold typed measured values (no persisted v1 data exists, and
    /// decoding fails closed on any unsupported version).
    static let currentSchemaVersion = 2

    /// Schema version of this instance (fails closed on decode if unsupported).
    let schemaVersion: Int
    /// Identifier of the base profile these overrides apply to.
    let baseProfileIdentifier: String
    /// The device identity these overrides were captured against, if recorded.
    let deviceIdentity: MIDIDeviceIdentity?
    /// Bindings the user added or replaced (by role).
    var bindingOverrides: [MIDIControlBinding]
    /// Measured calibration, if any.
    var calibration: MIDICalibration?
    /// When the user last verified this calibration, if ever.
    var verifiedAt: Date?

    init(
        schemaVersion: Int = MIDIUserOverrideProfile.currentSchemaVersion,
        baseProfileIdentifier: String,
        deviceIdentity: MIDIDeviceIdentity? = nil,
        bindingOverrides: [MIDIControlBinding] = [],
        calibration: MIDICalibration? = nil,
        verifiedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.baseProfileIdentifier = baseProfileIdentifier
        self.deviceIdentity = deviceIdentity
        self.bindingOverrides = bindingOverrides
        self.calibration = calibration
        self.verifiedAt = verifiedAt
    }

    /// Whether a verified-calibration stamp is present.
    var isVerified: Bool { verifiedAt != nil }

    /// Decodes an override, failing closed on an unsupported schema version.
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> MIDIUserOverrideProfile {
        let override = try decoder.decode(MIDIUserOverrideProfile.self, from: data)
        guard override.schemaVersion == currentSchemaVersion else {
            throw MIDIControllerProfileError.unsupportedSchemaVersion(override.schemaVersion)
        }
        return override
    }

    /// Applies the user's binding overrides onto a base profile, replacing any base binding
    /// that shares a role (kind + deck) and appending genuinely new ones. Pure: returns a
    /// new profile and never mutates the base. The result keeps the base profile's identity
    /// but is downgraded to `.community` confidence, since it now carries user edits.
    func applied(to base: MIDIControllerProfile) -> MIDIControllerProfile {
        var merged = base.bindings
        for override in bindingOverrides {
            if let index = merged.firstIndex(where: {
                $0.role.kind == override.role.kind && $0.role.deck == override.role.deck
            }) {
                merged[index] = override
            } else {
                merged.append(override)
            }
        }
        return MIDIControllerProfile(
            identifier: base.identifier,
            displayName: base.displayName,
            manufacturer: base.manufacturer,
            model: base.model,
            confidence: bindingOverrides.isEmpty ? base.confidence : .community,
            matching: base.matching,
            deckCount: base.deckCount,
            bindings: merged,
            notes: base.notes
        )
    }
}

// MARK: - Requirements / readiness bridge

// The policy layer that connects a known profile + its verification result to a usability
// verdict. Pure value model on top of the existing `MIDIVerificationPlan` — it adds the
// notions the plan does not carry: which checks are REQUIRED vs optional, which FAILURES
// block use, which checks PRODUCE a typed calibration value, and which confidence tiers
// must be verified before use. Nothing here ingests live MIDI, drives playback, or mutates
// the existing plan/result/evaluate behaviour.

/// Which typed `MIDICalibration` field a verification check can populate. Pure naming layer
/// so a check outcome can be routed to the right calibration slot by a future live layer.
enum MIDICalibrationField: String, Codable, CaseIterable, Equatable {
    case platterDirection
    case platterRotation
    case platterNoise
    case crossfaderRange
    case crossfaderOrientation
    case crossfaderCutThreshold
    case quickCut
}

extension MIDIVerificationCheck {
    /// The typed calibration field this check can produce when measured, or nil. Forward /
    /// backward platter motion both establish platter DIRECTION; the remaining checks map
    /// one-to-one onto their measurement's calibration slot.
    var calibrationField: MIDICalibrationField? {
        switch self {
        case .platterForwardMotion, .platterBackwardMotion: return .platterDirection
        case .platterFullRotationCalibration: return .platterRotation
        case .platterNoAliasingNoise: return .platterNoise
        case .crossfaderMinMax: return .crossfaderRange
        case .crossfaderInversion: return .crossfaderOrientation
        case .crossfaderCutThreshold: return .crossfaderCutThreshold
        case .crossfaderQuickCuts: return .quickCut
        }
    }
}

/// One check's requirement policy: whether it must pass for full readiness, whether failing
/// it blocks use, and which calibration field it produces. Pure Codable value.
struct MIDIVerificationRequirement: Codable, Equatable {
    /// The check this requirement governs.
    let check: MIDIVerificationCheck
    /// Whether the check must be present and passing for the device to be fully ready.
    let isRequired: Bool
    /// Whether FAILING the check makes the device unusable (a `.blocked` verdict).
    let blocksUseOnFailure: Bool
    /// The typed calibration field this check can produce, if any.
    let producesCalibration: MIDICalibrationField?

    init(check: MIDIVerificationCheck, isRequired: Bool, blocksUseOnFailure: Bool, producesCalibration: MIDICalibrationField?) {
        self.check = check
        self.isRequired = isRequired
        self.blocksUseOnFailure = blocksUseOnFailure
        self.producesCalibration = producesCalibration
    }

    /// Checks modelled as optional/non-blocking refinements rather than correctness gates.
    /// Quick cuts is a PERFORMANCE measurement (how fast the fader can cut) — useful to record
    /// but not something whose failure should block basic, correct use of the controller.
    private static let optionalChecks: Set<MIDIVerificationCheck> = [.crossfaderQuickCuts]

    /// The standard requirement for a check: required + blocking for correctness gates
    /// (platter motion/calibration/noise, crossfader range/inversion/cut), optional +
    /// non-blocking for refinements (`optionalChecks`). Calibration field comes from the check.
    static func standard(for check: MIDIVerificationCheck) -> MIDIVerificationRequirement {
        let required = !optionalChecks.contains(check)
        return MIDIVerificationRequirement(
            check: check,
            isRequired: required,
            blocksUseOnFailure: required,
            producesCalibration: check.calibrationField
        )
    }
}

/// The full set of requirements derived from a profile, plus the profile's confidence tier.
/// Built on `MIDIVerificationPlan.make(for:)` so the per-role check set stays the single
/// source of truth (this layer adds policy, it does not re-enumerate which checks a role has).
struct MIDIVerificationRequirementSet: Codable, Equatable {
    /// Identifier of the profile these requirements were derived from.
    let profileIdentifier: String
    /// The profile's certification / confidence tier (drives the verify-before-use gate).
    let confidence: MIDIProfileConfidence
    /// The per-check requirements, in plan/check order, de-duplicated across steps.
    let requirements: [MIDIVerificationRequirement]

    init(profileIdentifier: String, confidence: MIDIProfileConfidence, requirements: [MIDIVerificationRequirement]) {
        self.profileIdentifier = profileIdentifier
        self.confidence = confidence
        self.requirements = requirements
    }

    /// Derives requirements from a profile. Reuses the plan factory's checks (so a deckless
    /// mixer yields only crossfader checks, a platter-only deck yields only platter checks),
    /// de-duplicating checks that recur across steps (e.g. both platter decks share the same
    /// four platter checks → one requirement each).
    static func make(for profile: MIDIControllerProfile) -> MIDIVerificationRequirementSet {
        let plan = MIDIVerificationPlan.make(for: profile)
        var seen = Set<MIDIVerificationCheck>()
        var requirements: [MIDIVerificationRequirement] = []
        for step in plan.steps {
            for check in step.checks where !seen.contains(check) {
                seen.insert(check)
                requirements.append(.standard(for: check))
            }
        }
        return MIDIVerificationRequirementSet(
            profileIdentifier: profile.identifier,
            confidence: profile.confidence,
            requirements: requirements
        )
    }

    /// Checks that must pass for full readiness.
    var requiredChecks: [MIDIVerificationCheck] { requirements.filter(\.isRequired).map(\.check) }
    /// Checks that are optional (their failure never blocks).
    var optionalChecks: [MIDIVerificationCheck] { requirements.filter { !$0.isRequired }.map(\.check) }
    /// Checks whose failure blocks use.
    var blockingChecks: [MIDIVerificationCheck] { requirements.filter(\.blocksUseOnFailure).map(\.check) }
    /// Calibration fields the profile's checks can produce (per check; may repeat a field).
    var producibleCalibrationFields: [MIDICalibrationField] { requirements.compactMap(\.producesCalibration) }

    /// The requirement governing a given check, if the profile has it.
    func requirement(for check: MIDIVerificationCheck) -> MIDIVerificationRequirement? {
        requirements.first { $0.check == check }
    }

    /// Whether the profile's confidence tier mandates verification before use. `.heuristic`
    /// (inferred) and `.unverified` (no match) must always be verified; certified/community
    /// profiles are trusted unless a required check actually fails.
    var confidenceRequiresVerification: Bool {
        confidence <= MIDIProfileConfidence.heuristic
    }
}

/// The top-level usability verdict for a device under a profile.
enum MIDIVerificationReadinessVerdict: String, Codable, Equatable {
    /// All required checks present and passing, and the profile is trusted — safe to use.
    case ready
    /// Nothing is blocking, but the device must be verified first (low-confidence profile
    /// and/or a required check has not been exercised yet).
    case verificationRequired
    /// A required, use-blocking check failed — the device must not be used as mapped.
    case blocked
}

/// The readiness assessment of a verification result against a profile's requirements. Pure
/// and deterministic; carries enough detail to explain the verdict (blocking failures,
/// not-yet-exercised required checks, non-blocking failures, and the confidence reason).
struct MIDIVerificationReadiness: Codable, Equatable {
    /// The overall verdict.
    let verdict: MIDIVerificationReadinessVerdict
    /// Required, use-blocking checks that FAILED (the reason for `.blocked`).
    let blockingFailures: [MIDIVerificationCheck]
    /// Required checks with no outcome yet (not exercised) — contribute to `.verificationRequired`.
    let missingRequiredChecks: [MIDIVerificationCheck]
    /// Optional / non-blocking checks that failed (informational only; never block).
    let failedOptionalChecks: [MIDIVerificationCheck]
    /// Whether the profile's confidence tier alone mandates verification.
    let confidenceRequiresVerification: Bool
    /// The profile confidence the verdict was computed against.
    let confidence: MIDIProfileConfidence

    init(
        verdict: MIDIVerificationReadinessVerdict,
        blockingFailures: [MIDIVerificationCheck],
        missingRequiredChecks: [MIDIVerificationCheck],
        failedOptionalChecks: [MIDIVerificationCheck],
        confidenceRequiresVerification: Bool,
        confidence: MIDIProfileConfidence
    ) {
        self.verdict = verdict
        self.blockingFailures = blockingFailures
        self.missingRequiredChecks = missingRequiredChecks
        self.failedOptionalChecks = failedOptionalChecks
        self.confidenceRequiresVerification = confidenceRequiresVerification
        self.confidence = confidence
    }

    /// Convenience: whether the device is ready to use as mapped.
    var isReady: Bool { verdict == .ready }

    /// Computes readiness from a requirement set and a verification result. Pure: it inspects
    /// the result's check outcomes only and mutates nothing.
    ///
    /// Precedence (most severe wins):
    /// - Any required, use-blocking check that FAILED → `.blocked` (even on a trusted profile).
    /// - Else if confidence mandates verification, OR a required check was never exercised →
    ///   `.verificationRequired`.
    /// - Else → `.ready`.
    ///
    /// Optional checks never block and never force verification; a failed optional check is
    /// reported for information only.
    static func evaluate(
        requirements: MIDIVerificationRequirementSet,
        result: MIDIVerificationResult
    ) -> MIDIVerificationReadiness {
        let outcomes = result.allCheckOutcomes
        let failedChecks = Set(outcomes.filter { !$0.passed }.map(\.check))
        let presentChecks = Set(outcomes.map(\.check))

        var blockingFailures: [MIDIVerificationCheck] = []
        var missingRequired: [MIDIVerificationCheck] = []
        var failedOptional: [MIDIVerificationCheck] = []

        for requirement in requirements.requirements {
            let didFail = failedChecks.contains(requirement.check)
            let isPresent = presentChecks.contains(requirement.check)
            if didFail {
                if requirement.blocksUseOnFailure {
                    blockingFailures.append(requirement.check)
                } else {
                    failedOptional.append(requirement.check)
                }
            }
            if requirement.isRequired && !isPresent {
                missingRequired.append(requirement.check)
            }
        }

        let confidenceGate = requirements.confidenceRequiresVerification
        let verdict: MIDIVerificationReadinessVerdict
        if !blockingFailures.isEmpty {
            verdict = .blocked
        } else if confidenceGate || !missingRequired.isEmpty {
            verdict = .verificationRequired
        } else {
            verdict = .ready
        }

        return MIDIVerificationReadiness(
            verdict: verdict,
            blockingFailures: blockingFailures,
            missingRequiredChecks: missingRequired,
            failedOptionalChecks: failedOptional,
            confidenceRequiresVerification: confidenceGate,
            confidence: requirements.confidence
        )
    }
}
