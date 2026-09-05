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

// MARK: - Tear segmentation review

/// Half-open, take-relative seconds. The canonical record's own span type is
/// reused rather than re-declared so a reviewed boundary and a canonical
/// gesture record cannot drift apart on containment or duration semantics.
typealias ReferenceTearTimeSpan = ScratchNotation.GestureRecord.TimeSpan

/// What an operator asserts one same-direction gesture is.
///
/// Deliberately five closed cases. `unknown` is a first-class answer, not an
/// absence: "I looked and the evidence does not support a reading" must be
/// recordable, and it must never be rounded to the nearest tear.
///
/// `nonTear` is NOT a technique claim either. It says only that this gesture
/// carries no internal platter tear hold; whether it is half a Baby, a ghost
/// move or something with no name in this vocabulary is a separate question
/// this slice does not ask.
enum ReferenceTearClassification: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case unknown
    case nonTear = "non_tear"
    case tear1
    case tear2
    case tear3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .nonTear: return "Not a tear"
        case .tear1: return "1-tear"
        case .tear2: return "2-tear"
        case .tear3: return "3-tear"
        }
    }

    /// Internal PLATTER tear holds this classification asserts. `nil` for
    /// `unknown`, which asserts nothing — never `0`, because "no holds" and
    /// "we do not know" are different answers.
    var assertedTearHoldCount: Int? {
        switch self {
        case .unknown: return nil
        case .nonTear: return 0
        case .tear1: return 1
        case .tear2: return 2
        case .tear3: return 3
        }
    }

    /// The canonical derived structure for this reading, when the canonical
    /// vocabulary has one. `unknown` and `nonTear` map to `nil` on purpose:
    /// neither is a structure the classifier is permitted to name.
    var derivedStructure: ScratchNotationDerivedStructure? {
        guard let count = assertedTearHoldCount else { return nil }
        return ScratchNotationDerivedStructure.tearCandidate(holdCount: count)
    }

    /// The reading a bounded platter hold count supports. A count outside the
    /// authored 1...3 plain-tear vocabulary reports `unknown` and is never
    /// rounded down to the nearest supported tear.
    static func proposed(tearHoldCount: Int) -> ReferenceTearClassification {
        switch tearHoldCount {
        case 0: return .nonTear
        case 1: return .tear1
        case 2: return .tear2
        case 3: return .tear3
        default: return .unknown
        }
    }
}

/// What a reviewed boundary marks.
///
/// The two are kept apart because the canonical layer keeps them apart: a
/// fader click is instantaneous fader evidence and is NEVER a platter tear
/// hold, so a boundary the operator names a click stops counting toward the
/// tear hold count without being deleted or hidden.
enum ReferenceTearBoundaryKind: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// A bounded stationary PLATTER interval.
    case hold
    /// Fader work the automatic pass mistook for, or found on top of, a
    /// stationary platter. Cited as evidence; never counted as a tear hold.
    case faderClick = "fader_click"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Platter hold"
        case .faderClick: return "Fader click"
        }
    }

    var countsAsTearHold: Bool { self == .hold }
}

/// How well the evidence under a boundary supports the kind it is given.
///
/// `ambiguous` is a recorded operator statement, not a computed score. It
/// exists so a boundary can be kept, counted or discounted, and still carry
/// "this one is not clean" into whatever reads the review later.
enum ReferenceTearEvidenceQuality: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case clear
    case ambiguous

    var id: String { rawValue }
    var displayName: String { self == .clear ? "Clear" : "Ambiguous" }
    var isAmbiguous: Bool { self == .ambiguous }
}

/// Where a boundary came from. Retained for the life of the boundary, so an
/// automatic proposal the operator moved is never mistaken for one they
/// invented.
enum ReferenceTearBoundaryOrigin: String, Codable, Equatable, Sendable {
    case automatic
    case operatorAdded = "operator_added"

    var displayName: String {
        self == .automatic ? "Proposed automatically" : "Added by operator"
    }
}

/// Machine-readable justifications for everything this layer proposes,
/// including the readings it declines to make.
enum ReferenceTearReviewReason: String, CaseIterable, Codable, Equatable, Sendable {
    case noMotionEvidence
    case malformedMovementEvent
    case overlappingMovementEvents
    case uncalibratedPlatterCoordinates
    case gapDerivedStationaryInterval
    case boundedStationaryInterval
    case shortStationaryInterval
    case directionReversal
    case contiguousSameDirectionRuns
    case lowMovementConfidence
    case coincidentFaderClick
    case faderOpenThroughout
    case faderClosedThroughout
    case faderStateVariesWithinRegion
    case faderUnobserved
    case holdCountOutsideSupportedRange
    case tearCountIsPlatterOnly

