// ReferenceAuthoringSession — the state machine behind CXL's reference
// recording flow (steps 1–11 of the authoring workflow):
//
//   1  select technique          6  record a draft take
//   2  select pattern + BPM      7  review synchronized evidence
//   3  declare variant           8  review each repetition
//   4  verify inputs (preflight) 9  reject / retake / approve a repetition
//   5  calibrate the crossfader  10 explicitly publish
//                                11 only then is it available to training
//
// This is the COORDINATOR, not the recording hardware. Steps 6 and 7 do not
// touch AVFoundation, Core MIDI, or any camera/audio device directly — they
// call closures the host (macOS today) supplies, the same seam
// `MacCaptureEngine.startRoutineRecording`/`stopRoutineRecording` already
// exposes for ordinary capture. That is what keeps this file shared between
// iOS and macOS and testable with no hardware attached: every test below
// drives the session with fake recording/measurement results and asserts on
// the resulting state, lifecycle and validation report.
//
// Nothing in this file ever marks a take `.approvedCanonical` or `.published`
// except in direct, synchronous response to an explicit operator action
// (`approve`, `publish`). There is no timer, no automatic promotion, and
// auto-detected technique labels are read (`autoDetectedTechnique`) but never
// written back into `selectedTechnique` — advisory only, per the brief.

import Foundation

// MARK: - Recording seam

/// What the host must supply to actually record and measure a draft take.
///
/// Every closure is synchronous-from-the-session's-perspective (the host may
/// internally be async) and returns a `Result` so a hardware failure becomes a
/// named state, never a crash or a silent no-op.
struct ReferenceAuthoringRecordingHooks {
    /// Start recording; returns the take-relative reference the host will
    /// finalize on `stopRecording`.
    let startRecording: () -> Result<Void, ReferenceAuthoringError>
    /// Stop recording and hand back the raw evidence needed to build a
    /// `ReferenceTakeEvidence` for validation.
    let stopRecording: () -> Result<ReferenceRecordedTakeArtifacts, ReferenceAuthoringError>
    /// Live preflight snapshot, sampled on demand.
    let currentPreflightSnapshot: () -> ReferencePreflightSnapshot
    /// Feed one calibration reading into an in-progress sweep. The host polls
    /// this; the session owns the sweep state.
    ///
    /// Returns the reading TAGGED WITH THE MESSAGE IT CAME FROM
    /// (`observationSequence`), not a bare value. The host's live-MIDI cache
    /// keeps returning the same value long after the last message arrived, so
    /// a bare value cannot distinguish a held fader from a silent one — see
    /// `CrossfaderCalibrationObservation`.
    let latestCalibrationObservation: () -> CrossfaderCalibrationObservation?
    /// Re-read the Watch evidence for the take this bridge most recently
    /// finalized.
    ///
    /// The Watch's motion file can finish transferring AFTER macOS media
    /// finalization, so the value read at finalization is a snapshot, not an
    /// outcome. The host polls this until the state is terminal or the wait is
    /// bounded out. `nil` when there is no finalized take to ask about.
    let refreshWatchEvidence: () -> ReferenceWatchEvidenceRefresh?

    init(
        startRecording: @escaping () -> Result<Void, ReferenceAuthoringError>,
        stopRecording: @escaping () -> Result<ReferenceRecordedTakeArtifacts, ReferenceAuthoringError>,
        currentPreflightSnapshot: @escaping () -> ReferencePreflightSnapshot,
        latestCalibrationObservation: @escaping () -> CrossfaderCalibrationObservation?,
        refreshWatchEvidence: @escaping () -> ReferenceWatchEvidenceRefresh? = { nil }
    ) {
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.currentPreflightSnapshot = currentPreflightSnapshot
        self.latestCalibrationObservation = latestCalibrationObservation
        self.refreshWatchEvidence = refreshWatchEvidence
    }
}

/// One atomic re-read of a finalized sidecar after the Watch transfer has had
/// time to land. The evidence state and source binding must describe the same
/// bytes; returning them together prevents export from retaining the earlier
/// pre-transfer snapshot while displaying the later linked state.
struct ReferenceWatchEvidenceRefresh: Equatable, Sendable {
    let evidence: ReferenceWatchEvidence
    let sourceBinding: ReferenceTearEvidenceSourceBinding?
    let sourceState: ReferencePerTakeSourceState?

    init(
        evidence: ReferenceWatchEvidence,
        sourceBinding: ReferenceTearEvidenceSourceBinding? = nil,
        sourceState: ReferencePerTakeSourceState? = nil
    ) {
        self.evidence = evidence
        self.sourceBinding = sourceBinding
        self.sourceState = sourceState
    }
}

/// What the host measured after stopping a draft take. Everything a
/// `ReferenceValidator` needs, already measured — the session never reads a
/// file itself.
struct ReferenceRecordedTakeArtifacts: Equatable, Sendable {
    let tearEvidenceSourceBinding: ReferenceTearEvidenceSourceBinding?
    let rawSidecarURL: URL?
    let audio: ReferenceArtifactMeasurement
    let video: ReferenceArtifactMeasurement?
    let sidecar: ReferenceArtifactMeasurement
    let actualMediaFileName: String?
    let crossfaderRawSamples: [CrossfaderPositionSample]
    /// Every mixer packet preserved by the finalized sidecar. Package export
    /// writes this stream verbatim; derived fader/platter documents remain
    /// separate artifacts.
    let rawMixerMIDIEvents: [CaptureCore.RawMixerMIDIEvent]
    let observedCrossfaderAddress: CrossfaderMIDIAddress?
    let platterMovementEventCount: Int
    /// The recorded platter movement events themselves. Handed through
    /// untouched so tear-segmentation review can show the operator the motion
    /// rather than a count; see `ReferenceTakeEvidence.platterMovementEvents`.
    let platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    /// Derived from retained raw MIDI; never rewrites the sidecar or export.
    let platterEvidenceIntervals: [CaptureCore.PlatterEvidenceInterval]
    let recordedAt: Date
    /// The crossfader control state the ENGINE recorded at this take's
    /// media-start boundary, verbatim, or `nil` when none was written.
    let crossfaderTakeStartState: CaptureCore.CrossfaderTakeStartState?
    /// The identities that snapshot must have been observed under to be
    /// adopted. Supplied by the host, which is the only layer that knows the
    /// live device/session identity; the decision itself is made once, by
    /// `ReferenceCrossfaderTakeStart.correlate`.
    let crossfaderTakeStartCorrelation: ReferenceCrossfaderTakeStart.Correlation?
    /// What automatic detection believed the technique was, if it ran.
    /// ADVISORY ONLY — see the file header. `nil` when detection did not run
    /// or produced nothing.
    let autoDetectedTechnique: ReferenceTechnique?
    /// What the finalized take proves about its Watch motion, as a STATE.
    ///
    /// Read back from the WRITTEN take, never from the start handshake's
    /// reply: an acknowledgement says the Watch was told to record, the
    /// sidecar says what the take ended up carrying — and at finalization the
    /// motion file is often still transferring, which is neither "linked" nor
    /// "missing". See `ReferenceWatchEvidence`.
    let watchEvidence: ReferenceWatchEvidence
    /// Immutable timing observed from the existing capture clock and files.
    let witnessedTiming: ReferenceWitnessedTiming?
    let mediaTimeOrigin: ReferenceMediaTimeOrigin?
    let sourceState: ReferencePerTakeSourceState?

    init(
        audio: ReferenceArtifactMeasurement,
        video: ReferenceArtifactMeasurement?,
        sidecar: ReferenceArtifactMeasurement,
        actualMediaFileName: String?,
        crossfaderRawSamples: [CrossfaderPositionSample],
        rawMixerMIDIEvents: [CaptureCore.RawMixerMIDIEvent] = [],
        observedCrossfaderAddress: CrossfaderMIDIAddress?,
        platterMovementEventCount: Int,
        recordedAt: Date,
        autoDetectedTechnique: ReferenceTechnique?,
        watchEvidence: ReferenceWatchEvidence = .missing(
            syncState: CaptureWatchSyncState.notRequested.rawValue
        ),
        platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = [],
        platterEvidenceIntervals: [CaptureCore.PlatterEvidenceInterval] = [],
        crossfaderTakeStartState: CaptureCore.CrossfaderTakeStartState? = nil,
        crossfaderTakeStartCorrelation: ReferenceCrossfaderTakeStart.Correlation? = nil,
        tearEvidenceSourceBinding: ReferenceTearEvidenceSourceBinding? = nil,
        rawSidecarURL: URL? = nil,
        witnessedTiming: ReferenceWitnessedTiming? = nil,
        mediaTimeOrigin: ReferenceMediaTimeOrigin? = nil,
        sourceState: ReferencePerTakeSourceState? = nil
    ) {
        self.tearEvidenceSourceBinding = tearEvidenceSourceBinding
        self.rawSidecarURL = rawSidecarURL
        self.witnessedTiming = witnessedTiming
        self.mediaTimeOrigin = mediaTimeOrigin
        self.sourceState = sourceState
        self.audio = audio
        self.video = video
        self.sidecar = sidecar
        self.actualMediaFileName = actualMediaFileName
        self.crossfaderRawSamples = crossfaderRawSamples
        self.rawMixerMIDIEvents = rawMixerMIDIEvents
        self.observedCrossfaderAddress = observedCrossfaderAddress
        self.platterMovementEventCount = platterMovementEventCount
        self.platterMovementEvents = platterMovementEvents
        self.platterEvidenceIntervals = platterEvidenceIntervals
        self.recordedAt = recordedAt
        self.crossfaderTakeStartState = crossfaderTakeStartState
        self.crossfaderTakeStartCorrelation = crossfaderTakeStartCorrelation
        self.autoDetectedTechnique = autoDetectedTechnique
        self.watchEvidence = watchEvidence
    }
}

