// ReferenceValidation — every reason a reference take may be refused, each one
// naming the artifact or field that failed.
//
// The rule this file exists to enforce: a rejection must tell the operator
// what to fix. "This session is missing required files." satisfies nobody when
// the `.mov`, `.wav` and `.json` are all sitting on disk and non-empty. Each
// case below names one specific thing, and `ReferenceValidator` reports ALL of
// them rather than stopping at the first.
//
// Strictness is unchanged from the brief: everything that must fail, fails.
// Only the message improved.
//
// Foundation only. Pure. No file I/O — the caller measures the artifacts and
// hands the measurements in, which is what makes every rule unit-testable
// without a controller, a camera or a take on disk.

import Foundation

// MARK: - Findings

enum ReferenceValidationSeverity: String, Codable, Equatable, Sendable {
    /// Blocks approval and publication.
    case failure
    /// Recorded, surfaced in review, does not block.
    case warning
}

/// One named validation finding.
///
/// A closed vocabulary of checks. Associated values carry file NAMES, field
/// names and measurements — never file paths, performer names or note text.
enum ReferenceValidationFinding: Equatable, Sendable {

    // Artifacts
    case audioArtifactMissing(fileName: String)
    case audioArtifactUnreadable(fileName: String, detail: String)
    case audioArtifactEmpty(fileName: String)
    case videoArtifactMissing(fileName: String)
    case videoArtifactUnreadable(fileName: String, detail: String)
    case programAudioSilent(fileName: String, peakLevel: Double)
    case sidecarMissing(fileName: String)
    case sidecarUnreadable(fileName: String, detail: String)
    case fileNameSidecarMismatch(declaredInSidecar: String, actualFileName: String)
    case artifactHashMismatch(fileName: String, expectedSHA256: String, actualSHA256: String)

    // Controller / calibration
    case crossfaderCalibrationMissing
    case crossfaderCalibrationInvalid(detail: String)
    case crossfaderCalibrationAddressMismatch(
        calibrated: String,
        observed: String
    )
    case crossfaderEvidenceMissing
    /// An open-fader technique produced no trustworthy calibrated reading, so
    /// whether the fader was open cannot be established either way.
    case faderOpenStateUnknown(technique: String, detail: String)
    case platterEvidenceMissing
    case watchEvidenceMissing
    /// The Watch acknowledged and stopped for this exact take, but its motion
    /// file has not finished transferring yet. Distinct from missing: waiting
    /// is a state that resolves, absence is not.
    case watchEvidenceTransferPending
    case watchEvidenceTransferFailed(detail: String)
    case watchEvidenceIdentityMismatch(expected: String, found: String)
    case controllerNotIdentified

    // Derivation quality
    case unknownFaderEventRatioTooHigh(ratio: Double, maximum: Double)
    case faderLeftOpenZone(technique: String, closedEventCount: Int)
    case insufficientCutEvents(
        technique: String,
        repetitionIndex: Int,
        found: Int,
        required: Int
    )

    // Metadata
    case bpmOutOfRange(bpm: Int, supported: ClosedRange<Int>)
    case phraseLengthInvalid(phraseBars: Int, beatsPerBar: Int)
    case repetitionCountInvalid(found: Int, required: Int)
    case repetitionBoundariesInconsistent(detail: String)
    case repetitionBoundaryOutsideTake(repetitionIndex: Int, endBeat: Double, takeBeats: Int)
    case noRepetitionSelected
    case selectedRepetitionUnknown(index: Int)
    case startingPlatterDirectionUnknown
    case ambiguousFlareVariant(declaredScratchType: String)
    case performerNameMissing
    case operatorNameMissing
    case patternIdentityMissing
    case referenceVersionInvalid(version: Int)
    case lifecycleTransitionNotPermitted(from: String, to: String)

    var severity: ReferenceValidationSeverity {
        switch self {
        case .programAudioSilent:
            // A silent program stem is always fatal: the whole point of a
            // reference is the audio the learner copies.
            return .failure
        default:
            return .failure
        }
    }