    var detail: String {
        switch self {
        case .noMotionEvidence:
            return "the take carries no decoded platter movement evidence"
        case .malformedMovementEvent:
            return "at least one recorded movement event had a non-finite or non-positive span and was not segmented"
        case .overlappingMovementEvents:
            return "consecutive movement events overlap in time, so no stationary interval is claimed between them"
        case .uncalibratedPlatterCoordinates:
            return "recorded platter positions are normalised over this take's own range and are not calibrated revolutions, so no absolute travel is claimed"
        case .gapDerivedStationaryInterval:
            return "this stationary interval is the absence of platter telemetry between two observed runs, not a measured zero-velocity sample"
        case .boundedStationaryInterval:
            return "a stationary interval bounded on both sides by observed same-direction travel"
        case .shortStationaryInterval:
            return "the stationary interval is shorter than the review's provisional hold duration"
        case .directionReversal:
            return "travel polarity flipped here, which ends a gesture and is never a tear hold"
        case .contiguousSameDirectionRuns:
            return "two same-direction runs abut with no separating interval, so nothing is claimed between them"
        case .lowMovementConfidence:
            return "at least one movement event backing this region reported low decoder confidence"
        case .coincidentFaderClick:
            return "a fader cut, pulse or transform pulse coincides with this interval; it is cited as evidence and never counted as a tear hold"
        case .faderOpenThroughout:
            return "every fader observation covering this region reports open"
        case .faderClosedThroughout:
            return "every fader observation covering this region reports closed"
        case .faderStateVariesWithinRegion:
            return "the fader is observed in more than one state inside this region"
        case .faderUnobserved:
            return "no fader observation covers this region, which means unknown and never implicitly open"
        case .holdCountOutsideSupportedRange:
            return "the internal hold count lies outside the supported 1...3 plain-tear vocabulary"
        case .tearCountIsPlatterOnly:
            return "the tear hold count derives from the platter stream alone; fader evidence cannot change it"
        }
    }

    static func ordered(_ reasons: [ReferenceTearReviewReason]) -> [ReferenceTearReviewReason] {
        allCases.filter { reasons.contains($0) }
    }
}

/// Provenance for one operator correction: who, when, why, and in what words.
///
/// Carries a full `ScratchNotation.GestureRecord.Evidence` rather than a bare
/// string so a correction made here is the same shape of provenance the
/// canonical layer already demands of a manual label — and can be validated
/// with the canonical layer's own rule.
struct ReferenceTearCorrection: Equatable, Sendable {
    let correctedBy: String
    let correctedAt: Date
    let notes: String
    let evidence: ScratchNotation.GestureRecord.Evidence

    init(correctedBy: String, correctedAt: Date, notes: String, reason: String) {
        self.correctedBy = correctedBy
        self.correctedAt = correctedAt
        self.notes = notes
        self.evidence = ScratchNotation.GestureRecord.Evidence(
            provenance: .manuallyCorrected,
            observation: ScratchNotationEvidence(
                source: .manualCorrection,
                confidence: 1,
                reason: reason
            )
        )
    }

    /// Pure invariant check, separate from construction — the same doctrine
    /// the rest of this layer follows.
    func validationIssues() -> [String] {
        var issues: [String] = []
        if correctedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("a correction must name who made it")
        }
        if evidence.provenance != .manuallyCorrected {
            issues.append("a correction must carry manuallyCorrected provenance, got '\(evidence.provenance.rawValue)'")
        }
        issues.append(contentsOf: ScratchNotation.GestureRecord.evidenceIssues(evidence, platter: true))
        return issues
    }
}

/// One bounded platter interval or reversal, as this review presents it.
///
/// A segment is DERIVED presentation over the take's recorded movement
/// events. It never replaces them: `ReferenceTearSegmentationReview` keeps the
/// raw events verbatim beside these, and nothing in this file mutates,
/// reorders, repairs or drops one.
struct ReferenceTearMotionSegment: Equatable, Sendable, Identifiable {
    let index: Int
    let span: ReferenceTearTimeSpan
    let state: ScratchNotationMotionState
    /// Decoder confidence for a travel interval. `nil` for a stationary
    /// interval, which is inferred from an ABSENCE of platter telemetry and
    /// therefore has no measured confidence of its own.
    let confidence: Double?
    /// Index into `ReferenceTearSegmentationReview.rawMovementEvents`, or
    /// `nil` for a stationary interval, which no single event produced.
    let movementEventIndex: Int?
    let reasons: [ReferenceTearReviewReason]

    var id: Int { index }
    var isStationary: Bool { state.isStationary }
    var isTravel: Bool { state.isTravel }
}

/// A polarity flip between two gestures.
///
/// A direct turnaround is a zero-width span at the shared instant; a stop
/// before opposite travel spans the whole stationary interval rather than
/// inventing an instant inside it — the same rule
/// `PlatterMotionSegmenter.Reversal` states.
struct ReferenceTearReversal: Equatable, Sendable, Identifiable {
    let index: Int
    let span: ReferenceTearTimeSpan
    let from: ScratchNotationDirection
    let to: ScratchNotationDirection

    var id: Int { index }
    var isDirectTurnaround: Bool { span.duration <= 0 }
}

/// One reviewed tear boundary.
///
/// The automatic proposal is retained verbatim in `proposal` for the life of
/// the boundary. Moving, re-kinding, flagging or removing changes only the
/// live fields beside it, so the machine's reading and the operator's
/// disagreement with it both stay inspectable. Removal is a FLAG: no raw
/// event, and no proposal, is ever deleted.
struct ReferenceTearBoundary: Equatable, Sendable, Identifiable {

    /// What the automatic pass proposed. Absent for a boundary the operator
    /// added, which the machine never proposed at all.
    struct Proposal: Equatable, Sendable {
        let span: ReferenceTearTimeSpan
        let kind: ReferenceTearBoundaryKind
        let evidenceQuality: ReferenceTearEvidenceQuality
        let reasons: [ReferenceTearReviewReason]
    }