enum ReferenceAuthoringError: LocalizedError, Equatable {
    case preflightBlocked(summary: String)
    case calibrationIncomplete
    case recordingFailed(String)
    case noActiveRecording
    case stepOutOfOrder(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .preflightBlocked(let summary):
            return "Recording is blocked: \(summary)"
        case .calibrationIncomplete:
            return "Crossfader calibration has not been completed for this session."
        case .recordingFailed(let detail):
            return "Recording failed: \(detail)"
        case .noActiveRecording:
            return "No recording is in progress."
        case .stepOutOfOrder(let expected, let actual):
            return "Expected to be at step '\(expected)', but the session is at '\(actual)'."
        }
    }
}

// MARK: - Calibration provenance

/// How the session came by the calibration it is holding.
///
/// Three concepts stay distinct throughout this file and must not be
/// collapsed into one another:
///
/// - the LEARNED MIDI MAPPING (which channel/CC is the crossfader) —
///   `MacCaptureEngine`'s MIDI Learn owns it and it is never relearned here;
/// - the PERSISTED AUDIO RESPONSE of that fader (slope/curve) — separate
///   state, and deliberately not a source of reference geometry;
/// - the REFERENCE EVIDENCE CALIBRATION — the three measured positions in
///   `CrossfaderCalibration`, which is what this session needs.
///
/// A stored reference calibration for exactly the address, deck and open end
/// currently selected is already the answer. Re-sweeping it every time the
/// screen opens asks the operator to re-measure something ScratchLab already
/// measured, so it is adopted automatically. What is NEVER done is the
/// converse: a fader response curve that lacks three distinct measured
/// positions cannot be turned into a reference calibration, because the
/// missing measurement would have to be invented.
enum ReferenceCalibrationSource: Equatable, Sendable {
    /// Measured by a sweep in this session.
    case sweptInThisSession
    /// Adopted unchanged from `CrossfaderCalibrationStore`.
    case reusedPersisted(calibratedAt: Date)

    var isReused: Bool {
        if case .reusedPersisted = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .sweptInThisSession:
            return "Calibrated in this session"
        case .reusedPersisted(let calibratedAt):
            return "Reusing the saved calibration from "
                + ReferenceCalibrationSource.formatter.string(from: calibratedAt)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Why an existing stored calibration was not adopted, or that it was.
enum ReferenceCalibrationReuseOutcome: Equatable, Sendable {
    case adopted(CrossfaderCalibration)
    /// Already holding a calibration; nothing to adopt.
    case alreadyCalibrated
    /// No stored calibration for the live crossfader address.
    case noStoredCalibration
    /// Stored, but not for this device/address.
    case addressMismatch
    /// Stored, but measured for a different deck or open end.
    case configurationMismatch
    /// Stored, but it does not pass `validationIssues()`.
    case storedCalibrationUnusable
    /// No live crossfader address is known yet, so nothing can be matched.
    case noObservedAddress
    /// A sweep is in progress; an automatic adoption must not pre-empt it.
    case calibrationInProgress

    var adoptedCalibration: CrossfaderCalibration? {
        if case .adopted(let calibration) = self { return calibration }
        return nil
    }

    var operatorSummary: String {
        switch self {
        case .adopted(let calibration):
            return "Reusing the saved calibration for \(calibration.address.displayName)."
        case .alreadyCalibrated:
            return "This session already has a calibration."
        case .noStoredCalibration:
            return "No saved crossfader calibration exists for this address yet."
        case .addressMismatch:
            return "The saved calibration was measured on a different MIDI address."
        case .configurationMismatch:
            return "The saved calibration was measured for a different deck or open end."
        case .storedCalibrationUnusable:
            return "The saved calibration does not pass validation and was not reused."
        case .noObservedAddress:
            return "No crossfader address has been identified yet."
        case .calibrationInProgress:
            return "A calibration sweep is already in progress."
        }
    }
}

// MARK: - Session phase

/// Where the session is in steps 1–11. Distinct from `ReferenceLifecycleState`,
/// which describes ONE TAKE — a session moves through several takes.
enum ReferenceAuthoringPhase: Equatable, Sendable {
    case configuring
    case calibrating
    case readyToRecord
    case recording
    case reviewing(takeIndex: Int)
    case complete
}

// MARK: - Session

/// One CXL authoring session: configuration, zero or more recorded takes, and
/// the phase the operator is currently in.
///
/// A value type. The host (a SwiftUI view model) holds it in `@Published`
/// state and replaces it wholesale on every action, which is what makes every
/// transition here a plain, testable function from (session, action) to
/// (session, effect) with no hidden mutation.
struct ReferenceAuthoringSession: Equatable, Sendable {

    let authoringSessionID: String
    let operatorName: String
    var phase: ReferenceAuthoringPhase

    var selectedTechnique: ReferenceTechnique?
    var selectedPattern: ReferencePatternIdentity?
    var selectedBPM: Int?
    var selectedStartingDirection: ReferenceStartingPlatterDirection?
    var selectedFaderVariant: ReferenceFaderVariant?
    var selectedHandedness: CaptureSessionHandedness = .right
    var notes: String = ""
    /// Exact beat selected in Setup. Never inferred from a filename or BPM.
    private(set) var selectedBeatSpec: ReferenceBeatSpecBinding?
    /// Procedural backing selected before the first take, persisted through
    /// the routine session configuration in every sidecar and raw export.
    private(set) var selectedBeatEngineMode: BeatEngineMode = .boomBapTrainer
    private(set) var selectedCapturePurpose: ReferenceCapturePurpose = .canonicalReference
    /// Minted once before the first Record and retained through Next take.
    private(set) var captureIntent: ReferenceCaptureIntent?
    /// Each explicitly chosen new scratch gets a distinct immutable intent,
    /// while take numbering and the retained history span the whole session.
    private var setupSequence = 1

    var calibrationSweep: CrossfaderCalibrationSweep?
    var confirmedCalibration: CrossfaderCalibration?
    /// How `confirmedCalibration` was obtained. `nil` whenever there is none.
    private(set) var confirmedCalibrationSource: ReferenceCalibrationSource?
    /// The rig orientation requested by Setup, including a reuse attempt made
    /// before its first crossfader packet arrived.
    private var requestedCalibrationOpenEnd: CrossfaderOpenEnd?
    private var requestedCalibrationActiveDeck: CrossfaderActiveDeck?
    /// Frozen only on a successful start. Later polling/calibration changes
    /// can never reinterpret the take that is already recording.
    private struct RecordingFaderContext: Equatable, Sendable {
        let calibration: CrossfaderCalibration?
        let controllerIdentifier: String?
        let controllerName: String?
    }
    private var recordingFaderContext: RecordingFaderContext?
    /// Highest `observationSequence` already fed into the sweep. Everything at
    /// or below it is a re-read of a message the sweep has already counted, so
    /// it may keep the settle counter moving but must never count as proof the
    /// control is live. Monotonic for the whole session, never reset by a step
    /// or a retry.
    private(set) var lastIngestedCalibrationSequence: Int?

    var latestPreflight: ReferencePreflightResult?
    /// The raw snapshot `latestPreflight` was evaluated from. Retained so the
    /// panel can show live diagnostic detail (which MIDI addresses are
    /// actually carrying traffic, and how recently) that the evaluated checks
    /// deliberately summarise away.
    var latestPreflightSnapshot: ReferencePreflightSnapshot?

    /// Every take recorded in this session, in recording order. Includes
    /// rejected takes — nothing is removed from this list; rejection is a
    /// lifecycle state, not a deletion.
    private(set) var takes: [ReferenceAuthoringTake] = []

    init(authoringSessionID: String, operatorName: String) {
        self.authoringSessionID = authoringSessionID
        self.operatorName = operatorName
        self.phase = .configuring
    }

    var configurationIsComplete: Bool {
        selectedTechnique != nil
            && selectedPattern != nil
            && (selectedBPM.map { CaptureClickTrackDefaults.supportedBPMRange.contains($0) } ?? false)
            && selectedStartingDirection != nil
            && selectedFaderVariant != nil
    }

    var takeInReview: ReferenceAuthoringTake? {
        guard case .reviewing(let index) = phase, takes.indices.contains(index) else { return nil }
        return takes[index]
    }

    /// Reopen recorded evidence without invoking capture hooks or inventing a
    /// calibration from the currently connected rig. Validation is always fresh.
    init(reviewing draft: ReferenceSavedDraft, operatorName: String) throws {
        self.init(authoringSessionID: draft.evidence.metadata.authoringSessionID,
                  operatorName: operatorName)
        let metadata = draft.evidence.metadata
        guard metadata.lifecycleState == .draft || metadata.lifecycleState == .reviewed
                || metadata.lifecycleState == .approvedCanonical else {
            throw ReferenceAuthoringError.recordingFailed("This saved take cannot be reopened for review.")
        }
        selectedTechnique = metadata.technique
        selectedPattern = metadata.pattern
        selectedBPM = metadata.bpm
        selectedStartingDirection = metadata.startingPlatterDirection
        selectedFaderVariant = metadata.faderVariant
        selectedHandedness = metadata.handedness
        notes = metadata.notes
        selectedCapturePurpose = metadata.captureIntent?.purpose ?? .canonicalReference
        captureIntent = metadata.captureIntent
        selectedBeatSpec = metadata.captureIntent?.beatSpec
        confirmedCalibration = metadata.crossfaderCalibration
        var take = ReferenceAuthoringTake(
            evidence: draft.evidence, autoDetectedTechnique: draft.autoDetectedTechnique,
            latestValidation: ReferenceValidator.validate(draft.evidence),
            tearReview: draft.tearReview, tearEvidenceSourceBinding: draft.sourceBinding,
            rawSidecarURL: draft.sidecarURL)
        take.restoredTearProjection = draft.projection
        take.restoredTearPerformedLimitations = draft.performedLimitations
        take.preferenceMark = draft.evidence.boundaries.selectedRepetitionIndex == nil ? nil : draft.preferenceMark
        takes = [take]
        phase = metadata.lifecycleState == .approvedCanonical ? .complete : .reviewing(takeIndex: 0)
    }

    // MARK: Step 1–3: configuration

    mutating func selectTechnique(_ technique: ReferenceTechnique) {
        guard captureIntent == nil else { return }
        selectedTechnique = technique
        // A technique change invalidates any variant/pattern choice bound to
        // the previous technique's assumptions — the operator must reconfirm
        // fader variant explicitly rather than carry over a stale one.
        if technique != .babyScratch { selectedFaderVariant = nil }
    }

    mutating func selectPattern(_ pattern: ReferencePatternIdentity, bpm: Int) {
        guard captureIntent == nil else { return }
        selectedPattern = pattern
        selectedBPM = bpm
    }

    mutating func declareVariant(
        startingDirection: ReferenceStartingPlatterDirection,
        faderVariant: ReferenceFaderVariant,
        handedness: CaptureSessionHandedness
    ) {
        guard captureIntent == nil else { return }
        selectedStartingDirection = startingDirection
        selectedFaderVariant = faderVariant
        selectedHandedness = handedness
    }

    mutating func bindBeatSpec(_ beatSpec: ReferenceBeatSpecBinding?) {
        guard captureIntent == nil else { return }
        selectedBeatSpec = beatSpec
    }

    mutating func selectBeatEngineMode(_ mode: BeatEngineMode) {
        guard captureIntent == nil, mode != .silent else { return }
        selectedBeatEngineMode = mode
    }

    mutating func selectCapturePurpose(_ purpose: ReferenceCapturePurpose) {
        guard captureIntent == nil else { return }
        selectedCapturePurpose = purpose
        if purpose == .movementCheck { selectedBeatSpec = nil }
    }

    /// Freeze validated Setup before the bridge reserves media/Watch identity.
    /// Repeated calls return the same value and verify mutable form state has
    /// not drifted away from it.
    @discardableResult
    mutating func prepareCaptureIntentForRecording() throws -> ReferenceCaptureIntent {
        guard let technique = selectedTechnique,
              let pattern = selectedPattern,
              let bpm = selectedBPM,
              let direction = selectedStartingDirection,
              let fader = selectedFaderVariant,
              configurationIsComplete else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "complete Setup", actual: "\(phase)")
        }
        let variantID = [
            technique.id,
            pattern.id,
            direction.rawValue,
            fader.rawValue,
            selectedHandedness.rawValue,
        ].joined(separator: ".")
        let proposed = ReferenceCaptureIntent(
            id: setupSequence == 1
                ? "\(authoringSessionID).intent.v1"
                : "\(authoringSessionID).setup-\(setupSequence).intent.v1",
            parentTechniqueID: technique.id,
            variantID: variantID,
            recipeID: pattern.id,
            startingPlatterDirection: direction,
            faderForm: fader,
            bpm: bpm,
            beatsPerCycle: pattern.phraseBeats,
            plan: ReferenceCapturePlan(
                countInBars: selectedCapturePurpose == .movementCheck ? 0 : ReferenceTakeMetadata.defaultCountInBars,
                repetitionCount: selectedCapturePurpose == .movementCheck ? 0 : ReferenceTakeMetadata.defaultRepetitionCount,
                tailBars: selectedCapturePurpose == .movementCheck ? 0 : ReferenceTakeMetadata.defaultTailBars
            ),
            beatSpec: selectedCapturePurpose == .movementCheck ? nil : selectedBeatSpec,
            purpose: selectedCapturePurpose
        )
        if let captureIntent {
            guard captureIntent == proposed else {
                throw ReferenceAuthoringError.recordingFailed("Setup no longer matches the immutable capture intent.")
            }
            return captureIntent
        }
        let issues = ReferenceCaptureIntentValidator.issues(
            intent: proposed,
            requireBeatSpec: false
        )
        guard issues.isEmpty else {
            throw ReferenceAuthoringError.recordingFailed("Capture intent is invalid: \(issues)")
        }
        captureIntent = proposed
        return proposed
    }

