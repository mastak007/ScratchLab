// ReferenceTake — the metadata and lifecycle of one authored reference
// performance, and the beat-aligned phrase boundaries inside it.
//
// Take structure, fixed by the authoring brief:
//
//     | count-in bar | rep 1 | rep 2 | rep 3 | rep 4 | tail bar |
//
// One take = ONE technique, ONE rhythmic pattern, ONE BPM. A different
// pattern, BPM or technique is a different take. No silence is baked in for
// the learner's turn — the response window is inserted at playback time by
// `CallAndResponseSchedule`, so the same recording serves any response length.
//
// Lifecycle is strictly one-directional and human-gated:
//
//     draft -> reviewed -> approvedCanonical -> published
//
// with `diagnostic`, `rejected` and `deprecated` as off-ramps that never lead
// back. A raw capture is never canonical, and no step happens automatically.
//
// Foundation only. Pure value types, shared by iOS and macOS.

import Foundation

// MARK: - Lifecycle

/// The state of a captured take.
///
/// Seven states, kept deliberately distinct because conflating any two of them is
/// how bad data becomes canonical:
///
///   diagnostic         A capture kept ONLY to investigate a capture, export,
///                      MIDI or validation failure. Never promotable, never
///                      playable, never a technique example. A one-way state.
///   draft              A recorded reference take awaiting review.
///   reviewed           An operator has auditioned the repetitions and chosen
///                      one, but has not signed it off.
///   approvedCanonical  An operator has explicitly signed the take off as a
///                      correct example of the technique.
///   published          A build has installed the approved package into
///                      bundled reference resources. The ONLY state a learner
///                      may be served.
///   deprecated         Withdrawn from service. Files retained; never served.
///   rejected           An operator refused the take. Files retained as
///                      diagnostics; never promotable.
///
/// The only path to `published` runs through an explicit human approval. There
/// is no automatic promotion at any step, and no state machine shortcut.
enum ReferenceLifecycleState: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case diagnostic
    case draft
    case reviewed
    case approvedCanonical = "approved_canonical"
    case published
    case deprecated
    case rejected

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .diagnostic: return "Diagnostic capture"
        case .draft: return "Draft reference"
        case .reviewed: return "Reviewed reference"
        case .approvedCanonical: return "Approved canonical"
        case .published: return "Published"
        case .deprecated: return "Deprecated"
        case .rejected: return "Rejected"
        }
    }

    /// States this state may move to. Everything else is refused.
    ///
    /// `diagnostic` and `rejected` are terminal on purpose: a take that was
    /// captured to investigate a bug, or that an operator refused, cannot be
    /// talked back into the canonical path later. Re-record instead.
    var permittedNextStates: [ReferenceLifecycleState] {
        switch self {
        case .diagnostic:
            return []
        case .draft:
            return [.reviewed, .rejected]
        case .reviewed:
            return [.approvedCanonical, .rejected]
        case .approvedCanonical:
            return [.published, .deprecated, .rejected]
        case .published:
            return [.deprecated]
        case .deprecated:
            return []
        case .rejected:
            return []
        }
    }

    func canAdvance(to next: ReferenceLifecycleState) -> Bool {
        permittedNextStates.contains(next)
    }

    /// The ONLY state a learner may be served.
    ///
    /// Approval alone is not enough: step 11 of the authoring workflow makes a
    /// reference available to training only after it has been published into
    /// bundled resources, so an approved-but-not-yet-installed package is not
    /// playable either.
    var isPlayableByLearner: Bool { self == .published }

    /// `true` for a take that exists only as evidence about a defect.
    var isDiagnosticOnly: Bool { self == .diagnostic || self == .rejected }
}

// MARK: - Pattern identity