    let id: String
    let origin: ReferenceTearBoundaryOrigin
    let proposal: Proposal?
    private(set) var span: ReferenceTearTimeSpan
    private(set) var kind: ReferenceTearBoundaryKind
    private(set) var evidenceQuality: ReferenceTearEvidenceQuality
    /// `true` when the operator has struck this boundary out. The record and
    /// its proposal stay; only the count changes.
    private(set) var isRemoved: Bool
    /// Every correction applied to this boundary, oldest first. Appended to,
    /// never replaced, so the correction history is not overwritten by the
    /// next edit.
    private(set) var corrections: [ReferenceTearCorrection]

    init(
        id: String,
        origin: ReferenceTearBoundaryOrigin,
        proposal: Proposal?,
        span: ReferenceTearTimeSpan,
        kind: ReferenceTearBoundaryKind,
        evidenceQuality: ReferenceTearEvidenceQuality,
        isRemoved: Bool = false,
        corrections: [ReferenceTearCorrection] = []
    ) {
        self.id = id
        self.origin = origin
        self.proposal = proposal
        self.span = span
        self.kind = kind
        self.evidenceQuality = evidenceQuality
        self.isRemoved = isRemoved
        self.corrections = corrections
    }

    /// The ONE predicate that decides whether this boundary contributes to a
    /// tear hold count. A removed boundary and a fader click both contribute
    /// nothing, and neither is deleted to make that true.
    var countsAsTearHold: Bool { !isRemoved && kind.countsAsTearHold }

    var isCorrected: Bool { !corrections.isEmpty }
    var latestCorrection: ReferenceTearCorrection? { corrections.last }

    /// `true` when the live boundary no longer matches what the machine
    /// proposed. An operator-added boundary always disagrees: the machine
    /// proposed nothing there.
    var differsFromProposal: Bool {
        guard let proposal else { return true }
        return isRemoved
            || proposal.span != span
            || proposal.kind != kind
            || proposal.evidenceQuality != evidenceQuality
    }

    fileprivate mutating func apply(_ correction: ReferenceTearCorrection) {
        corrections.append(correction)
    }

    fileprivate mutating func move(to span: ReferenceTearTimeSpan, correction: ReferenceTearCorrection) {
        self.span = span
        apply(correction)
    }

    fileprivate mutating func setKind(_ kind: ReferenceTearBoundaryKind, correction: ReferenceTearCorrection) {
        self.kind = kind
        apply(correction)
    }

    fileprivate mutating func setEvidenceQuality(
        _ quality: ReferenceTearEvidenceQuality,
        correction: ReferenceTearCorrection
    ) {
        evidenceQuality = quality
        apply(correction)
    }

    fileprivate mutating func setRemoved(_ removed: Bool, correction: ReferenceTearCorrection) {
        isRemoved = removed
        apply(correction)
    }
}

/// One same-direction gesture under review, with the machine's reading and
/// the operator's.
struct ReferenceTearCandidate: Equatable, Sendable, Identifiable {
    let id: String
    let gestureIndex: Int
    let direction: ScratchNotationDirection
    let span: ReferenceTearTimeSpan
    /// Indices into `ReferenceTearSegmentationReview.segments`. The candidate
    /// CITES its evidence; it never copies it.
    let motionSegmentIndices: [Int]
    /// The automatic reading, retained verbatim and never rewritten by a
    /// correction.
    let proposedClassification: ReferenceTearClassification
    /// Weakest decoder confidence across the travel this gesture is built
    /// from, or `nil` when no backing event reported one.
    let proposedConfidence: Double?
    let proposalReasons: [ReferenceTearReviewReason]
    private(set) var boundaries: [ReferenceTearBoundary]
    /// The operator's reading. AUTHORITATIVE where present.
    private(set) var manualClassification: ReferenceTearClassification?
    private(set) var classificationCorrections: [ReferenceTearCorrection]
    /// Monotonic counter behind operator-added boundary IDs, so an added,
    /// removed and re-added boundary never reuses an identifier.
    private(set) var addedBoundaryCount: Int

    init(
        id: String,
        gestureIndex: Int,
        direction: ScratchNotationDirection,
        span: ReferenceTearTimeSpan,
        motionSegmentIndices: [Int],
        proposedClassification: ReferenceTearClassification,
        proposedConfidence: Double?,
        proposalReasons: [ReferenceTearReviewReason],
        boundaries: [ReferenceTearBoundary],
        manualClassification: ReferenceTearClassification? = nil,
        classificationCorrections: [ReferenceTearCorrection] = [],
        addedBoundaryCount: Int = 0
    ) {
        self.id = id
        self.gestureIndex = gestureIndex
        self.direction = direction
        self.span = span
        self.motionSegmentIndices = motionSegmentIndices
        self.proposedClassification = proposedClassification
        self.proposedConfidence = proposedConfidence
        self.proposalReasons = proposalReasons
        self.boundaries = boundaries
        self.manualClassification = manualClassification
        self.classificationCorrections = classificationCorrections
        self.addedBoundaryCount = addedBoundaryCount
    }

    /// The reading every consumer must use. A manual classification always
    /// wins; with none, the machine's proposal stands.
    var effectiveClassification: ReferenceTearClassification {
        manualClassification ?? proposedClassification
    }

    var isManuallyClassified: Bool { manualClassification != nil }
    var latestClassificationCorrection: ReferenceTearCorrection? { classificationCorrections.last }

    /// Boundaries that still count. Fader clicks and removed boundaries are
    /// excluded here and nowhere else.
    var countedTearHoldCount: Int { boundaries.filter(\.countsAsTearHold).count }