    // MARK: Step 4–5: preflight + calibration

    mutating func refreshPreflight(using hooks: ReferenceAuthoringRecordingHooks) {
        guard let technique = selectedTechnique else { return }
        let snapshot = hooks.currentPreflightSnapshot()
        latestPreflightSnapshot = snapshot
        latestPreflight = ReferenceCapturePreflight.evaluate(
            snapshot: snapshot,
            technique: technique
        )
    }

    mutating func beginCalibration(
        address: CrossfaderMIDIAddress,
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck
    ) {
        requestedCalibrationOpenEnd = openEnd
        requestedCalibrationActiveDeck = activeDeck
        calibrationSweep = CrossfaderCalibrationSweep(
            address: address,
            openEnd: openEnd,
            activeDeck: activeDeck
        )
        // The sweep opens UNARMED: it shows the full-left instruction and
        // collects nothing until the operator presses Capture. Whatever the
        // address last reported before that is a stale reading by definition.
        lastIngestedCalibrationSequence = nil
        // An explicit recalibration supersedes an adopted calibration: the
        // operator has said they want to measure it again.
        confirmedCalibration = nil
        confirmedCalibrationSource = nil
        phase = .calibrating
    }

    /// Feed one live reading into the sweep. Call repeatedly while polling.
    ///
    /// A reading whose `observationSequence` is not greater than the last one
    /// ingested is a re-read of an already-counted message, and is passed to
    /// the sweep as NOT fresh: it can still keep a stable hold stable, but it
    /// cannot help a step reach the liveness threshold. That is what stops a
    /// silent controller from settling all three positions.
    mutating func ingestCalibrationObservation(
        _ observation: CrossfaderCalibrationObservation,
        now: Date = Date()
    ) {
        guard let sweep = calibrationSweep else { return }
        lastIngestedCalibrationSequence = observation.observationSequence
        // The sweep itself owns the arm boundary and the freshness rule: an
        // unarmed stage ignores this entirely, and an armed one accepts only
        // observations newer than the moment it was armed.
        calibrationSweep = sweep.ingesting(
            rawValue: observation.rawValue,
            observationSequence: observation.observationSequence,
            now: now
        )
        if let calibration = calibrationSweep?.state.calibration, calibration.isUsable {
            confirmedCalibration = calibration
            confirmedCalibrationSource = .sweptInThisSession
        }
    }

    /// Arm the current calibration stage — the operator has read the
    /// instruction and presented the position.
    ///
    /// Anchored to the address's CURRENT observation sequence, so only
    /// readings that arrive after this call can settle the stage. A stage
    /// never arms itself; this is the only way in.
    mutating func armCalibrationCapture(using hooks: ReferenceAuthoringRecordingHooks) {
        guard let sweep = calibrationSweep, sweep.state.isAwaitingArm else { return }
        let boundary = hooks.latestCalibrationObservation()?.observationSequence ?? 0
        calibrationSweep = sweep.arming(atObservationSequence: boundary)
    }

    /// `true` when the current stage is showing its instruction and waiting
    /// for an explicit capture action.
    var calibrationIsAwaitingArm: Bool {
        calibrationSweep?.state.isAwaitingArm ?? false
    }

    mutating func retryCalibrationStep() {
        calibrationSweep = calibrationSweep?.retryingCurrentStep()
    }