/// The rhythmic pattern one take performs.
///
/// `id` is the stable key a reference package and the registry agree on;
/// `name` is display text and is never parsed. Length is authored in BARS, and
/// beats are derived, so a pattern cannot declare a length that does not divide
/// into bars.
struct ReferencePatternIdentity: Codable, Equatable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Phrase length of ONE repetition, in bars.
    let phraseBars: Int
    let beatsPerBar: Int

    init(id: String, name: String, phraseBars: Int, beatsPerBar: Int = 4) {
        self.id = id
        self.name = name
        self.phraseBars = phraseBars
        self.beatsPerBar = beatsPerBar
    }

    /// Phrase length of one repetition, in beats.
    var phraseBeats: Int { phraseBars * beatsPerBar }

    var isUsable: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phraseBars > 0
            && beatsPerBar > 0
    }
}

// MARK: - Platter direction

/// Which way the platter moves on the FIRST stroke of the phrase.
///
/// Recorded, never inferred: audio onsets cannot tell a push from a pull, and
/// guessing polarity is how a reference teaches the phrase backwards.
enum ReferenceStartingPlatterDirection: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case forward
    case backward

    var id: String { rawValue }
    var displayName: String { self == .forward ? "Forward (push)" : "Backward (pull)" }

    var notationDirection: ScratchNotationDirection {
        self == .forward ? .forward : .backward
    }
}

/// Which fader the technique is performed against.
///
/// Kept as recorded configuration, not a derived property of the technique:
/// the same chirp is a different reference on an upfader.
enum ReferenceFaderVariant: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case crossfader
    case upfader
    /// Performed with no fader work at all — the fader is parked open.
    case faderOpenThroughout

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crossfader: return "Crossfader"
        case .upfader: return "Upfader"
        case .faderOpenThroughout: return "Fader open throughout"
        }
    }

    /// `true` when a calibrated fader is required to evidence the take.
    var requiresCalibratedFader: Bool { true }
}

// MARK: - Take metadata

/// Everything an operator sets before recording, plus what the system records
/// about the take.
///
/// Every field here is persisted in the sidecar AND exported in the package
/// manifest — the repository rule that a field shown in the UI must be
/// modelled, validated, persisted and exported.
struct ReferenceTakeMetadata: Codable, Equatable, Sendable, Identifiable {

    static let currentSchemaVersion = "scratchlab_reference_take_v1"
    static let defaultPerformerName = "CXL"
    static let defaultRepetitionCount = 4
    static let defaultCountInBars = 1
    static let defaultTailBars = 1

    let schemaVersion: String
    /// Stable identity for this take, unique across all reference authoring.
    let referenceTakeID: String
    /// The authoring session this take belongs to.
    let authoringSessionID: String
    /// Monotonic take number inside the authoring session.
    let takeNumber: Int

    let performerName: String
    /// Who operated the capture. Distinct from the performer: the same take
    /// can be performed by CXL and operated by someone else.
    let operatorName: String

    let technique: ReferenceTechnique
    let pattern: ReferencePatternIdentity
    let bpm: Int
    let repetitionCount: Int
    let countInBars: Int
    let tailBars: Int
    let startingPlatterDirection: ReferenceStartingPlatterDirection
    let faderVariant: ReferenceFaderVariant
    let handedness: CaptureSessionHandedness
    let notes: String
    /// Monotonic version of this technique+pattern reference. A re-record of
    /// the same pattern increments it; the registry serves the highest
    /// approved version.
    let referenceVersion: Int

    /// The calibration in force when this take was recorded. Non-optional:
    /// a reference take cannot exist without one.
    let crossfaderCalibration: CrossfaderCalibration
    /// Hysteresis in force when the fader events were derived, so a package
    /// can be re-derived identically years later.
    let crossfaderHysteresisClosedAtOrBelow: Double
    let crossfaderHysteresisOpenAtOrAbove: Double
    let crossfaderHysteresisMinimumDwellSeconds: Double

