#if os(macOS)
import Foundation

// Scratch Playback Lab: pure recognition of whether the active MIDI source matches
// the controller the lab's mapping was built around (RANE ONE / ONE MKII).
//
// Scope guardrails (deliberate):
// - Pure value logic only. No Core MIDI, no AVFoundation, no device I/O, no Serato.
// - This NEVER touches mapper math, timeline capture, or any export. Its only job is
//   to decide whether to show the tester a "this mapping may be wrong" warning, so an
//   unsupported/unknown controller cannot silently produce garbage captured notation.
// - It is name-based on purpose: the verified RANE mapping (CC6 platter, CC8 crossfader,
//   measured steps/rev) is specific to that hardware, so any source that does not look
//   like a RANE ONE is treated as unverified rather than assumed-compatible.

/// Pure recognition of the verified Playback Lab controller, by MIDI source display name.
enum ControllerRecognition {
    /// Lowercased display-name fragment identifying the verified controller. "rane one"
    /// matches both "RANE ONE" and "RANE ONE MKII"; it is intentionally NOT just "rane"
    /// so an unrelated RANE mixer is not mistaken for the verified deck mapping.
    static let recognizedNameFragment = "rane one"

    /// Warning shown when the active source is not the verified controller.
    static let unverifiedWarning = "Unverified controller mapping — captured notation may be invalid."

    /// Whether a single source display name looks like the verified controller.
    static func isRecognized(sourceName: String) -> Bool {
        sourceName.lowercased().contains(recognizedNameFragment)
    }

    /// Whether the active selection is covered by the verified mapping:
    /// - A specific selected source is recognized iff its own name matches.
    /// - "All sources" (nil selection) is recognized iff a verified source is present
    ///   among those available (the RANE drives capture even if other gear is attached).
    /// - No sources at all is treated as recognized — nothing is connected to capture, so
    ///   there is no garbage to warn about and no false alarm on an empty lab.
    static func isRecognized(selectedSourceName: String?, availableSourceNames: [String]) -> Bool {
        if let selected = selectedSourceName {
            return isRecognized(sourceName: selected)
        }
        if availableSourceNames.isEmpty { return true }
        return availableSourceNames.contains { isRecognized(sourceName: $0) }
    }

    /// The warning string for the active selection, or nil when the selection is the
    /// verified controller (current behaviour, no warning).
    static func warning(selectedSourceName: String?, availableSourceNames: [String]) -> String? {
        isRecognized(selectedSourceName: selectedSourceName, availableSourceNames: availableSourceNames)
            ? nil
            : unverifiedWarning
    }
}

/// The controller profile the Scratch Playback Lab is currently treating as active.
/// Initially just the verified built-in profile or "Unverified" — there is no profile
/// editor and no MIDI learn yet. The unknown-controller warning is routed through this
/// state so there is one source of truth for "is the active mapping trustworthy".
enum ActiveControllerProfile: Equatable {
    /// A verified, built-in profile (currently only RANE ONE MKII).
    case builtIn(ControllerProfile)
    /// The active source does not match a verified profile; captured notation may be invalid.
    case unverified

    /// Name for the read-only "Controller profile: …" UI line.
    var displayName: String {
        switch self {
        case .builtIn(let profile): return profile.displayName
        case .unverified: return "Unverified"
        }
    }

    /// Whether the active profile is verified (current behaviour) versus unverified (warn).
    var isVerified: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The tester warning for an unverified active profile, or nil when verified. Routing
    /// the warning through here keeps it consistent with the displayed profile.
    var warning: String? {
        isVerified ? nil : ControllerRecognition.unverifiedWarning
    }

    /// Resolves the active profile purely from the live MIDI selection: a recognized
    /// RANE-like selection is the built-in RANE profile, anything else is unverified.
    /// Pure and side-effect free — it touches no timeline, capture, or export state.
    static func resolve(selectedSourceName: String?, availableSourceNames: [String]) -> ActiveControllerProfile {
        ControllerRecognition.isRecognized(
            selectedSourceName: selectedSourceName,
            availableSourceNames: availableSourceNames
        ) ? .builtIn(.raneOneMKII) : .unverified
    }
}