    /// Operator-facing sentence. Says what failed and what to do.
    var message: String {
        switch self {
        case .audioArtifactMissing(let fileName):
            return "Reference audio \(fileName) is missing from the take folder. Re-record this take."
        case .audioArtifactUnreadable(let fileName, let detail):
            return "Reference audio \(fileName) exists but could not be read: \(detail)"
        case .audioArtifactEmpty(let fileName):
            return "Reference audio \(fileName) contains no audio frames. Re-record this take."
        case .videoArtifactMissing(let fileName):
            return "Reference video \(fileName) is missing from the take folder. Re-record this take."
        case .videoArtifactUnreadable(let fileName, let detail):
            return "Reference video \(fileName) exists but could not be read: \(detail)"
        case .programAudioSilent(let fileName, let peakLevel):
            return String(
                format: "Program audio %@ peaks at %.4f, which is silence. Check the deck routing and re-record.",
                fileName,
                peakLevel
            )
        case .sidecarMissing(let fileName):
            return "Take sidecar \(fileName) is missing from the take folder."
        case .sidecarUnreadable(let fileName, let detail):
            return "Take sidecar \(fileName) exists but could not be decoded: \(detail)"
        case .fileNameSidecarMismatch(let declared, let actual):
            return "The sidecar names its media file as \(declared), but the file on disk is \(actual)."
        case .artifactHashMismatch(let fileName, let expected, let actual):
            return "\(fileName) does not match its recorded hash. Expected sha256 \(expected.prefix(16))…, found \(actual.prefix(16))…. The file changed after it was captured."
        case .crossfaderCalibrationMissing:
            return "No crossfader calibration is on file for this controller. Run the crossfader calibration (full left, centre, full right) before recording a reference."
        case .crossfaderCalibrationInvalid(let detail):
            return "The stored crossfader calibration cannot be used: \(detail)"
        case .crossfaderCalibrationAddressMismatch(let calibrated, let observed):
            return "The crossfader calibration was measured on \(calibrated) but this take recorded fader traffic on \(observed). Recalibrate on the controller you are recording with."
        case .crossfaderEvidenceMissing:
            return "No crossfader MIDI was recorded for this take. Check that the controller is connected and the crossfader is mapped, then re-record."
        case .faderOpenStateUnknown(let technique, let detail):
            return "\(technique) is performed with the crossfader held open, but this take carries no trustworthy calibrated reading of the fader, so it cannot be shown that it was open: \(detail) Touch the fader once at the start of the take so its position is recorded, then re-record."
        case .platterEvidenceMissing:
            return "No platter movement was recorded for this take. Check the platter MIDI mapping, then re-record."
        case .watchEvidenceMissing:
            return "This take carries no linked Apple Watch motion, so its wrist evidence is absent. A canonical reference must be recorded with the paired Watch acknowledged and linked; re-record with the Watch capture running."
        case .watchEvidenceTransferPending:
            return "The Apple Watch acknowledged and stopped for this take, but its motion file has not finished transferring yet. Wait for the transfer to complete; approval stays blocked until the matching wrist evidence has landed."
        case .watchEvidenceTransferFailed(let detail):
            return "The Apple Watch motion transfer for this take did not complete: \(detail) Re-record with the Watch capture running."
        case .watchEvidenceIdentityMismatch(let expected, let found):
            return "The Watch evidence offered for this take names \(found) but this take is \(expected). Wrist evidence from another take is never attached; re-record."
        case .controllerNotIdentified:
            return "The recording controller could not be identified, so the fader mapping has no provenance. Select the MIDI source before recording."
        case .unknownFaderEventRatioTooHigh(let ratio, let maximum):
            return String(
                format: "%.0f%% of the derived crossfader events could not be classified (limit %.0f%%). The fader stream is not trustworthy enough to publish; recalibrate the crossfader and re-record.",
                ratio * 100,
                maximum * 100
            )
        case .faderLeftOpenZone(let technique, let closedEventCount):
            return "\(technique) must be performed with the crossfader open, but this take closed it \(closedEventCount) time(s). Re-record with the fader parked in its calibrated open zone."
        case .insufficientCutEvents(let technique, let repetitionIndex, let found, let required):
            return "Repetition \(repetitionIndex + 1) shows \(found) crossfader cut(s); \(technique) requires at least \(required). Re-record, or select a different repetition."
        case .bpmOutOfRange(let bpm, let supported):
            return "BPM \(bpm) is outside the supported range \(supported.lowerBound)–\(supported.upperBound)."
        case .phraseLengthInvalid(let phraseBars, let beatsPerBar):
            return "Phrase length is invalid: \(phraseBars) bar(s) × \(beatsPerBar) beat(s) per bar. Both must be greater than zero."
        case .repetitionCountInvalid(let found, let required):
            return "This take declares \(found) repetition(s); a reference take must contain \(required)."
        case .repetitionBoundariesInconsistent(let detail):
            return "The repetition boundaries are inconsistent: \(detail)"
        case .repetitionBoundaryOutsideTake(let index, let endBeat, let takeBeats):
            return String(
                format: "Repetition %d ends at beat %.2f, past the end of the take at beat %d.",
                index + 1,
                endBeat,
                takeBeats
            )
        case .noRepetitionSelected:
            return "No repetition has been selected. Audition the repetitions and choose the one to publish."
        case .selectedRepetitionUnknown(let index):
            return "The selected repetition (\(index + 1)) is not one of this take's repetitions."
        case .startingPlatterDirectionUnknown:
            return "The starting platter direction was not recorded. Set it before approving — it cannot be recovered from audio."
        case .ambiguousFlareVariant(let declared):
            return "Scratch type '\(declared)' does not name a flare click count. Record as 1-click, 2-click or 3-click flare; a generic 'flare' is not a technique."
        case .performerNameMissing:
            return "Performer name is required before a reference can be approved."
        case .operatorNameMissing:
            return "Operator name is required before a reference can be approved."
        case .patternIdentityMissing:
            return "Pattern ID is required. Each rhythmic pattern is a separate reference take and needs its own stable ID."
        case .referenceVersionInvalid(let version):
            return "Reference version \(version) is invalid; versions start at 1 and increase."
        case .lifecycleTransitionNotPermitted(let from, let to):
            return "A reference cannot move from \(from) to \(to). The order is draft → reviewed → approved canonical → published, and diagnostic, rejected and deprecated takes never re-enter it."
        }
    }
}