    /// Boundaries retained but not counted — struck out or renamed a click.
    var discountedBoundaryCount: Int { boundaries.count - countedTearHoldCount }

    var hasAmbiguousEvidence: Bool {
        boundaries.contains { !$0.isRemoved && $0.evidenceQuality.isAmbiguous }
    }

    /// `true` when the reading in force asserts a hold count the surviving
    /// boundaries do not support. Surfaced, never auto-corrected: the
    /// operator's classification and their boundary edits are two separate
    /// assertions and this layer refuses to silently reconcile them.
    var classificationDisagreesWithBoundaryCount: Bool {
        guard let asserted = effectiveClassification.assertedTearHoldCount else { return false }
        return asserted != countedTearHoldCount
    }

    /// The reading the surviving boundaries alone would support. Offered to
    /// the operator; never applied for them.
    var boundarySupportedClassification: ReferenceTearClassification {
        .proposed(tearHoldCount: countedTearHoldCount)
    }

    var isReviewed: Bool {
        isManuallyClassified || boundaries.contains(where: \.isCorrected)
    }

    fileprivate mutating func classify(
        as classification: ReferenceTearClassification,
        correction: ReferenceTearCorrection
    ) {
        manualClassification = classification
        classificationCorrections.append(correction)
    }

    fileprivate mutating func addBoundary(
        span: ReferenceTearTimeSpan,
        kind: ReferenceTearBoundaryKind,
        evidenceQuality: ReferenceTearEvidenceQuality,
        correction: ReferenceTearCorrection
    ) -> String {
        let boundaryID = "\(id)-added-\(String(format: "%03d", addedBoundaryCount))"
        addedBoundaryCount += 1
        boundaries.append(
            ReferenceTearBoundary(
                id: boundaryID,
                origin: .operatorAdded,
                proposal: nil,
                span: span,
                kind: kind,
                evidenceQuality: evidenceQuality,
                corrections: [correction]
            )
        )
        sortBoundaries()
        return boundaryID
    }

    fileprivate mutating func mutateBoundary(
        id boundaryID: String,
        _ body: (inout ReferenceTearBoundary) -> Void
    ) -> Bool {
        guard let position = boundaries.firstIndex(where: { $0.id == boundaryID }) else { return false }
        body(&boundaries[position])
        sortBoundaries()
        return true
    }

    /// Chronological, with identifier order breaking a tie so ordering is
    /// total and stable across edits.
    private mutating func sortBoundaries() {
        boundaries.sort {
            $0.span.startTime == $1.span.startTime
                ? $0.id < $1.id
                : $0.span.startTime < $1.span.startTime
        }
    }
}

/// Everything an operator needs to inspect and correct one take's tear
/// segmentation, and every correction they made.
///
/// THIS REVIEW NEVER APPROVES ANYTHING. It does not touch
/// `ReferenceTakeMetadata.lifecycleState`, it does not write a
/// `ReferenceReviewDecision`, it is not read by `ReferenceValidator`, and a
/// fully corrected review leaves the take exactly as un-approved and
/// un-publishable as an untouched one. Making a take canonical remains the
/// explicit, separately gated operator action it already was.
struct ReferenceTearSegmentationReview: Equatable, Sendable {

    let referenceTakeID: String
    /// The take's recorded platter movement evidence, VERBATIM. Nothing in
    /// this type filters, reorders, repairs or removes an entry, and no
    /// correction below ever writes back into it.
    let rawMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    /// Derived travel and stationary intervals over `rawMovementEvents`.
    let segments: [ReferenceTearMotionSegment]
    let reversals: [ReferenceTearReversal]
    /// Committed crossfader state spans for this take, cited from the take's
    /// own derivation rather than re-derived here.
    let faderIntervals: [CrossfaderStateInterval]
    /// Instantaneous fader work — cut, pulse, transform pulse. Cited as
    /// evidence beside a boundary and never counted as a tear hold.
    let faderClicks: [CrossfaderSemanticEvent]
    /// Review-level justifications, including why a reading was declined.
    let reasons: [ReferenceTearReviewReason]
    private(set) var candidates: [ReferenceTearCandidate]
    /// Free-text operator notes for the whole review.
    private(set) var notes: String
    private(set) var noteCorrections: [ReferenceTearCorrection]

    init(
        referenceTakeID: String,
        rawMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
        segments: [ReferenceTearMotionSegment],
        reversals: [ReferenceTearReversal],
        faderIntervals: [CrossfaderStateInterval],
        faderClicks: [CrossfaderSemanticEvent],
        reasons: [ReferenceTearReviewReason],
        candidates: [ReferenceTearCandidate],
        notes: String = "",
        noteCorrections: [ReferenceTearCorrection] = []
    ) {
        self.referenceTakeID = referenceTakeID
        self.rawMovementEvents = rawMovementEvents
        self.segments = segments
        self.reversals = reversals
        self.faderIntervals = faderIntervals
        self.faderClicks = faderClicks
        self.reasons = reasons
        self.candidates = candidates
        self.notes = notes
        self.noteCorrections = noteCorrections
    }

    var stationaryIntervals: [ReferenceTearMotionSegment] { segments.filter(\.isStationary) }
    var travelIntervals: [ReferenceTearMotionSegment] { segments.filter(\.isTravel) }

    var hasMotionEvidence: Bool { !rawMovementEvents.isEmpty }

    /// Candidates whose reading in force is `unknown`.
    var unknownCandidateCount: Int {
        candidates.filter { $0.effectiveClassification == .unknown }.count
    }