    /// Adopt an already-stored reference calibration for the crossfader the
    /// operator is currently pointed at, without asking for another sweep.
    ///
    /// Adopts ONLY on an exact match: same device identifier, same channel and
    /// CC, same active deck, same open end, and the stored calibration passes
    /// its own `validationIssues()`. Anything less is refused with a named
    /// reason — a calibration measured for the other deck, or for the other
    /// open end, describes a different physical arrangement and applying it
    /// would silently mis-read every fader sample in the take.
    ///
    /// Nothing is fabricated here. The store is the only source; a fader
    /// response curve that does not carry three distinct measured positions is
    /// not a reference calibration and is never promoted into one.
    ///
    /// Advances to `readyToRecord` only when the configuration is complete and
    /// the session is not already past that point.
    @discardableResult
    mutating func adoptPersistedCalibrationIfExact(
        store: CrossfaderCalibrationStore,
        openEnd: CrossfaderOpenEnd,
        activeDeck: CrossfaderActiveDeck,
        address: CrossfaderMIDIAddress?
    ) -> ReferenceCalibrationReuseOutcome {
        requestedCalibrationOpenEnd = openEnd
        requestedCalibrationActiveDeck = activeDeck
        guard confirmedCalibration == nil else { return .alreadyCalibrated }
        guard calibrationSweep == nil else { return .calibrationInProgress }
        guard let address else { return .noObservedAddress }
        guard let stored = store.calibration(
            deviceIdentifier: address.deviceIdentifier,
            channel: address.channel,
            controller: address.controller
        ) else { return .noStoredCalibration }
        guard stored.address.matches(
            deviceIdentifier: address.deviceIdentifier,
            channel: address.channel,
            controller: address.controller
        ) else { return .addressMismatch }
        guard stored.openEnd == openEnd, stored.activeDeck == activeDeck else {
            return .configurationMismatch
        }
        guard stored.isUsable else { return .storedCalibrationUnusable }

        confirmedCalibration = stored
        confirmedCalibrationSource = .reusedPersisted(calibratedAt: stored.calibratedAt)
        if configurationIsComplete, phase == .configuring || phase == .calibrating {
            phase = .readyToRecord
        }
        return .adopted(stored)
    }

    /// Persist the completed sweep and advance to `readyToRecord`.
    ///
    /// Throws when the sweep has not produced a usable calibration — a
    /// half-finished or invalid sweep can never silently become "ready".
    mutating func commitCalibration(
        store: CrossfaderCalibrationStore,
        now: Date = Date()
    ) throws {
        guard let calibration = confirmedCalibration, calibration.isUsable else {
            throw ReferenceAuthoringError.calibrationIncomplete
        }
        try store.save(calibration, now: now)
        // The sweep is a DRAFT, and it is now spent. Clearing it is what makes
        // the panel truthful: while a completed sweep is still held, the UI
        // keeps asking the operator to "commit it before recording" for a
        // calibration that is already saved. It also closes a real hazard —
        // `ingestCalibrationObservation` keeps feeding a held sweep, so
        // further fader motion could overwrite `confirmedCalibration` after
        // the commit. Recalibration stays explicit: only `beginCalibration`
        // mints a new sweep.
        calibrationSweep = nil
        phase = .readyToRecord
    }

    // MARK: Step 6: record a draft take

    mutating func beginRecording(
        using hooks: ReferenceAuthoringRecordingHooks
    ) -> Result<Void, ReferenceAuthoringError> {
        guard configurationIsComplete else {
            return .failure(.stepOutOfOrder(expected: "configuring", actual: "\(phase)"))
        }
        do {
            _ = try prepareCaptureIntentForRecording()
        } catch let error as ReferenceAuthoringError {
            return .failure(error)
        } catch {
            return .failure(.recordingFailed(error.localizedDescription))
        }
        // Deliberately NOT gated on `confirmedCalibration`.
        //
        // Capture eligibility and canonical-reference eligibility are separate
        // gates. A missing or unusable reference calibration costs the take its
        // fader evidence — reported as explicit `unknown` and, through
        // `ReferenceValidator`, as a blocking `.crossfaderCalibrationMissing`
        // finding — but it must never cost the operator the RAW capture. The
        // take is still recorded, finalized, retained and exportable; it simply
        // cannot be approved as canonical. `approvalBlockReason` stays
        // fail-closed and is where that refusal lives.
        let snapshot = hooks.currentPreflightSnapshot()
        latestPreflightSnapshot = snapshot
        let preflight = ReferenceCapturePreflight.evaluate(
            snapshot: snapshot,
            technique: selectedTechnique!
        )
        latestPreflight = preflight
        guard !preflight.blocksRecording else {
            return .failure(.preflightBlocked(summary: preflight.blockingSummary ?? "Required input missing."))
        }
        let faderContext = faderContextForRecording(snapshot: snapshot)
        switch hooks.startRecording() {
        case .success:
            recordingFaderContext = faderContext
            if let calibration = faderContext.calibration, calibration != confirmedCalibration {
                confirmedCalibration = calibration
                confirmedCalibrationSource = .reusedPersisted(calibratedAt: calibration.calibratedAt)
            }
            phase = .recording
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private func faderContextForRecording(snapshot: ReferencePreflightSnapshot) -> RecordingFaderContext {
        let openEnd = requestedCalibrationOpenEnd ?? confirmedCalibration?.openEnd
        let activeDeck = requestedCalibrationActiveDeck ?? confirmedCalibration?.activeDeck
        let calibration: CrossfaderCalibration?
        if let candidate = snapshot.calibration,
           candidate.isUsable,
           candidate.openEnd == openEnd, candidate.activeDeck == activeDeck,
           let sourceID = snapshot.controllerIdentifier, !sourceID.isEmpty,
           let address = snapshot.observedCrossfaderAddress,
           address.deviceIdentifier == sourceID,
           candidate.address.matches(deviceIdentifier: sourceID,
                                     channel: address.channel, controller: address.controller) {
            calibration = candidate
        } else {
            calibration = nil
        }
        return RecordingFaderContext(calibration: calibration,
            controllerIdentifier: snapshot.controllerIdentifier, controllerName: snapshot.controllerName)
    }

    /// Stop recording, build evidence, validate it, and move into review.
    ///
    /// `expectation` defaults to the technique's provisional default — see
    /// `ReferenceFaderExpectation`. Pass a `.confirmed(by:at:)` expectation
    /// once CXL has signed off the technique's fader shape; until then,
    /// technique-shape findings are advisory and never block this step.
    mutating func finishRecording(
        using hooks: ReferenceAuthoringRecordingHooks,
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) -> Result<ReferenceValidationReport, ReferenceAuthoringError> {
        guard phase == .recording else {
            return .failure(.noActiveRecording)
        }
        guard let technique = selectedTechnique,
              let pattern = selectedPattern,
              let bpm = selectedBPM,
              let direction = selectedStartingDirection,
              let faderVariant = selectedFaderVariant else {
            return .failure(.stepOutOfOrder(expected: "configured", actual: "\(phase)"))
        }
        // May legitimately be nil. Only this take's frozen start context may
        // supply calibration; a later live reading cannot repair an old take.
        let faderContext = recordingFaderContext

        let artifacts: ReferenceRecordedTakeArtifacts
        switch hooks.stopRecording() {
        case .success(let value):
            artifacts = value
        case .failure(let error):
            return .failure(error)
        }

        let recordedSourceID = artifacts.crossfaderTakeStartCorrelation?.midiSourceID
            ?? artifacts.observedCrossfaderAddress?.deviceIdentifier
        let sourceMatchesStart = recordedSourceID == nil
            || recordedSourceID == faderContext?.controllerIdentifier
        let observedAddressMatchesCalibration = artifacts.observedCrossfaderAddress.map { address in
            faderContext?.calibration?.address.matches(deviceIdentifier: address.deviceIdentifier,
                channel: address.channel, controller: address.controller) ?? true
        } ?? true
        let calibration = sourceMatchesStart && observedAddressMatchesCalibration
            ? faderContext?.calibration : nil
        let recordedControllerName = artifacts.observedCrossfaderAddress?.deviceName
            ?? (sourceMatchesStart ? faderContext?.controllerName : nil)
        let recordedControllerIdentifier = artifacts.observedCrossfaderAddress?.deviceIdentifier
            ?? recordedSourceID ?? faderContext?.controllerIdentifier

        let takeNumber = takes.count + 1
        let metadata = ReferenceTakeMetadata(
            referenceTakeID: "\(authoringSessionID)-take-\(String(format: "%03d", takeNumber))",
            authoringSessionID: authoringSessionID,
            takeNumber: takeNumber,
            operatorName: operatorName,
            technique: technique,
            pattern: pattern,
            bpm: bpm,
            repetitionCount: captureIntent?.plan.repetitionCount ?? ReferenceTakeMetadata.defaultRepetitionCount,
            countInBars: captureIntent?.plan.countInBars ?? ReferenceTakeMetadata.defaultCountInBars,
            tailBars: captureIntent?.plan.tailBars ?? ReferenceTakeMetadata.defaultTailBars,
            startingPlatterDirection: direction,
            faderVariant: faderVariant,
            handedness: selectedHandedness,
            notes: notes,
            captureIntent: captureIntent,
            witnessedTiming: artifacts.witnessedTiming,
            mediaTimeOrigin: artifacts.mediaTimeOrigin,
            sourceState: artifacts.sourceState,
            referenceVersion: takeNumber,
            crossfaderCalibration: calibration,
            deviceInfo: ReferenceDeviceInfo(
                platform: "macOS",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                // Falls back to the address the take actually OBSERVED traffic
                // on when no calibration is in force, so an uncalibrated take
                // still names its controller truthfully instead of naming none.
                controllerName: calibration?.address.deviceName ?? recordedControllerName ?? "",
                controllerIdentifier: calibration?.address.deviceIdentifier ?? recordedControllerIdentifier ?? "",
                audioDeviceName: nil,
                videoDeviceName: nil,
                // Kept in step with `evidence.watchEvidence` and set from
                // nothing else — never from the start handshake, never
                // hardcoded, and never true while a transfer is still pending.
                watchLinked: artifacts.watchEvidence.isLinked
            ),
            recordedAt: artifacts.recordedAt,
            lifecycleState: .draft
        )

        // A parked fader emits nothing. The engine's take-start control state
        // is what lets such a take prove the position it genuinely knew —
        // provided the snapshot correlates with THIS take, this device
        // connection, this mapped address and this calibration. The recorded
        // samples themselves are handed to the evidence untouched; the
        // baseline exists only in the derivation input, so no pre-take packet
        // is ever persisted as an in-take measurement.
        let takeStartOutcome: ReferenceCrossfaderTakeStart.Outcome
        if let correlation = artifacts.crossfaderTakeStartCorrelation {
            takeStartOutcome = ReferenceCrossfaderTakeStart.correlate(
                artifacts.crossfaderTakeStartState,
                against: correlation,
                calibration: calibration,
                recordedSamples: artifacts.crossfaderRawSamples
            )
        } else {
            takeStartOutcome = .rejected(.notRecorded)
        }
        let derivation = calibration.flatMap { calibration in
            guard let sampleDerivation = CrossfaderStateDeriver.derive(
                rawEvents: ReferenceCrossfaderTakeStart.derivationInput(
                    recordedSamples: artifacts.crossfaderRawSamples,
                    outcome: takeStartOutcome
                ),
                calibration: calibration,
                response: artifacts.crossfaderTakeStartState?.crossfaderCurveResponse
                    ?? FaderCurveResponse(
                        zeroAt: 0,
                        oneAt: MIDIFaderCurveConstants.sharpScratchCutInWidth,
                        shape: .linear
                    )
            ) else { return nil as CrossfaderDerivation? }
            let measuredDuration: Double?
            if let frames = artifacts.audio.frameCount, frames > 0,
               let rate = artifacts.audio.sampleRate, rate.isFinite, rate > 0 {
                measuredDuration = Double(frames) / rate
            } else {
                measuredDuration = nil
            }
            return ReferenceCrossfaderTakeStart.applyingParkedHold(
                to: sampleDerivation, state: artifacts.crossfaderTakeStartState,
                outcome: takeStartOutcome, recordedSamples: artifacts.crossfaderRawSamples,
                calibration: calibration, measuredMediaDuration: measuredDuration
            )
        }

        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        // No repetition is pre-selected — step 9 is an explicit operator
        // action, never a default.
        boundaries.selectedRepetitionIndex = nil

        let evidence = ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: boundaries,
            audio: artifacts.audio,
            video: artifacts.video,
            sidecar: artifacts.sidecar,
            actualMediaFileName: artifacts.actualMediaFileName,
            crossfaderRawSamples: artifacts.crossfaderRawSamples,
            rawMixerMIDIEvents: artifacts.rawMixerMIDIEvents,
            observedCrossfaderAddress: artifacts.observedCrossfaderAddress,
            platterMovementEventCount: artifacts.platterMovementEventCount,
            derivation: derivation,
            watchEvidence: artifacts.watchEvidence,
            platterMovementEvents: artifacts.platterMovementEvents,
            platterEvidenceIntervals: artifacts.platterEvidenceIntervals,
            crossfaderTakeStartState: artifacts.crossfaderTakeStartState,
            crossfaderTakeStartOutcome: takeStartOutcome
        )

        let report = ReferenceValidator.validate(evidence, expectation: expectation, now: now)

        let take = ReferenceAuthoringTake(
            evidence: evidence,
            autoDetectedTechnique: artifacts.autoDetectedTechnique,
            latestValidation: report,
            // The automatic tear pass runs once, here, from the take's own
            // recorded evidence. It proposes; it approves nothing. See
            // `ReferenceTearSegmentationReview`.
            tearReview: ReferenceTearSegmentationReviewBuilder.build(for: evidence),
            tearEvidenceSourceBinding: artifacts.tearEvidenceSourceBinding,
            rawSidecarURL: artifacts.rawSidecarURL
        )
        takes.append(take)
        let index = takes.count - 1
        phase = .reviewing(takeIndex: index)
        return .success(report)
    }

    // MARK: Step 8–9: per-repetition review and decision

    /// Move a repetition boundary. Clamped to keep it non-inverted; every
    /// other check is left to `ReferenceValidator` on the next validation.
    mutating func adjustRepetitionBoundary(
        repetitionIndex: Int,
        startBeat: Double,
        endBeat: Double
    ) {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return }
        guard let position = takes[takeIndex].evidence.boundaries.repetitions.firstIndex(where: {
            $0.index == repetitionIndex
        }) else { return }
        var boundaries = takes[takeIndex].evidence.boundaries
        boundaries.repetitions[position].startBeat = min(startBeat, endBeat)
        boundaries.repetitions[position].endBeat = max(startBeat, endBeat)
        takes[takeIndex].updateBoundaries(boundaries)
    }