/// The full result of validating one take.
struct ReferenceValidationReport: Equatable, Sendable {
    let findings: [ReferenceValidationFinding]
    let evaluatedAt: Date

    init(findings: [ReferenceValidationFinding], evaluatedAt: Date) {
        self.findings = findings
        self.evaluatedAt = evaluatedAt
    }

    var failures: [ReferenceValidationFinding] {
        findings.filter { $0.severity == .failure }
    }

    var warnings: [ReferenceValidationFinding] {
        findings.filter { $0.severity == .warning }
    }

    var passes: Bool { failures.isEmpty }

    /// Every failure message, in the order the checks ran. Never collapsed to
    /// one sentence.
    var failureMessages: [String] { failures.map(\.message) }
}

// MARK: - Evidence

/// Measured facts about one artifact. The caller measures; the validator
/// judges.
struct ReferenceArtifactMeasurement: Equatable, Sendable {
    let fileName: String
    let exists: Bool
    let byteCount: Int64
    /// `nil` when the file could not be opened at all.
    let readError: String?
    /// Peak sample level, 0…1, for audio artifacts. `nil` for video.
    let peakLevel: Double?
    /// Frame count for audio artifacts. `nil` for video.
    let frameCount: Int64?
    /// SHA-256 recorded at capture time, if any.
    let recordedSHA256: String?
    /// SHA-256 measured now.
    let currentSHA256: String?

    init(
        fileName: String,
        exists: Bool,
        byteCount: Int64,
        readError: String? = nil,
        peakLevel: Double? = nil,
        frameCount: Int64? = nil,
        recordedSHA256: String? = nil,
        currentSHA256: String? = nil
    ) {
        self.fileName = fileName
        self.exists = exists
        self.byteCount = byteCount
        self.readError = readError
        self.peakLevel = peakLevel
        self.frameCount = frameCount
        self.recordedSHA256 = recordedSHA256
        self.currentSHA256 = currentSHA256
    }
}