    var ambiguousCandidateCount: Int { candidates.filter(\.hasAmbiguousEvidence).count }

    var correctedCandidateCount: Int { candidates.filter(\.isReviewed).count }

    /// Total surviving platter holds across every candidate. PLATTER ONLY —
    /// fader clicks and struck-out boundaries contribute nothing, by the same
    /// rule the canonical classifier states.
    var totalCountedTearHoldCount: Int {
        candidates.reduce(0) { $0 + $1.countedTearHoldCount }
    }

    /// `true` only when every candidate carries an explicit operator reading.
    ///
    /// This is a REVIEW-COMPLETENESS figure and nothing more. A complete
    /// review still approves nothing and still installs nothing; see the type
    /// comment.
    var everyCandidateHasAnOperatorReading: Bool {
        !candidates.isEmpty && candidates.allSatisfy(\.isManuallyClassified)
    }

    var candidatesDisagreeingWithTheirBoundaries: [ReferenceTearCandidate] {
        candidates.filter(\.classificationDisagreesWithBoundaryCount)
    }

    func candidate(id: String) -> ReferenceTearCandidate? {
        candidates.first { $0.id == id }
    }

    /// Fader observations intersecting `span`, as a single reading. An
    /// uncovered region reads UNKNOWN and never implicitly open.
    func faderReading(over span: ReferenceTearTimeSpan) -> ReferenceTearFaderReading {
        var states: Set<CrossfaderGateState> = []
        for interval in faderIntervals {
            let lower = max(interval.startTime, span.startTime)
            let upper = min(interval.endTime, span.endTime)
            guard upper > lower || (span.duration <= 0 && lower <= upper) else { continue }
            states.insert(interval.state)
        }
        switch (states.count, states.first) {
        case (0, _): return .unobserved
        case (1, .some(.open)): return .open
        case (1, .some(.closed)): return .closed
        case (1, .some(.transitioning)): return .transitioning
        default: return .mixed
        }
    }

    /// Fader clicks intersecting `span`, in evidence order.
    func faderClicks(over span: ReferenceTearTimeSpan) -> [CrossfaderSemanticEvent] {
        faderClicks.filter { $0.endTime >= span.startTime && $0.startTime <= span.endTime }
    }

    // MARK: Corrections

    /// Every mutator below records provenance and leaves the machine's
    /// proposal untouched. None of them advances a lifecycle state, writes a
    /// review decision, or makes the take approvable.

    @discardableResult
    mutating func classifyCandidate(
        id candidateID: String,
        as classification: ReferenceTearClassification,
        correction: ReferenceTearCorrection
    ) -> Bool {
        mutateCandidate(id: candidateID) { $0.classify(as: classification, correction: correction) }
    }

    /// Add a boundary the automatic pass did not propose.
    ///
    /// Returns the new boundary's identifier, or `nil` when the candidate is
    /// unknown or the span is not a bounded, finite interval. A rejected add
    /// changes nothing at all.
    @discardableResult
    mutating func addBoundary(
        toCandidate candidateID: String,
        span: ReferenceTearTimeSpan,
        kind: ReferenceTearBoundaryKind,
        evidenceQuality: ReferenceTearEvidenceQuality,
        correction: ReferenceTearCorrection
    ) -> String? {
        guard Self.isUsableSpan(span) else { return nil }
        guard let position = candidates.firstIndex(where: { $0.id == candidateID }) else { return nil }
        return candidates[position].addBoundary(
            span: span,
            kind: kind,
            evidenceQuality: evidenceQuality,
            correction: correction
        )
    }

    @discardableResult
    mutating func moveBoundary(
        inCandidate candidateID: String,
        boundaryID: String,
        to span: ReferenceTearTimeSpan,
        correction: ReferenceTearCorrection
    ) -> Bool {
        guard Self.isUsableSpan(span) else { return false }
        return mutateCandidate(id: candidateID) {
            $0.mutateBoundary(id: boundaryID) { $0.move(to: span, correction: correction) }
        }
    }

    @discardableResult
    mutating func setBoundaryKind(
        inCandidate candidateID: String,
        boundaryID: String,
        to kind: ReferenceTearBoundaryKind,
        correction: ReferenceTearCorrection
    ) -> Bool {
        mutateCandidate(id: candidateID) {
            $0.mutateBoundary(id: boundaryID) { $0.setKind(kind, correction: correction) }
        }
    }

    @discardableResult
    mutating func setBoundaryEvidenceQuality(
        inCandidate candidateID: String,
        boundaryID: String,
        to quality: ReferenceTearEvidenceQuality,
        correction: ReferenceTearCorrection
    ) -> Bool {
        mutateCandidate(id: candidateID) {
            $0.mutateBoundary(id: boundaryID) { $0.setEvidenceQuality(quality, correction: correction) }
        }
    }

    /// Strike a boundary out. The record, its proposal and its correction
    /// history all survive; only `countsAsTearHold` changes.
    @discardableResult
    mutating func setBoundaryRemoved(
        inCandidate candidateID: String,
        boundaryID: String,
        removed: Bool,
        correction: ReferenceTearCorrection
    ) -> Bool {
        mutateCandidate(id: candidateID) {
            $0.mutateBoundary(id: boundaryID) { $0.setRemoved(removed, correction: correction) }
        }
    }

    mutating func setNotes(_ notes: String, correction: ReferenceTearCorrection) {
        self.notes = notes
        noteCorrections.append(correction)
    }