    /// Marks CXL's optional preferred repetition (zero-based `index`; the
    /// operator sees `index + 1`). This is the same single selection approval
    /// reads, but marking never approves, publishes, trims or changes
    /// lifecycle. Unrecorded indices and movement checks are refused.
    @discardableResult
    mutating func markPreferredRepetition(_ repetitionIndex: Int, now: Date = Date()) -> Bool {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return false }
        let take = takes[takeIndex]
        guard take.evidence.metadata.captureIntent?.isMovementCheck != true,
              take.evidence.boundaries.repetitions.contains(where: { $0.index == repetitionIndex }) else { return false }
        var boundaries = take.evidence.boundaries
        boundaries.selectedRepetitionIndex = repetitionIndex
        takes[takeIndex].updateBoundaries(boundaries)
        takes[takeIndex].preferenceMark = ReferenceRepetitionPreferenceMark(markedBy: operatorName, markedAt: now)
        return true
    }

    mutating func selectRepetitionForApproval(_ repetitionIndex: Int) {
        markPreferredRepetition(repetitionIndex)
    }

    /// Removes the optional preference before approval. The recording and all
    /// repetitions are unchanged; approval simply requires a new choice.
    @discardableResult
    mutating func clearPreferredRepetition() -> Bool {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return false }
        var boundaries = takes[takeIndex].evidence.boundaries
        boundaries.selectedRepetitionIndex = nil
        takes[takeIndex].updateBoundaries(boundaries)
        takes[takeIndex].preferenceMark = nil
        return true
    }

    /// Attach a newly-observed Watch evidence state to the take in review.
    ///
    /// The Watch's motion file can land after macOS media finalization, so the
    /// take's evidence has to be able to move from
    /// `acknowledgedTransferPending` to `linked` without re-recording.
    /// `metadata.deviceInfo.watchLinked` is derived from the new state here
    /// and nowhere else, and validation is re-run so approval eligibility
    /// updates with it.
    ///
    /// Ignores an update that would move a take BACKWARDS out of `linked`:
    /// once matching evidence has landed it is not un-landed by a later poll.
    mutating func updateWatchEvidenceForTakeInReview(
        _ watchEvidence: ReferenceWatchEvidence,
        refreshedSourceBinding: ReferenceTearEvidenceSourceBinding? = nil,
        sourceState: ReferencePerTakeSourceState? = nil,
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return }
        guard !takes[takeIndex].evidence.watchEvidence.isLinked || watchEvidence.isLinked else { return }
        // A reached timeout or failure is never reopened as pending; only a
        // verified matching file (checked below) may resolve it.
        guard !(takes[takeIndex].evidence.watchEvidence.isTerminal && watchEvidence.isTransferPending) else { return }
        guard takes[takeIndex].acceptsWatchEvidence(watchEvidence, sourceState: sourceState) else { return }
        if case .linked(let identity, _, _) = sourceState, let refreshedSourceBinding {
            guard refreshedSourceBinding.capturedSessionID == identity.sessionID,
                  refreshedSourceBinding.capturedTakeID == identity.takeID,
                  refreshedSourceBinding.capturedTakeNumber == identity.takeNumber else { return }
            if let existing = takes[takeIndex].tearEvidenceSourceBinding,
               existing.rawSidecarFileName != refreshedSourceBinding.rawSidecarFileName { return }
        }
        takes[takeIndex].applyWatchEvidence(watchEvidence, sourceState: sourceState)
        if watchEvidence.isLinked,
           let refreshedSourceBinding,
           let existing = takes[takeIndex].tearEvidenceSourceBinding,
           existing.capturedSessionID == refreshedSourceBinding.capturedSessionID,
           existing.capturedTakeID == refreshedSourceBinding.capturedTakeID,
           existing.capturedTakeNumber == refreshedSourceBinding.capturedTakeNumber,
           existing.rawSidecarFileName == refreshedSourceBinding.rawSidecarFileName {
            takes[takeIndex].tearEvidenceSourceBinding = refreshedSourceBinding
        }
        revalidateTakeInReview(expectation: expectation, now: now)
    }

    // MARK: Step 8: tear segmentation review
    //
    // Inspection and correction of the take's tear segmentation. EVERY
    // mutator below is additive provenance over the automatic proposal: it
    // records who changed what, when and why, it never rewrites the proposal
    // or the raw movement events, and it never advances a lifecycle state,
    // writes a review decision, or affects `approvalBlockReason`. A fully
    // corrected take is exactly as un-approved as an untouched one.

    /// The tear review for the take currently in review, or `nil` when no
    /// take is in review.
    var tearReviewForTakeInReview: ReferenceTearSegmentationReview? {
        takeInReview?.tearReview
    }

    /// Record the operator's reading of one candidate.
    ///
    /// The machine's proposal is retained beside it; a reading is never
    /// "corrected away".
    @discardableResult
    mutating func classifyTearCandidate(
        _ candidateID: String,
        as classification: ReferenceTearClassification,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let correction = tearCorrection(
            reason: "classified_\(candidateID)_as_\(classification.rawValue)",
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.classifyCandidate(id: candidateID, as: classification, correction: correction)
        }
    }

    /// Add a tear boundary the automatic pass did not propose.
    ///
    /// Refuses a non-finite, inverted or zero-width span. Adding never
    /// touches the raw movement events, and removing one later only flags it.
    @discardableResult
    mutating func addTearBoundary(
        toCandidate candidateID: String,
        startTime: Double,
        endTime: Double,
        kind: ReferenceTearBoundaryKind = .hold,
        evidenceQuality: ReferenceTearEvidenceQuality = .clear,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let span = ReferenceTearTimeSpan(
            startTime: min(startTime, endTime),
            endTime: max(startTime, endTime)
        )
        let correction = tearCorrection(
            reason: "added_boundary_to_\(candidateID)",
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.addBoundary(
                toCandidate: candidateID,
                span: span,
                kind: kind,
                evidenceQuality: evidenceQuality,
                correction: correction
            ) != nil
        }
    }

    /// Move an existing boundary. The proposal it started from is retained,
    /// so the move stays visible as a disagreement.
    @discardableResult
    mutating func moveTearBoundary(
        inCandidate candidateID: String,
        boundaryID: String,
        startTime: Double,
        endTime: Double,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let span = ReferenceTearTimeSpan(
            startTime: min(startTime, endTime),
            endTime: max(startTime, endTime)
        )
        let correction = tearCorrection(
            reason: "moved_boundary_\(boundaryID)",
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.moveBoundary(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: span,
                correction: correction
            )
        }
    }

    /// Say whether a boundary is a platter hold or fader work. Naming it a
    /// click stops it counting toward the tear hold count without deleting
    /// anything.
    @discardableResult
    mutating func setTearBoundaryKind(
        inCandidate candidateID: String,
        boundaryID: String,
        to kind: ReferenceTearBoundaryKind,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let correction = tearCorrection(
            reason: "boundary_\(boundaryID)_kind_\(kind.rawValue)",
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.setBoundaryKind(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: kind,
                correction: correction
            )
        }
    }

    /// Mark a boundary's evidence clear or ambiguous. Ambiguity is recorded,
    /// not resolved: the boundary keeps counting exactly as its kind says.
    @discardableResult
    mutating func setTearBoundaryEvidenceQuality(
        inCandidate candidateID: String,
        boundaryID: String,
        to quality: ReferenceTearEvidenceQuality,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let correction = tearCorrection(
            reason: "boundary_\(boundaryID)_evidence_\(quality.rawValue)",
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.setBoundaryEvidenceQuality(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: quality,
                correction: correction
            )
        }
    }

    /// Strike a boundary out, or restore it. NOTHING is deleted: the record,
    /// its automatic proposal and its correction history all survive, and the
    /// take's raw movement events are untouched either way.
    @discardableResult
    mutating func setTearBoundaryRemoved(
        inCandidate candidateID: String,
        boundaryID: String,
        removed: Bool,
        notes: String = "",
        now: Date = Date()
    ) -> Bool {
        let correction = tearCorrection(
            reason: "boundary_\(boundaryID)_" + (removed ? "removed" : "restored"),
            notes: notes,
            now: now
        )
        return mutateTearReview { review in
            review.setBoundaryRemoved(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                removed: removed,
                correction: correction
            )
        }
    }

    @discardableResult
    mutating func setTearReviewNotes(_ notes: String, now: Date = Date()) -> Bool {
        let correction = tearCorrection(reason: "review_notes", notes: notes, now: now)
        return mutateTearReview(invalidatesProjection: false) { review in
            review.setNotes(notes, correction: correction)
            return true
        }
    }

    private func tearCorrection(reason: String, notes: String, now: Date) -> ReferenceTearCorrection {
        ReferenceTearCorrection(
            correctedBy: operatorName,
            correctedAt: now,
            notes: notes,
            reason: reason
        )
    }

    /// The single seam every tear correction goes through. Guarded on
    /// `.reviewing` exactly like the repetition-boundary mutators, so a
    /// correction can never be applied to a take that is not in review.
    private mutating func mutateTearReview(
        invalidatesProjection: Bool = true,
        _ body: (inout ReferenceTearSegmentationReview) -> Bool
    ) -> Bool {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return false }
        var review = takes[takeIndex].tearReview
        let changed = body(&review)
        guard changed else { return false }
        takes[takeIndex].tearReview = review
        if invalidatesProjection {
            takes[takeIndex].restoredTearProjection = nil
            takes[takeIndex].restoredTearPerformedLimitations = nil
        }
        return true
    }

    /// Restores evidence only into its already corresponding take. Capture,
    /// validation, lifecycle and approval fields are deliberately not assigned.
    mutating func restoreTearEvidence(_ data: Data?) throws -> ReferenceTearEvidenceCodec.ReadResult {
        guard case .reviewing(let index) = phase, takes.indices.contains(index) else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "reviewing", actual: "\(phase)")
        }
        guard let binding = takes[index].tearEvidenceSourceBinding else {
            if data == nil { return .notAnalysed }
            throw ReferenceAuthoringError.recordingFailed("This take has no finalized sidecar binding for tear evidence.")
        }
        let result = try ReferenceTearEvidenceCodec.decode(
            data, expectedSource: binding, expectedReferenceTakeID: takes[index].id
        )
        if case .restored(let document) = result {
            takes[index].tearReview = document.review
            takes[index].restoredTearProjection = document.projection
            takes[index].restoredTearPerformedLimitations = document.performedLimitations
        }
        return result
    }

    /// Re-run validation against the take's current boundaries. Call after
    /// any adjustment, before approving.
    mutating func revalidateTakeInReview(
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else { return }
        let report = ReferenceValidator.validate(
            takes[takeIndex].evidence,
            expectation: expectation,
            now: now
        )
        takes[takeIndex].latestValidation = report
    }

    /// Reject the take in review. Terminal — see `ReferenceLifecycleState`.
    mutating func rejectTakeInReview(notes: String, now: Date = Date()) throws {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "reviewing", actual: "\(phase)")
        }
        // The Watch refresh targets the take in review. Leaving review while
        // its transfer is pending would strand that evidence and its outcome.
        if let reason = pendingTakeEvidenceBlockReason(for: takes[takeIndex]) {
            throw ReferenceAuthoringError.recordingFailed(reason)
        }
        try takes[takeIndex].transition(to: .rejected)
        takes[takeIndex].evidence.metadata.reviewDecision = ReferenceReviewDecision(
            outcome: .rejected,
            decidedBy: operatorName,
            decidedAt: now,
            notes: notes,
            selectedRepetitionIndex: takes[takeIndex].evidence.boundaries.selectedRepetitionIndex
        )
        phase = .readyToRecord
    }

    /// Repeat the existing setup, retaining the prior take without changing
    /// its review decision. Serial callers should use the identity-checked
    /// overload so an action queued for an older take cannot move a newer one.
    mutating func retake() {
        guard let takeID = latestRecordedTake?.id else { return }
        try? retake(afterTakeID: takeID)
    }

    func retakeBlockReason() -> String? {
        if let reason = finalizedTakeContinuationBlockReason() { return reason }
        guard configurationIsComplete else {
            return "Complete Setup before preparing another take."
        }
        return nil
    }

    mutating func retake(afterTakeID expectedTakeID: String) throws {
        if let reason = retakeBlockReason() {
            throw ReferenceAuthoringError.recordingFailed(reason)
        }
        try requireLatestTakeIdentity(expectedTakeID)
        if let captureIntent, !captureIntent.isMovementCheck, captureIntent.beatSpec == nil {
            // Older raw captures may predate exact beat binding. Prepare only
            // the next take to bind its assets; the retained take and its
            // original intent remain unchanged.
            setupSequence += 1
            self.captureIntent = nil
            selectedBeatSpec = nil
        }
        phase = .readyToRecord
    }

    func newScratchSetupBlockReason() -> String? {
        finalizedTakeContinuationBlockReason()
    }

    /// Return to Setup for another scratch. Finalized takes, their identities,
    /// calibration and hardware observations remain intact. This allocates no
    /// take and makes no approval/rejection decision about the previous one.
    mutating func prepareNewScratchSetup(afterTakeID expectedTakeID: String) throws {
        if let reason = newScratchSetupBlockReason() {
            throw ReferenceAuthoringError.recordingFailed(reason)
        }
        try requireLatestTakeIdentity(expectedTakeID)
        setupSequence += 1
        captureIntent = nil
        selectedBeatSpec = nil
        selectedTechnique = nil
        selectedPattern = nil
        selectedBPM = nil
        selectedStartingDirection = nil
        selectedFaderVariant = nil
        selectedBeatEngineMode = .boomBapTrainer
        notes = ""
        // Preflight depends on the selected technique; retain the hardware
        // snapshot, but require a fresh evaluation for the next setup.
        latestPreflight = nil
        phase = .configuring
    }

    private func finalizedTakeContinuationBlockReason() -> String? {
        switch phase {
        case .recording:
            return "Wait for the current take to stop and finish finalizing."
        case .calibrating:
            return "Finish calibration before changing takes."
        case .configuring:
            return "Complete the current setup and record a take first."
        case .reviewing(let index):
            guard takes.indices.contains(index), index == takes.count - 1 else {
                return "Return to the latest finalized take before continuing."
            }
        case .readyToRecord, .complete:
            break
        }
        guard let take = latestRecordedTake else {
            return "No finalized take is available yet."
        }
        return pendingTakeEvidenceBlockReason(for: take)
    }

    private func pendingTakeEvidenceBlockReason(for take: ReferenceAuthoringTake) -> String? {
        if case .acknowledgedTransferPending = take.evidence.watchEvidence {
            return "Wait for this take's Apple Watch motion transfer to finish before continuing."
        }
        if take.evidence.metadata.sourceState?.isTerminal == false {
            return "Wait for this take's pending source transfer to finish before continuing."
        }
        return nil
    }

    private func requireLatestTakeIdentity(_ expectedTakeID: String) throws {
        guard latestRecordedTake?.id == expectedTakeID else {
            throw ReferenceAuthoringError.stepOutOfOrder(
                expected: "latest finalized take \(expectedTakeID)",
                actual: latestRecordedTake?.id ?? "no finalized take"
            )
        }
    }

    /// Move the take in review from `draft` to `reviewed` — the operator has
    /// audited it (whether or not they will ultimately approve it).
    mutating func markTakeReviewed() throws {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "reviewing", actual: "\(phase)")
        }
        if takes[takeIndex].evidence.metadata.lifecycleState == .draft {
            try takes[takeIndex].transition(to: .reviewed)
        }
    }

    /// Step 9's positive outcome and step 10 combined at the model level:
    /// approve the take in review as canonical. STILL NOT published — that is
    /// a separate, later action (`publish`), matching "explicitly publish an
    /// approved canonical reference" as its own numbered step.
    ///
    /// Refuses when validation has any failure, or when no repetition is
    /// selected — approval can never happen against a report that has not
    /// been re-checked against the operator's final boundaries.
    /// Why the take in review cannot be approved right now, or `nil` when it
    /// can.
    ///
    /// THE single source of truth for approval eligibility. The button reads
    /// it and so does `approveTakeInReview`, because a disabled button is a
    /// presentation detail and presentation is not a safety boundary — on
    /// 2026-09-05 `Approve Canonical Draft` was enabled against a take with
    /// three blocking findings.
    func approvalBlockReason(
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) -> String? {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else {
            return "This session is not reviewing a take."
        }
        let take = takes[takeIndex]
        if take.evidence.metadata.captureIntent?.isMovementCheck == true {
            return "Movement checks can be played and saved. Record a reference take to request canonical approval."
        }
        guard take.evidence.metadata.lifecycleState.canAdvance(to: .reviewed)
            || take.evidence.metadata.lifecycleState == .reviewed else {
            return "This take is \(take.evidence.metadata.lifecycleState.rawValue) and can no longer be approved."
        }
        // Validated FRESH, against the take's current boundaries. A stale
        // passing report from before a boundary edit must never authorise an
        // approval.
        let report = ReferenceValidator.validate(take.evidence, expectation: expectation, now: now)
        guard report.passes else {
            return "Cannot approve: " + report.failureMessages.joined(separator: " ")
        }
        guard take.evidence.boundaries.selectedRepetitionIndex != nil else {
            return "No repetition has been selected for approval."
        }
        return nil
    }

    // MARK: Raw diagnostic export
    //
    // Exporting the RAW capture and APPROVING a canonical reference are two
    // different acts with two different gates, and this is where they are kept
    // apart. Export copies what was recorded; approval asserts that what was
    // recorded is reference material. Export is therefore deliberately blind
    // to repetition selection, crossfader calibration, tear-review corrections
    // and `approvalBlockReason` — none of those changes a single byte of the
    // raw take, and refusing the export because one of them is outstanding
    // strands a real diagnostic capture on the machine that made it.
    //
    // Exporting APPROVES NOTHING. It does not publish, install, register or
    // make any take training-eligible, and it never advances a lifecycle
    // state.

    /// The most recently recorded take, whatever its lifecycle state.
    /// Rejected and un-reviewed takes are raw captures too and are retained.
    var latestRecordedTake: ReferenceAuthoringTake? { takes.last }

    /// Whether the completed session can explicitly continue with another
    /// draft while retaining the approved take. This prepares recording; it
    /// never starts or reserves the next take.
    var canPrepareNextTake: Bool {
        phase == .complete
            && latestRecordedTake?.evidence.metadata.lifecycleState == .approvedCanonical
    }

    /// Why the latest recorded take cannot be exported as a raw diagnostic
    /// capture right now, or `nil` when it can.
    ///
    /// Only two things are required: the take was authoritatively finalized,
    /// and the artifacts it names are actually on disk and readable. Both are
    /// properties of the CAPTURE, which is exactly what is being exported.
    func rawCaptureExportBlockReason() -> String? {
        guard case .recording = phase else {
            guard let take = latestRecordedTake else {
                return "No take has been recorded in this session yet."
            }
            let evidence = take.evidence
            guard evidence.sidecar.exists, evidence.sidecar.readError == nil else {
                return "This take's sidecar is missing or unreadable, so there is nothing stable to export."
            }
            guard evidence.audio.exists, evidence.audio.readError == nil else {
                return "This take's audio artifact is missing or unreadable, so there is nothing stable to export."
            }
            if let video = evidence.video, video.exists, let readError = video.readError {
                return "This take's video artifact is not stable yet: \(readError)"
            }
            if case .acknowledgedTransferPending = evidence.watchEvidence {
                return "Apple Watch motion is still transferring. Save Capture will become available when it is linked."
            }
            return nil
        }
        return "A take is still recording."
    }

    var canExportRawCapture: Bool { rawCaptureExportBlockReason() == nil }

    /// Convenience for the UI. Never the only check — see
    /// `approvalBlockReason`.
    func canApproveTakeInReview(
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) -> Bool {
        approvalBlockReason(expectation: expectation, now: now) == nil
    }

    mutating func approveTakeInReview(
        notes: String,
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) throws {
        guard case .reviewing(let takeIndex) = phase, takes.indices.contains(takeIndex) else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "reviewing", actual: "\(phase)")
        }
        // Re-validate and re-check EVERY gate here, not only in the caller.
        // A direct call to this method must not be able to approve a take the
        // button would have refused.
        revalidateTakeInReview(expectation: expectation, now: now)
        if let reason = approvalBlockReason(expectation: expectation, now: now) {
            throw ReferenceAuthoringError.recordingFailed(reason)
        }
        let take = takes[takeIndex]
        guard let selectedRepetitionIndex = take.evidence.boundaries.selectedRepetitionIndex else {
            throw ReferenceAuthoringError.recordingFailed("No repetition has been selected for approval.")
        }
        try takes[takeIndex].transition(to: .reviewed)
        try takes[takeIndex].transition(to: .approvedCanonical)
        takes[takeIndex].evidence.metadata.reviewDecision = ReferenceReviewDecision(
            outcome: .approved,
            decidedBy: operatorName,
            decidedAt: now,
            notes: notes,
            selectedRepetitionIndex: selectedRepetitionIndex
        )
        phase = .complete
    }

    /// Return a completed session to its existing ready state after the
    /// operator explicitly chooses to record another take.
    ///
    /// The expected ID is captured by the caller before serial dispatch so a
    /// stale action for an earlier approval cannot advance a later session.
    mutating func prepareNextTake(afterApprovedTakeID expectedTakeID: String) throws {
        guard canPrepareNextTake, let approvedTake = latestRecordedTake else {
            throw ReferenceAuthoringError.stepOutOfOrder(
                expected: "complete with a latest approved canonical take",
                actual: "\(phase)"
            )
        }
        guard approvedTake.id == expectedTakeID else {
            throw ReferenceAuthoringError.stepOutOfOrder(
                expected: "latest approved take \(expectedTakeID)",
                actual: "latest approved take \(approvedTake.id)"
            )
        }
        phase = .readyToRecord
    }

    /// Step 10: explicit publish. Only a take already `.approvedCanonical` may
    /// move here — this method builds nothing on disk itself; it hands the
    /// approved take to the caller, which is expected to run
    /// `ReferencePackageIO.writePackage` and then the developer import step.
    /// Step 11 — "available to training only after publication" — is
    /// enforced by `ReferenceRegistry`/`ReferenceLifecycleState`, not here.
    func takeReadyForPublication(takeIndex: Int) -> ReferenceAuthoringTake? {
        guard takes.indices.contains(takeIndex),
              takes[takeIndex].evidence.metadata.lifecycleState == .approvedCanonical else {
            return nil
        }
        return takes[takeIndex]
    }

    mutating func markTakePublished(takeIndex: Int) throws {
        guard takes.indices.contains(takeIndex) else {
            throw ReferenceAuthoringError.stepOutOfOrder(expected: "approvedCanonical", actual: "no such take")
        }
        try takes[takeIndex].transition(to: .published)
    }
}