/// Everything the validator needs about one take.
/// What is known about this take's Apple Watch motion, as a state rather than
/// a boolean.
///
/// A boolean could not express the case the 2026-09-05 hardware take actually
/// hit: the Watch acknowledged the start on the matching identity, stopped
/// cleanly on the same identity, and its motion file was still `pending`
/// transfer when macOS media finalization read the sidecar. Collapsing that to
/// `watchLinked == false` reported a working Watch as a missing one and made
/// the take permanently un-approvable.
///
/// `linked` is set ONLY from evidence whose session/take identity matches the
/// take it is being attached to.
enum ReferenceWatchEvidence: Equatable, Sendable {
    /// Matching motion evidence has landed and is attached to this take.
    case linked(motionFileName: String?)
    /// Acknowledged for this exact identity; the motion transfer has not
    /// reached a terminal state yet. Resolves on its own, or times out.
    case acknowledgedTransferPending
    /// The transfer reached a terminal state that is not "transferred".
    case transferFailed(detail: String)
    /// Watch data exists but names a different session/take. Never attached.
    case identityMismatch(expected: String, found: String)
    /// No Watch association at all — the start was never acknowledged, or no
    /// Watch was involved.
    case missing(syncState: String)

    var isLinked: Bool {
        if case .linked = self { return true }
        return false
    }

    var isTransferPending: Bool {
        if case .acknowledgedTransferPending = self { return true }
        return false
    }

    /// Whether this state can still change on its own. Used to bound the
    /// authoring screen's wait: everything else is terminal.
    var isTerminal: Bool { !isTransferPending }

    var operatorSummary: String {
        switch self {
        case .linked(let fileName):
            return "Apple Watch: linked motion capture present\(fileName.map { " (\($0))" } ?? "")."
        case .acknowledgedTransferPending:
            return "Apple Watch: acknowledged — motion transfer pending."
        case .transferFailed(let detail):
            return "Apple Watch: motion transfer failed — \(detail)"
        case .identityMismatch(let expected, let found):
            return "Apple Watch: evidence names \(found), not \(expected). Not attached."
        case .missing(let syncState):
            return "Apple Watch: NO linked motion capture (\(syncState))."
        }
    }
}

struct ReferenceTakeEvidence: Equatable, Sendable {
    /// `var`, not `let`: `ReferenceAuthoringSession` advances
    /// `metadata.lifecycleState` and sets `metadata.reviewDecision` in place
    /// as the operator moves a take through review — every other field stays
    /// fixed measurement, replaced only via `ReferenceAuthoringTake` building
    /// a whole new `ReferenceTakeEvidence` (see `updateBoundaries`).
    var metadata: ReferenceTakeMetadata
    var boundaries: ReferencePhraseBoundaries
    let audio: ReferenceArtifactMeasurement
    /// Video is optional for a reference package, but if declared it must be
    /// readable.
    let video: ReferenceArtifactMeasurement?
    let sidecar: ReferenceArtifactMeasurement
    /// Media file name found on disk, for the sidecar cross-check.
    let actualMediaFileName: String?
    /// Raw crossfader samples, as `(takeRelativeTime, rawValue)`.
    let crossfaderRawSamples: [CrossfaderPositionSample]
    /// The MIDI address the take actually observed fader traffic on.
    let observedCrossfaderAddress: CrossfaderMIDIAddress?
    /// Count of recorded platter movement events.
    let platterMovementEventCount: Int
    /// The recorded platter movement events themselves, exactly as the
    /// finalized sidecar carries them.
    ///
    /// Retained beside the count because tear-segmentation review has to show
    /// the operator the motion, not a number. Nothing derives a second
    /// platter decode from these: they are the output of
    /// `CaptureCore.derivePlatterMovementEvents` as written at finalization,
    /// and every review over them is a pure grouping of that evidence.
    /// Defaults to empty so a take measured before this field existed decodes
    /// and validates unchanged.
    let platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    /// The derivation produced from the raw samples and the calibration.
    /// `nil` when derivation could not run (unusable calibration).
    let derivation: CrossfaderDerivation?
    /// `var`: the Watch's motion file can finish transferring after macOS
    /// media finalization, so this is updated in place when the MATCHING
    /// transfer lands. `metadata.deviceInfo.watchLinked` is kept in step with
    /// it and is never set from anything else.
    var watchEvidence: ReferenceWatchEvidence