    /// A bounded, finite, non-negative interval. A zero-width or inverted
    /// boundary is refused rather than silently clamped.
    static func isUsableSpan(_ span: ReferenceTearTimeSpan) -> Bool {
        span.startTime.isFinite && span.endTime.isFinite
            && span.startTime >= 0 && span.endTime > span.startTime
    }

    @discardableResult
    private mutating func mutateCandidate(
        id candidateID: String,
        _ body: (inout ReferenceTearCandidate) -> Void
    ) -> Bool {
        guard let position = candidates.firstIndex(where: { $0.id == candidateID }) else { return false }
        body(&candidates[position])
        return true
    }

    @discardableResult
    private mutating func mutateCandidate(
        id candidateID: String,
        _ body: (inout ReferenceTearCandidate) -> Bool
    ) -> Bool {
        guard let position = candidates.firstIndex(where: { $0.id == candidateID }) else { return false }
        return body(&candidates[position])
    }
}

/// A single fader reading over a region. `unobserved` is never open.
enum ReferenceTearFaderReading: String, Equatable, Sendable {
    case unobserved
    case open
    case closed
    case transitioning
    case mixed

    var displayName: String {
        switch self {
        case .unobserved: return "Fader unobserved"
        case .open: return "Fader open throughout"
        case .closed: return "Fader closed throughout"
        case .transitioning: return "Fader in transition"
        case .mixed: return "Fader state varies"
        }
    }

    var reason: ReferenceTearReviewReason {
        switch self {
        case .unobserved: return .faderUnobserved
        case .open: return .faderOpenThroughout
        case .closed: return .faderClosedThroughout
        case .transitioning, .mixed: return .faderStateVariesWithinRegion
        }
    }
}

/// Provisional thresholds for the automatic pass.
///
/// PROVISIONAL, on the same terms as `CrossfaderStateDeriver`'s defaults: not
/// derived from any recorded reference take. They are caller-supplied
/// precisely so a measured value can replace them without touching the
/// builder.
struct ReferenceTearReviewConfiguration: Equatable, Sendable {
    /// A bounded stationary interval shorter than this is proposed, but
    /// flagged ambiguous rather than presented as a clean hold.
    var ambiguousStationaryDuration: Double = 0.12
    /// Decoder confidence at or below which a travel interval is flagged.
    var lowMovementConfidence: Double = 0.75
    /// Times closer than this are the same instant.
    var timeTolerance: Double = 1e-6

    init(
        ambiguousStationaryDuration: Double = 0.12,
        lowMovementConfidence: Double = 0.75,
        timeTolerance: Double = 1e-6
    ) {
        self.ambiguousStationaryDuration = ambiguousStationaryDuration
        self.lowMovementConfidence = lowMovementConfidence
        self.timeTolerance = timeTolerance
    }
}

/// The automatic pass: a PURE derivation of tear candidates from one take's
/// already-recorded evidence.
///
/// It re-decodes nothing. Platter movement events come from the take's
/// finalized sidecar exactly as `CaptureCore.derivePlatterMovementEvents`
/// wrote them, and fader spans and clicks come from the take's own
/// `CrossfaderDerivation`. This builder therefore adds no second decoder and
/// no second calibration: it only groups, correlates and cites.
///
/// `PlatterMotionSegmenter` is deliberately NOT used here. Its input contract
/// is CALIBRATED platter samples with an externally established reference,
/// and a reference take's persisted movement positions are normalised over
/// the take's own step range — supplying them would fabricate a calibration
/// the take does not carry. Every review it produces therefore states
/// `.uncalibratedPlatterCoordinates`, and no absolute travel is claimed.
enum ReferenceTearSegmentationReviewBuilder {

    static func build(
        for evidence: ReferenceTakeEvidence,
        configuration: ReferenceTearReviewConfiguration = ReferenceTearReviewConfiguration()
    ) -> ReferenceTearSegmentationReview {
        build(
            referenceTakeID: evidence.metadata.referenceTakeID,
            movementEvents: evidence.platterMovementEvents,
            derivation: evidence.derivation,
            configuration: configuration
        )
    }