    /// `var`, like `lifecycleState` and `reviewDecision`: `watchLinked` is
    /// re-derived in place when the matching Watch motion transfer lands after
    /// macOS media finalization. `ReferenceAuthoringTake.applyWatchEvidence`
    /// is its only writer.
    var deviceInfo: ReferenceDeviceInfo
    let recordedAt: Date
    var lifecycleState: ReferenceLifecycleState
    /// Set when an operator approves or rejects; nil while `draft`.
    var reviewDecision: ReferenceReviewDecision?

    var id: String { referenceTakeID }

    var hysteresis: CrossfaderHysteresis {
        CrossfaderHysteresis(
            closedAtOrBelow: crossfaderHysteresisClosedAtOrBelow,
            openAtOrAbove: crossfaderHysteresisOpenAtOrAbove,
            minimumDwellSeconds: crossfaderHysteresisMinimumDwellSeconds
        )
    }

    /// Total authored length of the take in beats, including count-in and tail.
    var totalBeats: Int {
        (countInBars * pattern.beatsPerBar)
            + (repetitionCount * pattern.phraseBeats)
            + (tailBars * pattern.beatsPerBar)
    }

    var secondsPerBeat: Double { bpm > 0 ? 60.0 / Double(bpm) : 0 }

    /// Take-relative seconds at which the first repetition starts.
    var firstRepetitionStartSeconds: Double {
        Double(countInBars * pattern.beatsPerBar) * secondsPerBeat
    }

    /// Duration of one repetition, in seconds.
    var repetitionDurationSeconds: Double {
        Double(pattern.phraseBeats) * secondsPerBeat
    }

    init(
        schemaVersion: String = ReferenceTakeMetadata.currentSchemaVersion,
        referenceTakeID: String,
        authoringSessionID: String,
        takeNumber: Int,
        performerName: String = ReferenceTakeMetadata.defaultPerformerName,
        operatorName: String,
        technique: ReferenceTechnique,
        pattern: ReferencePatternIdentity,
        bpm: Int,
        repetitionCount: Int = ReferenceTakeMetadata.defaultRepetitionCount,
        countInBars: Int = ReferenceTakeMetadata.defaultCountInBars,
        tailBars: Int = ReferenceTakeMetadata.defaultTailBars,
        startingPlatterDirection: ReferenceStartingPlatterDirection,
        faderVariant: ReferenceFaderVariant,
        handedness: CaptureSessionHandedness = .right,
        notes: String = "",
        referenceVersion: Int,
        crossfaderCalibration: CrossfaderCalibration,
        hysteresis: CrossfaderHysteresis = .default,
        deviceInfo: ReferenceDeviceInfo,
        recordedAt: Date,
        lifecycleState: ReferenceLifecycleState = .draft,
        reviewDecision: ReferenceReviewDecision? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.referenceTakeID = referenceTakeID
        self.authoringSessionID = authoringSessionID
        self.takeNumber = takeNumber
        self.performerName = performerName
        self.operatorName = operatorName
        self.technique = technique
        self.pattern = pattern
        self.bpm = bpm
        self.repetitionCount = repetitionCount
        self.countInBars = countInBars
        self.tailBars = tailBars
        self.startingPlatterDirection = startingPlatterDirection
        self.faderVariant = faderVariant
        self.handedness = handedness
        self.notes = notes
        self.referenceVersion = referenceVersion
        self.crossfaderCalibration = crossfaderCalibration
        self.crossfaderHysteresisClosedAtOrBelow = hysteresis.closedAtOrBelow
        self.crossfaderHysteresisOpenAtOrAbove = hysteresis.openAtOrAbove
        self.crossfaderHysteresisMinimumDwellSeconds = hysteresis.minimumDwellSeconds
        self.deviceInfo = deviceInfo
        self.recordedAt = recordedAt
        self.lifecycleState = lifecycleState
        self.reviewDecision = reviewDecision
    }
}

/// Hardware the take was recorded on. Provenance, never behaviour.
struct ReferenceDeviceInfo: Codable, Equatable, Sendable {
    let platform: String
    let appVersion: String
    let controllerName: String
    let controllerIdentifier: String
    let audioDeviceName: String?
    let videoDeviceName: String?
    let watchLinked: Bool