    init(
        metadata: ReferenceTakeMetadata,
        boundaries: ReferencePhraseBoundaries,
        audio: ReferenceArtifactMeasurement,
        video: ReferenceArtifactMeasurement?,
        sidecar: ReferenceArtifactMeasurement,
        actualMediaFileName: String?,
        crossfaderRawSamples: [CrossfaderPositionSample],
        observedCrossfaderAddress: CrossfaderMIDIAddress?,
        platterMovementEventCount: Int,
        derivation: CrossfaderDerivation?,
        watchEvidence: ReferenceWatchEvidence = .missing(syncState: "notRequested"),
        platterMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []
    ) {
        self.watchEvidence = watchEvidence
        self.metadata = metadata
        self.boundaries = boundaries
        self.audio = audio
        self.video = video
        self.sidecar = sidecar
        self.actualMediaFileName = actualMediaFileName
        self.crossfaderRawSamples = crossfaderRawSamples
        self.observedCrossfaderAddress = observedCrossfaderAddress
        self.platterMovementEventCount = platterMovementEventCount
        self.platterMovementEvents = platterMovementEvents
        self.derivation = derivation
    }
}

// MARK: - Validator

enum ReferenceValidator {

    /// Peak level at or below which a program stem counts as silent.
    static let silenceThreshold: Double = 0.0005

    /// Validate one take for APPROVAL.
    ///
    /// Every check runs; findings accumulate. Nothing short-circuits, because
    /// an operator fixing one problem should not have to re-run to discover
    /// the next.
    static func validate(
        _ evidence: ReferenceTakeEvidence,
        expectation: ReferenceFaderExpectation? = nil,
        now: Date = Date()
    ) -> ReferenceValidationReport {
        var findings: [ReferenceValidationFinding] = []
        let metadata = evidence.metadata
        let expectation = expectation ?? metadata.technique.defaultFaderExpectation

        findings.append(contentsOf: metadataFindings(metadata))
        findings.append(contentsOf: artifactFindings(evidence))
        findings.append(contentsOf: calibrationFindings(evidence))
        findings.append(contentsOf: evidenceFindings(evidence, expectation: expectation))
        findings.append(contentsOf: boundaryFindings(evidence))
        findings.append(
            contentsOf: techniqueFindings(evidence, expectation: expectation)
        )

        return ReferenceValidationReport(findings: findings, evaluatedAt: now)
    }

    // MARK: Metadata