    static func build(
        referenceTakeID: String,
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
        derivation: CrossfaderDerivation?,
        configuration: ReferenceTearReviewConfiguration = ReferenceTearReviewConfiguration()
    ) -> ReferenceTearSegmentationReview {

        let faderIntervals = derivation?.intervals ?? []
        let faderClicks = (derivation?.events ?? []).filter {
            $0.kind == .cut || $0.kind == .pulse || $0.kind == .transformPulse
        }

        var reviewReasons: [ReferenceTearReviewReason] = []
        if movementEvents.isEmpty { reviewReasons.append(.noMotionEvidence) }
        else { reviewReasons.append(.uncalibratedPlatterCoordinates) }
        if faderIntervals.isEmpty { reviewReasons.append(.faderUnobserved) }

        // Usable travel, in evidence order by time. The raw array is retained
        // untouched; this is a view over it that carries each entry's original
        // index so every derived segment can cite the event it came from.
        struct Travel {
            let eventIndex: Int
            let span: ReferenceTearTimeSpan
            let direction: ScratchNotationDirection
            let confidence: Double
        }
        var travels: [Travel] = []
        var sawMalformed = false
        for (index, event) in movementEvents.enumerated() {
            guard event.startTime.isFinite, event.endTime.isFinite,
                  event.startTime >= 0, event.endTime > event.startTime,
                  let direction = notationDirection(event.direction) else {
                sawMalformed = true
                continue
            }
            travels.append(
                Travel(
                    eventIndex: index,
                    span: ReferenceTearTimeSpan(startTime: event.startTime, endTime: event.endTime),
                    direction: direction,
                    confidence: event.confidence
                )
            )
        }
        travels.sort {
            $0.span.startTime == $1.span.startTime
                ? $0.span.endTime < $1.span.endTime
                : $0.span.startTime < $1.span.startTime
        }
        if sawMalformed { reviewReasons.append(.malformedMovementEvent) }

        // Interleave the travel runs with the intervals between them. An
        // interval is stationary only when it is a real, positive-width gap in
        // the platter telemetry; abutting or overlapping runs claim nothing.
        var segments: [ReferenceTearMotionSegment] = []
        var sawOverlap = false
        for (position, travel) in travels.enumerated() {
            if position > 0 {
                let previous = travels[position - 1]
                let gap = travel.span.startTime - previous.span.endTime
                if gap < -configuration.timeTolerance {
                    sawOverlap = true
                } else if gap > configuration.timeTolerance {
                    let span = ReferenceTearTimeSpan(
                        startTime: previous.span.endTime,
                        endTime: travel.span.startTime
                    )
                    var reasons: [ReferenceTearReviewReason] = [.gapDerivedStationaryInterval]
                    if previous.direction == travel.direction {
                        reasons.append(.boundedStationaryInterval)
                    } else {
                        reasons.append(.directionReversal)
                    }
                    if span.duration < configuration.ambiguousStationaryDuration {
                        reasons.append(.shortStationaryInterval)
                    }
                    segments.append(
                        ReferenceTearMotionSegment(
                            index: segments.count,
                            span: span,
                            state: .stationary,
                            confidence: nil,
                            movementEventIndex: nil,
                            reasons: ReferenceTearReviewReason.ordered(reasons)
                        )
                    )
                } else if previous.direction == travel.direction {
                    // Two same-direction runs with nothing between them: the
                    // decoder only splits on a gap or a sign flip, so this is
                    // not evidence of a pause and must not become one.
                    segments.append(
                        contiguityMarker(index: segments.count, at: travel.span.startTime)
                    )
                }
            }
            var reasons: [ReferenceTearReviewReason] = []
            if travel.confidence <= configuration.lowMovementConfidence {
                reasons.append(.lowMovementConfidence)
            }
            segments.append(
                ReferenceTearMotionSegment(
                    index: segments.count,
                    span: travel.span,
                    state: ScratchNotationMotionState(direction: travel.direction),
                    confidence: travel.confidence,
                    movementEventIndex: travel.eventIndex,
                    reasons: ReferenceTearReviewReason.ordered(reasons)
                )
            )
        }
        if sawOverlap { reviewReasons.append(.overlappingMovementEvents) }

        // Reversals. A stop before opposite travel spans the whole stationary
        // interval; a direct turnaround is the zero-width shared instant.
        var reversals: [ReferenceTearReversal] = []
        for (position, travel) in travels.enumerated() where position > 0 {
            let previous = travels[position - 1]
            guard previous.direction != travel.direction else { continue }
            reversals.append(
                ReferenceTearReversal(
                    index: reversals.count,
                    span: ReferenceTearTimeSpan(
                        startTime: previous.span.endTime,
                        endTime: max(previous.span.endTime, travel.span.startTime)
                    ),
                    from: previous.direction,
                    to: travel.direction
                )
            )
        }
        if !reversals.isEmpty { reviewReasons.append(.directionReversal) }
        if segments.contains(where: { $0.reasons.contains(.contiguousSameDirectionRuns) }) {
            reviewReasons.append(.contiguousSameDirectionRuns)
        }

        let candidates = makeCandidates(
            segments: segments,
            faderIntervals: faderIntervals,
            faderClicks: faderClicks,
            configuration: configuration
        )
        if candidates.contains(where: { $0.proposedClassification == .unknown }) {
            reviewReasons.append(.holdCountOutsideSupportedRange)
        }
        if candidates.contains(where: { $0.countedTearHoldCount > 0 }) {
            reviewReasons.append(.tearCountIsPlatterOnly)
        }

        return ReferenceTearSegmentationReview(
            referenceTakeID: referenceTakeID,
            rawMovementEvents: movementEvents,
            segments: segments,
            reversals: reversals,
            faderIntervals: faderIntervals,
            faderClicks: faderClicks,
            reasons: ReferenceTearReviewReason.ordered(reviewReasons),
            candidates: candidates
        )
    }

    // MARK: Gesture grouping