/// One recorded take inside an authoring session, with its live evidence,
/// advisory auto-detection and latest validation.
struct ReferenceAuthoringTake: Equatable, Sendable, Identifiable {
    fileprivate(set) var tearEvidenceSourceBinding: ReferenceTearEvidenceSourceBinding?
    let rawSidecarURL: URL?
    fileprivate(set) var restoredTearProjection: ReferenceTearCanonicalProjection?
    fileprivate(set) var restoredTearPerformedLimitations: [String: [CanonicalTearComparison.UnavailableReason]]?
    fileprivate(set) var evidence: ReferenceTakeEvidence
    /// What automatic detection believed, shown to the operator, never
    /// written into `evidence.metadata.technique`.
    let autoDetectedTechnique: ReferenceTechnique?
    fileprivate(set) var latestValidation: ReferenceValidationReport
    /// Tear-segmentation review for this take: the automatic proposal plus
    /// every operator correction made against it.
    ///
    /// Read by the review UI and by nothing else. `ReferenceValidator` does
    /// not consult it, no lifecycle transition depends on it, and correcting
    /// it can neither approve this take nor make it available to training.
    fileprivate(set) var tearReview: ReferenceTearSegmentationReview
    /// Reviewer and time for `evidence.boundaries.selectedRepetitionIndex`;
    /// nil whenever no repetition is preferred. Not read by validation.
    fileprivate(set) var preferenceMark: ReferenceRepetitionPreferenceMark?