    private static func metadataFindings(
        _ metadata: ReferenceTakeMetadata
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []

        if metadata.performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.performerNameMissing)
        }
        if metadata.operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.operatorNameMissing)
        }
        if !metadata.pattern.isUsable {
            findings.append(.patternIdentityMissing)
        }
        let supportedBPM = CaptureClickTrackDefaults.supportedBPMRange
        if !supportedBPM.contains(metadata.bpm) {
            findings.append(.bpmOutOfRange(bpm: metadata.bpm, supported: supportedBPM))
        }
        if metadata.pattern.phraseBars <= 0 || metadata.pattern.beatsPerBar <= 0 {
            findings.append(
                .phraseLengthInvalid(
                    phraseBars: metadata.pattern.phraseBars,
                    beatsPerBar: metadata.pattern.beatsPerBar
                )
            )
        }
        if metadata.repetitionCount != ReferenceTakeMetadata.defaultRepetitionCount {
            findings.append(
                .repetitionCountInvalid(
                    found: metadata.repetitionCount,
                    required: ReferenceTakeMetadata.defaultRepetitionCount
                )
            )
        }
        if metadata.referenceVersion < 1 {
            findings.append(.referenceVersionInvalid(version: metadata.referenceVersion))
        }
        // A flare that reached this point without a click count is not
        // representable in `ReferenceTechnique`, but a sidecar decoded from
        // disk can still name an ambiguous scratch type; catch it here rather
        // than trusting that the type system already did.
        if metadata.technique.scratchType == .unknown {
            findings.append(
                .ambiguousFlareVariant(declaredScratchType: metadata.technique.scratchType.rawValue)
            )
        }
        return findings
    }

    // MARK: Artifacts

    private static func artifactFindings(
        _ evidence: ReferenceTakeEvidence
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []

        let audio = evidence.audio
        if !audio.exists {
            findings.append(.audioArtifactMissing(fileName: audio.fileName))
        } else if let readError = audio.readError {
            findings.append(.audioArtifactUnreadable(fileName: audio.fileName, detail: readError))
        } else if audio.byteCount <= 0 || (audio.frameCount ?? 0) <= 0 {
            findings.append(.audioArtifactEmpty(fileName: audio.fileName))
        } else if let peak = audio.peakLevel, peak <= silenceThreshold {
            findings.append(.programAudioSilent(fileName: audio.fileName, peakLevel: peak))
        }

        if let video = evidence.video {
            if !video.exists {
                findings.append(.videoArtifactMissing(fileName: video.fileName))
            } else if let readError = video.readError {
                findings.append(
                    .videoArtifactUnreadable(fileName: video.fileName, detail: readError)
                )
            }
        }

        let sidecar = evidence.sidecar
        if !sidecar.exists {
            findings.append(.sidecarMissing(fileName: sidecar.fileName))
        } else if let readError = sidecar.readError {
            findings.append(.sidecarUnreadable(fileName: sidecar.fileName, detail: readError))
        }

        if let video = evidence.video,
           let actual = evidence.actualMediaFileName,
           video.exists,
           video.fileName != actual {
            findings.append(
                .fileNameSidecarMismatch(declaredInSidecar: video.fileName, actualFileName: actual)
            )
        }

        for measurement in [evidence.audio, evidence.video, evidence.sidecar].compactMap({ $0 }) {
            guard let recorded = measurement.recordedSHA256,
                  let current = measurement.currentSHA256,
                  recorded != current else { continue }
            findings.append(
                .artifactHashMismatch(
                    fileName: measurement.fileName,
                    expectedSHA256: recorded,
                    actualSHA256: current
                )
            )
        }
        return findings
    }

    // MARK: Calibration

    private static func calibrationFindings(
        _ evidence: ReferenceTakeEvidence
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []
        let calibration = evidence.metadata.crossfaderCalibration
        let issues = calibration.validationIssues()
        if !issues.isEmpty {
            findings.append(
                .crossfaderCalibrationInvalid(
                    detail: issues.map(\.message).joined(separator: " ")
                )
            )
        }
        if let observed = evidence.observedCrossfaderAddress,
           !calibration.address.matches(
                deviceIdentifier: observed.deviceIdentifier,
                channel: observed.channel,
                controller: observed.controller
           ) {
            findings.append(
                .crossfaderCalibrationAddressMismatch(
                    calibrated: calibration.address.displayName,
                    observed: observed.displayName
                )
            )
        }
        if evidence.metadata.deviceInfo.controllerIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.controllerNotIdentified)
        }
        return findings
    }

    // MARK: Fader open-state evidence

    /// How late the first calibrated reading may arrive and still count as
    /// evidence about the START of the take.
    ///
    /// A fader that only reports at t=4s says nothing about the first four
    /// seconds. `unknown` is the honest answer for that gap, not `open`.
    static let faderOpenBaselineTolerance: Double = 0.5

    /// What a take PROVES about the calibrated crossfader.
    ///
    /// Three outcomes, deliberately not two. The 2026-09-04 and 2026-09-05
    /// hardware takes were rejected for "no crossfader MIDI was recorded" on a
    /// Baby Scratch — a technique whose own `ReferenceFaderExpectation`
    /// declares `requiresContinuouslyOpenFader: true` and
    /// `minimumCutEventsPerRepetition: 0`. Absence of MOVEMENT is expected
    /// there; absence of KNOWLEDGE is not, and the two were being reported as
    /// the same thing.
    enum FaderOpenEvidence: Equatable, Sendable {
        /// Trustworthy calibrated intervals exist, they begin at the take's
        /// start, and every one of them is open.
        case provenContinuouslyOpen
        /// Trustworthy calibrated intervals exist and at least one is not open.
        case provenClosedAtSomePoint(closedIntervalCount: Int)
        /// No trustworthy calibrated interval covers the take's start. NEVER
        /// treated as open — an unmeasured fader is unknown, not compliant.
        case unknown(detail: String)
    }

    /// Classify `evidence` without fabricating anything: it reads only the
    /// intervals the deriver produced from real samples.
    static func faderOpenEvidence(
        for evidence: ReferenceTakeEvidence,
        baselineTolerance: Double = ReferenceValidator.faderOpenBaselineTolerance
    ) -> FaderOpenEvidence {
        guard evidence.metadata.crossfaderCalibration.isUsable else {
            return .unknown(detail: "the stored crossfader calibration is not usable.")
        }
        guard let derivation = evidence.derivation else {
            return .unknown(detail: "no calibrated fader stream could be derived for this take.")
        }
        guard let first = derivation.intervals.min(by: { $0.startTime < $1.startTime }) else {
            return .unknown(detail: "no crossfader position was recorded at any point in this take.")
        }
        guard first.startTime <= baselineTolerance else {
            return .unknown(
                detail: String(
                    format: "the first crossfader reading arrived %.2fs into the take, so its state at the start is unmeasured.",
                    first.startTime
                )
            )
        }
        let closedCount = derivation.intervals.filter { $0.state != .open }.count
        return closedCount == 0
            ? .provenContinuouslyOpen
            : .provenClosedAtSomePoint(closedIntervalCount: closedCount)
    }

    // MARK: Recorded evidence

    private static func evidenceFindings(
        _ evidence: ReferenceTakeEvidence,
        expectation: ReferenceFaderExpectation
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []

        // Crossfader requirements come from the TECHNIQUE, never from a
        // blanket "there must be fader movement" rule.
        //
        // An open-fader technique (Baby Scratch) is PERFORMED without moving
        // the fader, so an empty movement stream is the expected result, not a
        // defect. What it still owes is proof the fader was OPEN — handled in
        // `techniqueFindings` via `faderOpenEvidence`, which reports `unknown`
        // rather than silently passing. Requiring movement here made the one
        // authorable technique impossible to validate.
        if !expectation.requiresContinuouslyOpenFader {
            if evidence.crossfaderRawSamples.isEmpty {
                findings.append(.crossfaderEvidenceMissing)
            } else if evidence.metadata.crossfaderCalibration.isUsable, evidence.derivation == nil {
                // The calibration is fine, so a nil derivation can only mean
                // the stream itself was unusable.
                findings.append(.crossfaderEvidenceMissing)
            }
        }
        if expectation.requiresPlatterMotion, evidence.platterMovementEventCount <= 0 {
            findings.append(.platterEvidenceMissing)
        }
        // Watch motion is REQUIRED evidence for a canonical reference. The
        // states are kept apart deliberately: a transfer still in flight is
        // not the same as wrist data that never existed, and reporting the
        // first as the second made every acknowledged take look failed at
        // finalization (2026-09-05 take-003).
        switch evidence.watchEvidence {
        case .linked:
            break
        case .acknowledgedTransferPending:
            findings.append(.watchEvidenceTransferPending)
        case .transferFailed(let detail):
            findings.append(.watchEvidenceTransferFailed(detail: detail))
        case .identityMismatch(let expected, let found):
            findings.append(.watchEvidenceIdentityMismatch(expected: expected, found: found))
        case .missing:
            findings.append(.watchEvidenceMissing)
        }
        if let derivation = evidence.derivation, !derivation.events.isEmpty {
            let ratio = derivation.unknownEventRatio
            if ratio > expectation.maximumUnknownEventRatio {
                findings.append(
                    .unknownFaderEventRatioTooHigh(
                        ratio: ratio,
                        maximum: expectation.maximumUnknownEventRatio
                    )
                )
            }
        }
        return findings
    }

    // MARK: Boundaries

    private static func boundaryFindings(
        _ evidence: ReferenceTakeEvidence
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []
        let metadata = evidence.metadata
        let repetitions = evidence.boundaries.repetitions.sorted { $0.index < $1.index }

        if repetitions.count != metadata.repetitionCount {
            findings.append(
                .repetitionBoundariesInconsistent(
                    detail: "\(repetitions.count) boundary set(s) for \(metadata.repetitionCount) declared repetition(s)."
                )
            )
        }

        for repetition in repetitions {
            if repetition.durationBeats <= 0 {
                findings.append(
                    .repetitionBoundariesInconsistent(
                        detail: "repetition \(repetition.index + 1) ends at or before it starts."
                    )
                )
            }
            if repetition.endBeat > Double(metadata.totalBeats) {
                findings.append(
                    .repetitionBoundaryOutsideTake(
                        repetitionIndex: repetition.index,
                        endBeat: repetition.endBeat,
                        takeBeats: metadata.totalBeats
                    )
                )
            }
        }

        for index in 1..<max(1, repetitions.count) where index < repetitions.count {
            let previous = repetitions[index - 1]
            let current = repetitions[index]
            if current.startBeat < previous.endBeat {
                findings.append(
                    .repetitionBoundariesInconsistent(
                        detail: "repetition \(current.index + 1) starts before repetition \(previous.index + 1) ends."
                    )
                )
            }
        }

        guard let selected = evidence.boundaries.selectedRepetitionIndex else {
            findings.append(.noRepetitionSelected)
            return findings
        }
        if !repetitions.contains(where: { $0.index == selected }) {
            findings.append(.selectedRepetitionUnknown(index: selected))
        }
        return findings
    }

    // MARK: Technique requirements

    private static func techniqueFindings(
        _ evidence: ReferenceTakeEvidence,
        expectation: ReferenceFaderExpectation
    ) -> [ReferenceValidationFinding] {
        var findings: [ReferenceValidationFinding] = []
        let metadata = evidence.metadata

        // Evaluated BEFORE the derivation guard below: an open-fader technique
        // with no derivation at all is exactly the `unknown` case, and
        // returning early would have let it pass silently.
        if expectation.requiresContinuouslyOpenFader {
            switch faderOpenEvidence(for: evidence) {
            case .provenContinuouslyOpen:
                break
            case .provenClosedAtSomePoint(let closedCount):
                findings.append(
                    .faderLeftOpenZone(
                        technique: metadata.technique.displayName,
                        closedEventCount: closedCount
                    )
                )
            case .unknown(let detail):
                findings.append(
                    .faderOpenStateUnknown(
                        technique: metadata.technique.displayName,
                        detail: detail
                    )
                )
            }
        }

        guard let derivation = evidence.derivation else { return findings }

        // Cut-count requirements are TECHNIQUE-SHAPE claims — ScratchLab has
        // never been shown a correct chirp, transform or flare, so these stay
        // advisory (surfaced in review, never blocking) until CXL explicitly
        // confirms the requirement for this technique via
        // `ReferenceFaderExpectation.confirmed(by:at:)`. Baby Scratch's
        // open-fader check above is NOT gated this way — "the fader stays
        // open" is definitional for that technique, not a shape CXL needs to
        // confirm from a recording.
        guard expectation.minimumCutEventsPerRepetition > 0,
              expectation.source.isOperatorConfirmed else { return findings }
        for repetition in evidence.boundaries.repetitions {
            let start = repetition.startSeconds(bpm: metadata.bpm)
            let end = repetition.endSeconds(bpm: metadata.bpm)
            let cuts = derivation.events.filter { event in
                let isCutFamily = event.kind == .cut
                    || event.kind == .pulse
                    || event.kind == .transformPulse
                return isCutFamily && event.startTime >= start && event.startTime < end
            }
            // A transform pulse figure contains several clicks; count them so
            // a collapsed figure is not scored as one cut.
            let cutCount = cuts.reduce(0) { partial, event in
                partial + (event.kind == .transformPulse ? 3 : (event.kind == .pulse ? 2 : 1))
            }
            if cutCount < expectation.minimumCutEventsPerRepetition {
                findings.append(
                    .insufficientCutEvents(
                        technique: metadata.technique.displayName,
                        repetitionIndex: repetition.index,
                        found: cutCount,
                        required: expectation.minimumCutEventsPerRepetition
                    )
                )
            }
        }
        return findings
    }

    /// Validate a lifecycle move on its own, so the UI can disable an illegal
    /// transition rather than performing it and reporting afterwards.
    static func lifecycleFinding(
        from current: ReferenceLifecycleState,
        to next: ReferenceLifecycleState
    ) -> ReferenceValidationFinding? {
        guard !current.canAdvance(to: next) else { return nil }
        return .lifecycleTransitionNotPermitted(
            from: current.rawValue,
            to: next.rawValue
        )
    }
}