    /// Maximal same-direction gestures over the derived segments.
    ///
    /// A gesture accumulates same-direction travel and the stationary
    /// intervals bounded by it. It ends at a reversal or the end of the
    /// stream, and a leading or trailing stationary interval is left outside
    /// it — the same shape `ScratchNotation.PlatterGesture` defines, so a
    /// reviewed candidate and a canonical gesture agree on what a tear is.
    private static func makeCandidates(
        segments: [ReferenceTearMotionSegment],
        faderIntervals: [CrossfaderStateInterval],
        faderClicks: [CrossfaderSemanticEvent],
        configuration: ReferenceTearReviewConfiguration
    ) -> [ReferenceTearCandidate] {
        var candidates: [ReferenceTearCandidate] = []
        var index = 0
        while index < segments.count {
            guard let direction = segments[index].state.travelDirection else {
                index += 1
                continue
            }
            var travelIndices = [index]
            var holdIndices: [Int] = []
            var cursor = index + 1
            var pendingHold: Int?
            while cursor < segments.count {
                let segment = segments[cursor]
                if segment.state.travelDirection == direction {
                    if let hold = pendingHold {
                        holdIndices.append(hold)
                        pendingHold = nil
                    }
                    travelIndices.append(cursor)
                    cursor += 1
                    continue
                }
                if segment.isStationary, pendingHold == nil,
                   !segment.reasons.contains(.directionReversal) {
                    pendingHold = cursor
                    cursor += 1
                    continue
                }
                // Two same-direction runs that abut: the marker records that
                // nothing is claimed between them, and the gesture continues
                // through it rather than being split by a non-event.
                if segment.reasons.contains(.contiguousSameDirectionRuns) {
                    cursor += 1
                    continue
                }
                break
            }
            // A trailing stationary interval is not bounded by same-direction
            // travel on both sides, so it is not a tear hold and is not part
            // of the gesture.
            let cited = (travelIndices + holdIndices).sorted()
            let span = ReferenceTearTimeSpan(
                startTime: segments[travelIndices[0]].span.startTime,
                endTime: segments[travelIndices.last!].span.endTime
            )
            let candidateID = "gesture-\(String(format: "%03d", candidates.count))"
            let boundaries = holdIndices.enumerated().map { ordinal, segmentIndex -> ReferenceTearBoundary in
                makeBoundary(
                    id: "\(candidateID)-hold-\(String(format: "%03d", ordinal))",
                    segment: segments[segmentIndex],
                    faderIntervals: faderIntervals,
                    faderClicks: faderClicks
                )
            }
            let confidences = travelIndices.compactMap { segments[$0].confidence }
            var proposalReasons: [ReferenceTearReviewReason] = boundaries.isEmpty
                ? []
                : [.boundedStationaryInterval, .tearCountIsPlatterOnly]
            proposalReasons += travelIndices.flatMap { segments[$0].reasons }
            proposalReasons += boundaries.flatMap { $0.proposal?.reasons ?? [] }
            let holdCount = boundaries.filter(\.countsAsTearHold).count
            let proposed = ReferenceTearClassification.proposed(tearHoldCount: holdCount)
            if proposed == .unknown { proposalReasons.append(.holdCountOutsideSupportedRange) }

            candidates.append(
                ReferenceTearCandidate(
                    id: candidateID,
                    gestureIndex: candidates.count,
                    direction: direction,
                    span: span,
                    motionSegmentIndices: cited,
                    proposedClassification: proposed,
                    proposedConfidence: confidences.min(),
                    proposalReasons: ReferenceTearReviewReason.ordered(proposalReasons),
                    boundaries: boundaries
                )
            )
            index = max(cursor, index + 1)
        }
        return candidates
    }

    /// One proposed boundary over a bounded stationary platter interval.
    ///
    /// The proposed kind is ALWAYS `.hold`. A coincident fader click is cited
    /// as evidence and flags the boundary ambiguous, but it never turns the
    /// proposal into a click: the tear hold count derives from the platter
    /// stream alone, and only the operator may say a pause was really fader
    /// work.
    private static func makeBoundary(
        id: String,
        segment: ReferenceTearMotionSegment,
        faderIntervals: [CrossfaderStateInterval],
        faderClicks: [CrossfaderSemanticEvent]
    ) -> ReferenceTearBoundary {
        var reasons = segment.reasons
        let clicks = faderClicks.filter {
            $0.endTime >= segment.span.startTime && $0.startTime <= segment.span.endTime
        }
        if !clicks.isEmpty { reasons.append(.coincidentFaderClick) }

        var states: Set<CrossfaderGateState> = []
        for interval in faderIntervals
        where min(interval.endTime, segment.span.endTime) > max(interval.startTime, segment.span.startTime) {
            states.insert(interval.state)
        }
        let reading: ReferenceTearFaderReading
        switch (states.count, states.first) {
        case (0, _): reading = .unobserved
        case (1, .some(.open)): reading = .open
        case (1, .some(.closed)): reading = .closed
        case (1, .some(.transitioning)): reading = .transitioning
        default: reading = .mixed
        }
        reasons.append(reading.reason)

        let ambiguous = !clicks.isEmpty
            || reasons.contains(.shortStationaryInterval)
            || reading == .unobserved
            || reading == .mixed
            || reading == .transitioning
        let quality: ReferenceTearEvidenceQuality = ambiguous ? .ambiguous : .clear
        let ordered = ReferenceTearReviewReason.ordered(reasons)

        return ReferenceTearBoundary(
            id: id,
            origin: .automatic,
            proposal: ReferenceTearBoundary.Proposal(
                span: segment.span,
                kind: .hold,
                evidenceQuality: quality,
                reasons: ordered
            ),
            span: segment.span,
            kind: .hold,
            evidenceQuality: quality
        )
    }

    private static func contiguityMarker(index: Int, at time: Double) -> ReferenceTearMotionSegment {
        ReferenceTearMotionSegment(
            index: index,
            span: ReferenceTearTimeSpan(startTime: time, endTime: time),
            state: .unknown,
            confidence: nil,
            movementEventIndex: nil,
            reasons: [.contiguousSameDirectionRuns]
        )
    }

    private static func notationDirection(_ raw: String) -> ScratchNotationDirection? {
        switch raw {
        case "forward": return .forward
        case "backward": return .backward
        default: return nil
        }
    }
}