    var id: String { evidence.metadata.referenceTakeID }

    init(
        evidence: ReferenceTakeEvidence,
        autoDetectedTechnique: ReferenceTechnique?,
        latestValidation: ReferenceValidationReport,
        tearReview: ReferenceTearSegmentationReview? = nil,
        tearEvidenceSourceBinding: ReferenceTearEvidenceSourceBinding? = nil,
        rawSidecarURL: URL? = nil
    ) {
        self.tearEvidenceSourceBinding = tearEvidenceSourceBinding
        self.rawSidecarURL = rawSidecarURL
        self.evidence = evidence
        self.autoDetectedTechnique = autoDetectedTechnique
        self.latestValidation = latestValidation
        self.tearReview = tearReview
            ?? ReferenceTearSegmentationReviewBuilder.build(for: evidence)
    }

    var tearProjection: ReferenceTearCanonicalProjection {
        restoredTearProjection ?? ReferenceTearCanonicalProjectionBuilder.project(tearReview)
    }

    /// Intrinsic limitations only. Inter-gesture gaps depend on the selected
    /// phrase and are applied by comparison, never persisted across selections.
    var tearPerformedLimitations: [String: [CanonicalTearComparison.UnavailableReason]] {
        restoredTearPerformedLimitations ?? tearReview.requiredIntrinsicComparisonLimitations
    }

