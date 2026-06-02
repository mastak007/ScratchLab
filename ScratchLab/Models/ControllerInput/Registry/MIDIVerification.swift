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

/// The pass/fail outcome of a single intended check, with an optional human detail. Pure
/// value model — constructed by a future live layer or directly in tests.
struct MIDIVerificationCheckOutcome: Codable, Equatable {
    let check: MIDIVerificationCheck
    let passed: Bool
    let detail: String?

    init(check: MIDIVerificationCheck, passed: Bool, detail: String? = nil) {
        self.check = check
        self.passed = passed
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

/// User-measured calibration values for a controller (all optional — only what was
/// actually measured is recorded). Does not itself drive playback in this slice.
struct MIDICalibration: Codable, Equatable {
    /// Measured platter ticks per physical revolution.
    var platterTicksPerRevolution: Int?
    /// Observed crossfader minimum raw value.
    var crossfaderMin: Int?
    /// Observed crossfader maximum raw value.
    var crossfaderMax: Int?
    /// Whether the user flagged platter direction as inverted.
    var inverted: Bool

    init(
        platterTicksPerRevolution: Int? = nil,
        crossfaderMin: Int? = nil,
        crossfaderMax: Int? = nil,
        inverted: Bool = false
    ) {
        self.platterTicksPerRevolution = platterTicksPerRevolution
        self.crossfaderMin = crossfaderMin
        self.crossfaderMax = crossfaderMax
        self.inverted = inverted
    }
}

/// A user's corrections layered over a base (built-in) profile, plus an optional verified
/// calibration stamp. The base profile is referenced by identifier and never mutated, so a
/// certified profile stays read-only while the user keeps their own overrides. Schema is
/// versioned and fails closed on decode.
struct MIDIUserOverrideProfile: Codable, Equatable {
    /// Schema version this build writes and accepts.
    static let currentSchemaVersion = 1

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