/// A bucketed summary of what was observed on a controller's expected controls, counted
/// against an active profile's platter / crossfader / pitch-bend bindings. Pure data.
struct ControllerSignalObservation: Equatable {
    /// Events seen on the profile's platter control (RANE ONE = CC6) — the capture driver.
    var platterEventCount: Int = 0
    /// Events seen on the profile's crossfader control (RANE ONE = CC8).
    var crossfaderEventCount: Int = 0
    /// Pitch-bend events seen (RANE ONE platter companion stream; diagnostic-only).
    var pitchBendEventCount: Int = 0

    init(platterEventCount: Int = 0, crossfaderEventCount: Int = 0, pitchBendEventCount: Int = 0) {
        self.platterEventCount = platterEventCount
        self.crossfaderEventCount = crossfaderEventCount
        self.pitchBendEventCount = pitchBendEventCount
    }

    /// Buckets a stream of parsed MIDI messages against a profile's expected bindings.
    /// Pure: a CC matching the platter binding counts as platter motion, a CC matching the
    /// crossfader binding counts as crossfader motion, and pitch-bend is counted separately
    /// (it is diagnostic-only and must not be mistaken for a capture-grade platter signal).
    static func observe(_ messages: [ParsedMIDIMessage], profile: ControllerProfile) -> ControllerSignalObservation {
        let platterCC = profile.deck.platter.ccNumber
        let crossfaderCC = profile.deck.crossfader.ccNumber
        var observation = ControllerSignalObservation()
        for message in messages {
            switch message.messageType {
            case .controlChange:
                if let cc = message.controlNumber {
                    if cc == platterCC { observation.platterEventCount += 1 }
                    else if cc == crossfaderCC { observation.crossfaderEventCount += 1 }
                }
            case .pitchBend:
                observation.pitchBendEventCount += 1
            default:
                break
            }
        }
        return observation
    }
}

/// Whether an observed mapping is safe enough to capture from.
enum ControllerMappingValidity: Int, Equatable, Comparable {
    /// Capture is trustworthy (verified profile, platter present).
    case valid = 0
    /// Capture can proceed but something is degraded or unverified — treat as experimental.
    case warning = 1
    /// Capture must not be trusted (no usable platter signal).
    case invalid = 2