    /// `true` when auto-detection disagrees with CXL's selected technique.
    /// Surfaced to the operator; never auto-corrected.
    var autoDetectionDisagreesWithSelection: Bool {
        guard let autoDetectedTechnique else { return false }
        return autoDetectedTechnique != evidence.metadata.technique
    }

    fileprivate mutating func updateBoundaries(_ boundaries: ReferencePhraseBoundaries) {
        evidence.boundaries = boundaries
    }

    /// The ONLY writer of `watchEvidence` and of the `watchLinked` flag
    /// derived from it, so the two can never disagree.
    fileprivate func acceptsWatchEvidence(
        _ watchEvidence: ReferenceWatchEvidence,
        sourceState: ReferencePerTakeSourceState?
    ) -> Bool {
        if case .linked(_, let existingFile, _) = evidence.metadata.sourceState,
           case .linked(let file) = watchEvidence,
           existingFile != file { return false }
        guard let sourceState else { return true }
        // A verified late file may resolve only the exact pending/linked
        // capture. An external result cannot resurrect another terminal state.
        guard case .linked(let incomingIdentity, let incomingFile, let incomingHash) = sourceState,
              case .linked(let evidenceFile) = watchEvidence,
              let incomingFile, !incomingFile.isEmpty,
              incomingFile == evidenceFile else { return false }
        let currentIdentity: ReferenceTakeSourceIdentity
        switch evidence.metadata.sourceState {
        case .waitingForLateTransfer(let identity, _): currentIdentity = identity
        case .conflict(let identity?, _), .timedOut(let identity):
            // Older drafts treated Stop `sent` as a terminal failure, and an
            // optional Watch transfer can now time out. Recover only a proven
            // in-flight snapshot (Stop sent, or stopped with its file pending),
            // with the same command/take and a newly verified file digest.
            // Degraded Stop outcomes stay terminal.
            guard case .transferFailed = evidence.watchEvidence,
                  let incomingHash, incomingHash.count == 64, incomingHash.allSatisfy(\.isHexDigit),
                  let binding = tearEvidenceSourceBinding else { return false }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let sidecar = try? decoder.decode(CaptureCore.LocalRecordingSidecar.self,
                    from: binding.rawSidecarData),
                  sidecar.watchSyncState == .acknowledged,
                  sidecar.sessionID == identity.sessionID, sidecar.takeID == identity.takeID,
                  sidecar.appLocalTakeNumber == identity.takeNumber,
                  sidecar.watchCommandID == identity.takeToken else { return false }
            if let stop = sidecar.watchStopDiagnostics {
                guard stop.outcome == .sent || (stop.outcome == .stopped && stop.motionTransferState == .pending)
                else { return false }
            } else {
                // Older acknowledged captures have no Stop diagnostics. The
                // bridge still bounds their pending state at 90 seconds, so
                // the matching verified file must also be able to resolve
                // that timeout. Absence of diagnostics cannot clear a conflict.
                guard case .timedOut = evidence.metadata.sourceState else { return false }
            }
            currentIdentity = identity
        case .linked(let identity, _, let existingHash):
            currentIdentity = identity
            if let existingHash, let incomingHash, existingHash != incomingHash { return false }
        default: return false
        }
        guard incomingIdentity == currentIdentity else { return false }
        if let binding = tearEvidenceSourceBinding {
            guard binding.capturedSessionID == incomingIdentity.sessionID,
                  binding.capturedTakeID == incomingIdentity.takeID,
                  binding.capturedTakeNumber == incomingIdentity.takeNumber else { return false }
        }
        return true
    }

    fileprivate mutating func applyWatchEvidence(
        _ watchEvidence: ReferenceWatchEvidence,
        sourceState: ReferencePerTakeSourceState? = nil
    ) {
        guard acceptsWatchEvidence(watchEvidence, sourceState: sourceState) else { return }
        evidence.watchEvidence = watchEvidence
        if case .linked(let identity, let file, let hash) = sourceState {
            let retainedHash: String?
            if case .linked(_, _, let existingHash) = evidence.metadata.sourceState {
                retainedHash = hash ?? existingHash
            } else {
                retainedHash = hash
            }
            evidence.metadata.sourceState = .linked(identity: identity, motionFileName: file, sha256: retainedHash)
        } else if case .waitingForLateTransfer(let identity, _) = evidence.metadata.sourceState {
            switch watchEvidence {
            case .linked(let file):
                evidence.metadata.sourceState = .linked(identity: identity, motionFileName: file, sha256: nil)
            case .transferFailed(let detail):
                evidence.metadata.sourceState = detail.localizedCaseInsensitiveContains("timeout")
                    ? .timedOut(identity: identity)
                    : .conflict(identity: identity, detail: detail)
            case .identityMismatch(_, let found):
                let parts = found.split(separator: "/", maxSplits: 1).map(String.init)
                evidence.metadata.sourceState = .identityMismatch(
                    expected: identity,
                    foundSessionID: parts.first ?? found,
                    foundTakeID: parts.count > 1 ? parts[1] : "unknown"
                )
            case .acknowledgedTransferPending: break
            case .missing(let state):
                evidence.metadata.sourceState = .conflict(identity: identity, detail: "source became \(state)")
            }
        }
        evidence.metadata.deviceInfo = ReferenceDeviceInfo(
            platform: evidence.metadata.deviceInfo.platform,
            appVersion: evidence.metadata.deviceInfo.appVersion,
            controllerName: evidence.metadata.deviceInfo.controllerName,
            controllerIdentifier: evidence.metadata.deviceInfo.controllerIdentifier,
            audioDeviceName: evidence.metadata.deviceInfo.audioDeviceName,
            videoDeviceName: evidence.metadata.deviceInfo.videoDeviceName,
            watchLinked: watchEvidence.isLinked
        )
    }

    fileprivate mutating func transition(to next: ReferenceLifecycleState) throws {
        let current = evidence.metadata.lifecycleState
        guard current.canAdvance(to: next) else {
            throw ReferenceAuthoringError.stepOutOfOrder(
                expected: current.permittedNextStates.map(\.rawValue).joined(separator: " or "),
                actual: next.rawValue
            )
        }
        evidence.metadata.lifecycleState = next
    }
}