    init(
        platform: String,
        appVersion: String,
        controllerName: String,
        controllerIdentifier: String,
        audioDeviceName: String?,
        videoDeviceName: String?,
        watchLinked: Bool
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.controllerName = controllerName
        self.controllerIdentifier = controllerIdentifier
        self.audioDeviceName = audioDeviceName
        self.videoDeviceName = videoDeviceName
        self.watchLinked = watchLinked
    }
}

// MARK: - Repetition boundaries

/// One repetition inside a take, in beats and in seconds.
///
/// Boundaries are authored in BEATS and projected to seconds through the take's
/// BPM, so an operator nudging a boundary moves it on the grid rather than off
/// it. `isSelected` marks the repetition the operator chose as canonical.
struct ReferenceRepetitionBoundary: Codable, Equatable, Sendable, Identifiable {
    let index: Int
    /// Take-relative start, in beats from the start of the recording
    /// (including the count-in bar).
    var startBeat: Double
    var endBeat: Double

    var id: Int { index }

    var durationBeats: Double { max(0, endBeat - startBeat) }

    func startSeconds(bpm: Int) -> Double {
        bpm > 0 ? startBeat * 60.0 / Double(bpm) : 0
    }

    func endSeconds(bpm: Int) -> Double {
        bpm > 0 ? endBeat * 60.0 / Double(bpm) : 0
    }

    init(index: Int, startBeat: Double, endBeat: Double) {
        self.index = index
        self.startBeat = startBeat
        self.endBeat = endBeat
    }
}

/// The full set of repetition boundaries for a take, plus the operator's
/// selection.
struct ReferencePhraseBoundaries: Codable, Equatable, Sendable {
    var repetitions: [ReferenceRepetitionBoundary]
    /// Index of the repetition the operator approved. `nil` until they choose.
    var selectedRepetitionIndex: Int?

    init(repetitions: [ReferenceRepetitionBoundary], selectedRepetitionIndex: Int? = nil) {
        self.repetitions = repetitions
        self.selectedRepetitionIndex = selectedRepetitionIndex
    }

    var selectedRepetition: ReferenceRepetitionBoundary? {
        guard let selectedRepetitionIndex else { return nil }
        return repetitions.first { $0.index == selectedRepetitionIndex }
    }

    /// The nominal boundaries implied by the take metadata, before any
    /// operator adjustment. This is a STARTING POINT for review, never the
    /// approved answer — a performer does not land exactly on the grid, which
    /// is why the operator can nudge each edge.
    static func nominal(for metadata: ReferenceTakeMetadata) -> ReferencePhraseBoundaries {
        let countInBeats = Double(metadata.countInBars * metadata.pattern.beatsPerBar)
        let phraseBeats = Double(metadata.pattern.phraseBeats)
        let repetitions = (0..<metadata.repetitionCount).map { index in
            ReferenceRepetitionBoundary(
                index: index,
                startBeat: countInBeats + (Double(index) * phraseBeats),
                endBeat: countInBeats + (Double(index + 1) * phraseBeats)
            )
        }
        return ReferencePhraseBoundaries(repetitions: repetitions)
    }
}

// MARK: - Review decision

/// An operator's signed decision on a take.
struct ReferenceReviewDecision: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case approved
        case rejected
    }

    let outcome: Outcome
    let decidedBy: String
    let decidedAt: Date
    let notes: String
    /// The repetition the operator approved. Required for `approved`.
    let selectedRepetitionIndex: Int?

    init(
        outcome: Outcome,
        decidedBy: String,
        decidedAt: Date,
        notes: String = "",
        selectedRepetitionIndex: Int?
    ) {
        self.outcome = outcome
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.notes = notes
        self.selectedRepetitionIndex = selectedRepetitionIndex
    }
}