    static func < (lhs: ControllerMappingValidity, rhs: ControllerMappingValidity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The result of validating a detected mapping: an overall verdict plus the human-readable
/// reasons behind it. Pure and deterministic.
struct ControllerMappingValidation: Equatable {
    let validity: ControllerMappingValidity
    let reasons: [String]

    /// Validates an observed mapping against the active profile. Pure and deterministic:
    /// the same inputs always yield the same verdict and reasons, and nothing is mutated.
    ///
    /// Rules (the verdict is the most severe that applies):
    /// - An unverified active profile is at least a warning (experimental capture).
    /// - No platter motion at all is invalid — capture needs a platter signal.
    /// - Pitch-bend-only platter motion is invalid — pitch bend is diagnostic-only and
    ///   cannot drive capture (CC6 is the ground-truth driver).
    /// - No crossfader motion is a warning — muted-section timing will be unavailable.
    static func validate(
        observation: ControllerSignalObservation,
        sourceName: String,
        activeProfile: ActiveControllerProfile
    ) -> ControllerMappingValidation {
        var validity = ControllerMappingValidity.valid
        var reasons: [String] = []

        if !activeProfile.isVerified {
            validity = max(validity, .warning)
            reasons.append("Controller \"\(sourceName)\" is not a verified profile — treat captured notation as experimental.")
        }

        if observation.platterEventCount == 0 {
            validity = max(validity, .invalid)
            if observation.pitchBendEventCount > 0 {
                reasons.append("Only pitch-bend platter motion was seen; pitch bend is diagnostic-only and cannot drive capture.")
            } else {
                reasons.append("No platter motion observed — a platter signal is required to capture.")
            }
        }

        if observation.crossfaderEventCount == 0 {
            validity = max(validity, .warning)
            reasons.append("No crossfader motion observed — crossfader-muted timing will be unavailable.")
        }

        return ControllerMappingValidation(validity: validity, reasons: reasons)
    }
}

/// A control binding inferred from an observed MIDI stream, with a 0...1 confidence and
/// the human-readable reasons behind it.
struct InferredControlCandidate: Equatable {
    let signal: ControllerControlSignal
    let confidence: Double
    let reasons: [String]
}

/// The platter and crossfader candidates inferred from an observed MIDI stream, plus any
/// overall notes (e.g. that pitch-bend motion was ignored for platter inference).
struct InferredMappingCandidates: Equatable {
    let platter: InferredControlCandidate?
    let crossfader: InferredControlCandidate?
    let notes: [String]
}

/// Pure inference of likely platter / crossfader bindings from an observed MIDI stream.
/// Model only — no UI, no persistence, and nothing here drives capture. It exists so a
/// tester on unsupported gear can be SHOWN a guess to confirm; it is never trusted blindly.
enum ControllerMappingInference {
    /// CC ring modulus used to detect ±1 platter steps (matches the RANE CC6 ring).
    static let ringModulus = 128
    /// Minimum value transitions on a CC before it is considered at all.
    static let minTransitions = 8
    /// Minimum ±1 ring steps for a CC to be platter-like.
    static let minPlatterRingSteps = 16
    /// Minimum fraction of transitions that must be ±1 ring steps for a platter candidate.
    static let platterRingStepRatio = 0.75
    /// Minimum fraction of the full 0...127 range a CC must sweep to be crossfader-like.
    static let crossfaderSweepFraction = 0.7

    private struct CCFeatures {
        let cc: Int
        let transitions: Int
        let ringStepOnes: Int
        let sweepFraction: Double
        var ringStepRatio: Double { transitions > 0 ? Double(ringStepOnes) / Double(transitions) : 0 }
    }

    /// Infers platter and crossfader candidates from a parsed MIDI stream.
    /// - A platter-like CC shows rapid ±1 ring changes (RANE CC6 fingerprint).
    /// - A crossfader-like CC sweeps broadly across 0...127.
    /// Pitch bend is never offered as a platter candidate — it is diagnostic-only — even
    /// when it is the only motion in the stream.
    static func infer(_ messages: [ParsedMIDIMessage]) -> InferredMappingCandidates {
        // Group CC values in arrival order; count pitch-bend events separately.
        var valuesByCC: [Int: [Int]] = [:]
        var pitchBendCount = 0
        for message in messages {
            switch message.messageType {
            case .controlChange:
                if let cc = message.controlNumber, let value = message.value {
                    valuesByCC[cc, default: []].append(value)
                }
            case .pitchBend:
                pitchBendCount += 1
            default:
                break
            }
        }

        let features = valuesByCC.map { cc, values -> CCFeatures in
            var ringStepOnes = 0
            for index in 1..<max(values.count, 1) where values.count > 1 {
                let step = ScratchPlatterPlayheadMapper.cc6Step(from: values[index - 1], to: values[index], modulus: ringModulus)
                if abs(step) == 1 { ringStepOnes += 1 }
            }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 0
            return CCFeatures(
                cc: cc,
                transitions: max(values.count - 1, 0),
                ringStepOnes: ringStepOnes,
                sweepFraction: Double(hi - lo) / 127.0
            )
        }

        var notes: [String] = []

        // Platter: the CC with the most ±1 ring steps, above the ratio/count thresholds.
        let platterFeature = features
            .filter { $0.transitions >= minTransitions && $0.ringStepOnes >= minPlatterRingSteps && $0.ringStepRatio >= platterRingStepRatio }
            .max { $0.ringStepOnes < $1.ringStepOnes }
        let platter = platterFeature.map { feature in
            InferredControlCandidate(
                signal: .controlChange(number: feature.cc),
                confidence: min(feature.ringStepRatio, 1.0),
                reasons: ["CC\(feature.cc): \(feature.ringStepOnes) ±1 ring steps (\(Int((feature.ringStepRatio * 100).rounded()))% of transitions) — platter-like."]
            )
        }

        // Crossfader: the non-platter CC with the broadest 0...127 sweep that is NOT itself
        // ±1-ring-dominated (so a platter is never mistaken for a fader).
        let crossfaderFeature = features
            .filter { $0.cc != platterFeature?.cc && $0.transitions >= minTransitions && $0.sweepFraction >= crossfaderSweepFraction && $0.ringStepRatio < platterRingStepRatio }
            .max { $0.sweepFraction < $1.sweepFraction }
        let crossfader = crossfaderFeature.map { feature in
            InferredControlCandidate(
                signal: .controlChange(number: feature.cc),
                confidence: min(feature.sweepFraction, 1.0),
                reasons: ["CC\(feature.cc): swept \(Int((feature.sweepFraction * 100).rounded()))% of the 0–127 range — crossfader-like."]
            )
        }

        if pitchBendCount > 0 {
            notes.append("Pitch-bend events seen but ignored for platter inference — pitch bend is diagnostic-only.")
        }
        if platter == nil {
            notes.append("No platter-like CC detected — capture needs a ±1 ring platter signal.")
        }

        return InferredMappingCandidates(platter: platter, crossfader: crossfader, notes: notes)
    }
}

/// One step of the guided mapping check. The flow walks a tester through moving each
/// control, then shows the inferred result for confirmation.
enum GuidedMappingStep: Equatable {
    case idle
    /// "Spin the platter forward and back."
    case spinPlatter
    /// "Move the crossfader fully open and closed."
    case moveCrossfader
    /// Inference has run; the tester reviews the guessed controls.
    case review(InferredMappingCandidates)
    /// The tester accepted the guess. Held in memory only — no persistence, no export.
    case confirmed(InferredMappingCandidates)
}

/// A pure state machine for the guided "verify your controller" flow. It collects MIDI
/// while the tester moves each control, infers candidate bindings, and lets them confirm.
/// EXPERIMENTAL mapping only: the result is held in memory and never drives capture,
/// persistence, or any export in this slice.
struct GuidedMappingSession: Equatable {
    private(set) var step: GuidedMappingStep = .idle
    /// MIDI collected across the platter and crossfader steps, fed to inference at review.
    private(set) var collected: [ParsedMIDIMessage] = []

    /// True while the flow is actively collecting controller motion.
    var isCollecting: Bool { step == .spinPlatter || step == .moveCrossfader }

    /// The inferred candidates once the flow reaches review/confirmed, else nil.
    var inferred: InferredMappingCandidates? {
        switch step {
        case .review(let candidates), .confirmed(let candidates): return candidates
        default: return nil
        }
    }

    /// The confirmed mapping (memory only), or nil until the tester confirms.
    var confirmedMapping: InferredMappingCandidates? {
        if case .confirmed(let candidates) = step { return candidates }
        return nil
    }

    /// Begins the flow at the first step, discarding any prior collection.
    mutating func start() {
        step = .spinPlatter
        collected = []
    }

    /// Records one parsed MIDI message — only while collecting (other steps ignore it).
    mutating func record(_ message: ParsedMIDIMessage) {
        guard isCollecting else { return }
        collected.append(message)
    }

    /// Advances to the next step. From the crossfader step this runs inference; from
    /// review it confirms. Idle starts the flow; confirmed is terminal.
    mutating func advance() {
        switch step {
        case .idle:
            start()
        case .spinPlatter:
            step = .moveCrossfader
        case .moveCrossfader:
            step = .review(ControllerMappingInference.infer(collected))
        case .review(let candidates):
            step = .confirmed(candidates)
        case .confirmed:
            break
        }
    }

    /// Cancels the flow and clears everything back to idle.
    mutating func cancel() {
        step = .idle
        collected = []
    }
}
#endif
