// ReferencePackage — the versioned, self-describing bundle one approved
// reference performance exports as.
//
// A package is complete evidence: the audio a learner hears, every raw stream
// it was derived from, the calibration that made the derivation meaningful,
// the boundaries an operator chose, and the validation report that was true at
// the moment of approval. Anyone — a later build, the developer import step, a
// reviewer a year from now — can re-derive the semantic fader events from the
// raw MIDI and the calibration and get the same answer.
//
// On-disk layout:
//
//     <referenceID>_v<version>/
//       manifest.json                 this file's `ReferencePackageManifest`
//       audio/reference.wav           the selected repetition
//       audio/full_take.wav           the whole take, for re-cutting
//       video/reference.mov           optional
//       capture/take_sidecar.json     the original capture sidecar, verbatim
//       capture/raw_midi.json         every mixer MIDI event in the take
//       capture/platter_timeline.json raw platter events
//       capture/crossfader_raw.json   raw crossfader samples
//       capture/crossfader_calibrated.json  normalized samples + derived events
//       notation/evidence.json        detected notation evidence
//       validation/report.json        findings at approval time
//
// Every path above appears in the manifest with its byte count and SHA-256, so
// a package that has been edited after approval fails its own hash check.
//
// Foundation only. Pure value types; file I/O lives in the authoring service.

import Foundation

// MARK: - Artifact records

/// One file in the package.
struct ReferenceArtifactRecord: Codable, Equatable, Sendable, Identifiable {
    /// Package-relative path, e.g. `"audio/reference.wav"`.
    let path: String
    let byteCount: Int64
    let sha256: String
    /// What the file is, from a closed vocabulary the import step switches on.
    let role: Role

    enum Role: String, Codable, Equatable, Sendable {
        case referenceAudio
        case fullTakeAudio
        case referenceVideo
        case takeSidecar
        case rawMIDI
        case platterTimeline
        case crossfaderRaw
        case crossfaderCalibrated
        case notationEvidence
        case validationReport
        case beatProductionMaster
        case beatSparseAnalysis
        case beatManifest
        case beatRightsReceipt
        case watchMotion
    }

    var id: String { path }

    init(path: String, byteCount: Int64, sha256: String, role: Role) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.role = role
    }
}

// MARK: - Serialized streams

/// One raw mixer MIDI event, as exported.
struct ReferenceRawMIDIEvent: Codable, Equatable, Sendable {
    let takeRelativeTime: Double
    let deviceName: String
    let channel: Int
    let controller: Int
    let value: Int
    /// The control this address was mapped to, if any. Never inferred at read
    /// time — what capture believed at record time.
    let mappedControl: String?
}

/// One calibrated crossfader sample, as exported.
///
/// Both the raw value and the calibrated position are written. The raw value
/// is the measurement; the position is this build's interpretation of it. A
/// future build that improves normalization can recompute the position from
/// the raw value and the calibration without re-recording.
struct ReferenceCalibratedFaderSample: Codable, Equatable, Sendable {
    let takeRelativeTime: Double
    let rawValue: Int
    let normalizedPosition: Double
    /// Audible gain after the snapshotted curve. Legacy documents omit it.
    let audibleGain: Double?

    init(
        takeRelativeTime: Double,
        rawValue: Int,
        normalizedPosition: Double,
        audibleGain: Double? = nil
    ) {
        self.takeRelativeTime = takeRelativeTime
        self.rawValue = rawValue
        self.normalizedPosition = normalizedPosition
        self.audibleGain = audibleGain
    }
}

/// One derived semantic fader event, as exported.
struct ReferenceDerivedFaderEvent: Codable, Equatable, Sendable {
    let kind: CrossfaderSemanticEventKind
    let startTime: Double
    let endTime: Double
    let fromPosition: Double
    let toPosition: Double
}

/// One committed open/closed/transitioning interval, as exported.
struct ReferenceFaderStateInterval: Codable, Equatable, Sendable {
    let state: CrossfaderGateState
    let startTime: Double
    let endTime: Double
}

/// One platter movement event, as exported.
struct ReferencePlatterEvent: Codable, Equatable, Sendable {
    let startTime: Double
    let endTime: Double
    let direction: ScratchNotationDirection
    let startPosition: Double
    let endPosition: Double
    let speed: Double
}

/// The calibrated fader document: what the derivation ran on, and what it
/// produced, with the parameters that produced it.
struct ReferenceCalibratedFaderDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_reference_fader_v1"

    let schemaVersion: String
    let calibration: CrossfaderCalibration
    /// Exact learned response used for gate derivation. Legacy absence means
    /// the migration-safe sharp scratch response.
    let curveResponse: FaderCurveResponse?
    let hysteresisClosedAtOrBelow: Double
    let hysteresisOpenAtOrAbove: Double
    let hysteresisMinimumDwellSeconds: Double
    let maximumCutDurationSeconds: Double
    let maximumPulseGapSeconds: Double
    let samples: [ReferenceCalibratedFaderSample]
    let stateIntervals: [ReferenceFaderStateInterval]
    let derivedEvents: [ReferenceDerivedFaderEvent]
    let unknownEventCount: Int
    let unknownEventRatio: Double

    init(
        schemaVersion: String = ReferenceCalibratedFaderDocument.currentSchemaVersion,
        calibration: CrossfaderCalibration,
        curveResponse: FaderCurveResponse? = nil,
        hysteresis: CrossfaderHysteresis,
        maximumCutDurationSeconds: Double,
        maximumPulseGapSeconds: Double,
        samples: [ReferenceCalibratedFaderSample],
        derivation: CrossfaderDerivation
    ) {
        self.schemaVersion = schemaVersion
        self.calibration = calibration
        self.curveResponse = curveResponse
        self.hysteresisClosedAtOrBelow = hysteresis.closedAtOrBelow
        self.hysteresisOpenAtOrAbove = hysteresis.openAtOrAbove
        self.hysteresisMinimumDwellSeconds = hysteresis.minimumDwellSeconds
        self.maximumCutDurationSeconds = maximumCutDurationSeconds
        self.maximumPulseGapSeconds = maximumPulseGapSeconds
        self.samples = samples
        self.stateIntervals = derivation.intervals.map {
            ReferenceFaderStateInterval(
                state: $0.state,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        self.derivedEvents = derivation.events.map {
            ReferenceDerivedFaderEvent(
                kind: $0.kind,
                startTime: $0.startTime,
                endTime: $0.endTime,
                fromPosition: $0.fromPosition,
                toPosition: $0.toPosition
            )
        }
        self.unknownEventCount = derivation.unknownEventCount
        self.unknownEventRatio = derivation.unknownEventRatio
    }

    /// Rebuild the derivation this document recorded, without re-reading the
    /// raw stream. Used by the round-trip test and by the import step's
    /// consistency check.
    var recordedDerivation: CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: stateIntervals.map {
                CrossfaderStateInterval(
                    state: $0.state,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    startPosition: 0,
                    endPosition: 0
                )
            },
            events: derivedEvents.map {
                CrossfaderSemanticEvent(
                    kind: $0.kind,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    fromPosition: $0.fromPosition,
                    toPosition: $0.toPosition
                )
            }
        )
    }

    var hysteresis: CrossfaderHysteresis {
        CrossfaderHysteresis(
            closedAtOrBelow: hysteresisClosedAtOrBelow,
            openAtOrAbove: hysteresisOpenAtOrAbove,
            minimumDwellSeconds: hysteresisMinimumDwellSeconds
        )
    }
}

// MARK: - Serialized validation report

/// The validation result frozen at approval time.
///
/// Messages are stored as text because that is what a human reading the
/// package a year from now needs; the check names are stored alongside so a
/// machine can still filter.
struct ReferenceValidationRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_reference_validation_v1"

    struct Entry: Codable, Equatable, Sendable {
        let severity: ReferenceValidationSeverity
        let message: String
    }

    let schemaVersion: String
    let evaluatedAt: Date
    let passed: Bool
    let entries: [Entry]

    init(report: ReferenceValidationReport) {
        self.schemaVersion = Self.currentSchemaVersion
        self.evaluatedAt = report.evaluatedAt
        self.passed = report.passes
        self.entries = report.findings.map {
            Entry(severity: $0.severity, message: $0.message)
        }
    }
}

// MARK: - Manifest

/// The package manifest — the one file the import step reads first.
struct ReferencePackageManifest: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = "scratchlab_reference_package_v1"
    static let fileName = "manifest.json"

    let schemaVersion: String
    /// Stable identity of the reference this package publishes.
    let referenceID: String
    let referenceVersion: Int
    let packageBuiltAt: Date

    let metadata: ReferenceTakeMetadata
    let boundaries: ReferencePhraseBoundaries
    /// The repetition that was approved, resolved from `boundaries`.
    let selectedRepetitionIndex: Int
    /// Take-relative bounds of the published phrase, in seconds.
    let publishedPhraseStartSeconds: Double
    let publishedPhraseEndSeconds: Double
    let publishedPhraseBeats: Int

    let approval: ReferenceReviewDecision
    let validation: ReferenceValidationRecord
    let artifacts: [ReferenceArtifactRecord]

    var id: String { "\(referenceID)_v\(referenceVersion)" }

    /// Directory name this package occupies on disk.
    var packageDirectoryName: String { id }

    init(
        schemaVersion: String = ReferencePackageManifest.currentSchemaVersion,
        referenceID: String,
        referenceVersion: Int,
        packageBuiltAt: Date,
        metadata: ReferenceTakeMetadata,
        boundaries: ReferencePhraseBoundaries,
        selectedRepetitionIndex: Int,
        publishedPhraseStartSeconds: Double,
        publishedPhraseEndSeconds: Double,
        publishedPhraseBeats: Int,
        approval: ReferenceReviewDecision,
        validation: ReferenceValidationRecord,
        artifacts: [ReferenceArtifactRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.referenceID = referenceID
        self.referenceVersion = referenceVersion
        self.packageBuiltAt = packageBuiltAt
        self.metadata = metadata
        self.boundaries = boundaries
        self.selectedRepetitionIndex = selectedRepetitionIndex
        self.publishedPhraseStartSeconds = publishedPhraseStartSeconds
        self.publishedPhraseEndSeconds = publishedPhraseEndSeconds
        self.publishedPhraseBeats = publishedPhraseBeats
        self.approval = approval
        self.validation = validation
        self.artifacts = artifacts
    }

    func artifact(role: ReferenceArtifactRecord.Role) -> ReferenceArtifactRecord? {
        artifacts.first { $0.role == role }
    }

    var requiresExactWatchArtifact: Bool {
        guard let beat = metadata.captureIntent?.beatSpec else { return false }
        return beat.version >= 2 && beat.id.hasPrefix("cxl_runtime_v2_")
    }

    /// Roles that must be present for a package to be importable. Video is
    /// deliberately absent: it is useful, not required.
    static let requiredArtifactRoles: [ReferenceArtifactRecord.Role] = [
        .referenceAudio,
        .fullTakeAudio,
        .takeSidecar,
        .rawMIDI,
        .platterTimeline,
        .crossfaderRaw,
        .crossfaderCalibrated,
        .notationEvidence,
        .validationReport
    ]

    /// Stable reference ID for a technique + pattern pair.
    static func makeReferenceID(
        technique: ReferenceTechnique,
        patternID: String
    ) -> String {
        "\(technique.scratchType.rawValue).\(patternID)"
    }
}

// MARK: - Package-level validation

/// Why a package may not be imported.
enum ReferencePackageIssue: Equatable, Sendable {
    case unsupportedSchemaVersion(found: String, expected: String)
    case missingRequiredArtifact(role: String)
    case artifactFileMissing(path: String)
    case artifactHashMismatch(path: String, expected: String, actual: String)
    case artifactSizeMismatch(path: String, expected: Int64, actual: Int64)
    case notApproved(lifecycleState: String)
    case approvalOutcomeNotApproved(outcome: String)
    case validationDidNotPass(failureCount: Int)
    case selectedRepetitionMissing(index: Int)
    case publishedPhraseEmpty
    case captureIntentInvalid(detail: String)
    case witnessedTimingInvalid(detail: String)
    case sourceStateInvalid(detail: String)
    case identityMismatch(detail: String)
    case unsafeArtifactPath(path: String)

    var message: String {
        switch self {
        case .unsupportedSchemaVersion(let found, let expected):
            return "Reference package uses schema '\(found)'; this build imports '\(expected)'."
        case .missingRequiredArtifact(let role):
            return "Reference package does not declare a required artifact for role '\(role)'."
        case .artifactFileMissing(let path):
            return "Reference package declares \(path), but that file is not in the package."
        case .artifactHashMismatch(let path, let expected, let actual):
            return "\(path) does not match its manifest hash. Expected sha256 \(expected.prefix(16))…, found \(actual.prefix(16))…."
        case .artifactSizeMismatch(let path, let expected, let actual):
            return "\(path) is \(actual) bytes; the manifest declares \(expected)."
        case .notApproved(let lifecycleState):
            return "Reference package is in state '\(lifecycleState)'. Only an approved package may be imported."
        case .approvalOutcomeNotApproved(let outcome):
            return "Reference package carries a '\(outcome)' review decision, not an approval."
        case .validationDidNotPass(let failureCount):
            return "Reference package was approved with \(failureCount) unresolved validation failure(s) and cannot be imported."
        case .selectedRepetitionMissing(let index):
            return "Reference package names repetition \(index + 1) as approved, but its boundaries do not contain it."
        case .publishedPhraseEmpty:
            return "Reference package declares a published phrase of zero length."
        case .captureIntentInvalid(let detail):
            return "Reference package capture intent is invalid: \(detail)"
        case .witnessedTimingInvalid(let detail): return "Reference package timing is invalid: \(detail)"
        case .sourceStateInvalid(let detail): return "Reference package source state is invalid: \(detail)"
        case .identityMismatch(let detail): return "Reference package identity mismatch: \(detail)"
        case .unsafeArtifactPath(let path): return "Reference package artifact path is unsafe: \(path)"
        }
    }
}

/// Deterministic package checks that need no file system.
///
/// The developer import step runs these first, then re-hashes the files on
/// disk against `artifacts` — the two halves together are what make the import
/// reproducible.
enum ReferencePackageValidator {

    /// Checks that read only the manifest.
    static func manifestIssues(_ manifest: ReferencePackageManifest) -> [ReferencePackageIssue] {
        var issues: [ReferencePackageIssue] = []

        if manifest.schemaVersion != ReferencePackageManifest.currentSchemaVersion {
            issues.append(
                .unsupportedSchemaVersion(
                    found: manifest.schemaVersion,
                    expected: ReferencePackageManifest.currentSchemaVersion
                )
            )
        }
        for role in ReferencePackageManifest.requiredArtifactRoles
        where manifest.artifact(role: role) == nil {
            issues.append(.missingRequiredArtifact(role: role.rawValue))
        }
        if let beat = manifest.metadata.captureIntent?.beatSpec {
            for role in [ReferenceArtifactRecord.Role.beatProductionMaster, .beatSparseAnalysis,
                         .beatManifest, .beatRightsReceipt] where manifest.artifact(role: role) == nil {
                issues.append(.missingRequiredArtifact(role: role.rawValue))
            }
            for (role, fileName, expectedHash) in [
                (ReferenceArtifactRecord.Role.beatProductionMaster, beat.productionMasterFileName, beat.productionMasterSHA256),
                (.beatSparseAnalysis, beat.sparseAnalysisMixFileName, beat.sparseAnalysisMixSHA256)
            ] {
                if let artifact = manifest.artifact(role: role),
                   artifact.path != "beat_assets/\(beat.id)/\(fileName)" || artifact.sha256 != expectedHash {
                    issues.append(.captureIntentInvalid(detail: "\(role.rawValue) does not match the exact bound beat asset"))
                }
            }
        }
        if manifest.requiresExactWatchArtifact {
            if case .linked(_, let fileName, let hash) = manifest.metadata.sourceState,
               let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let hash, hash.count == 64,
               hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), manifest.metadata.deviceInfo.watchLinked {
                if manifest.artifact(role: .watchMotion) == nil {
                    issues.append(.missingRequiredArtifact(role: ReferenceArtifactRecord.Role.watchMotion.rawValue))
                }
            } else {
                issues.append(.sourceStateInvalid(detail: "An exact CXL reference requires linked Watch identity, filename and SHA-256."))
            }
        }
        if case .linked(_, _, let hash) = manifest.metadata.sourceState, let hash {
            if let artifact = manifest.artifact(role: .watchMotion) {
                if artifact.sha256 != hash {
                    issues.append(.sourceStateInvalid(detail: "Watch artifact does not match the linked source hash"))
                }
            } else {
                issues.append(.missingRequiredArtifact(role: ReferenceArtifactRecord.Role.watchMotion.rawValue))
            }
        }
        let expectedReferenceID = ReferencePackageManifest.makeReferenceID(
            technique: manifest.metadata.technique,
            patternID: manifest.metadata.pattern.id
        )
        if manifest.referenceID != expectedReferenceID
            || manifest.referenceVersion != manifest.metadata.referenceVersion {
            issues.append(.identityMismatch(detail: "manifest and take metadata name different references"))
        }
        for artifact in manifest.artifacts where !ReferencePackageIO.isSafeRelativePath(artifact.path) {
            issues.append(.unsafeArtifactPath(path: artifact.path))
        }
        if manifest.metadata.lifecycleState != .approvedCanonical
            && manifest.metadata.lifecycleState != .published {
            issues.append(.notApproved(lifecycleState: manifest.metadata.lifecycleState.rawValue))
        }
        if manifest.approval.outcome != .approved {
            issues.append(
                .approvalOutcomeNotApproved(outcome: manifest.approval.outcome.rawValue)
            )
        }
        let failureCount = manifest.validation.entries.filter { $0.severity == .failure }.count
        if !manifest.validation.passed || failureCount > 0 {
            issues.append(.validationDidNotPass(failureCount: failureCount))
        }
        if !manifest.boundaries.repetitions.contains(where: {
            $0.index == manifest.selectedRepetitionIndex
        }) {
            issues.append(
                .selectedRepetitionMissing(index: manifest.selectedRepetitionIndex)
            )
        }
        if manifest.publishedPhraseEndSeconds <= manifest.publishedPhraseStartSeconds {
            issues.append(.publishedPhraseEmpty)
        }
        if let origin = manifest.metadata.mediaTimeOrigin {
            issues.append(contentsOf: origin.validationIssues.map { .witnessedTimingInvalid(detail: $0) })
        }
        if manifest.metadata.captureIntent != nil {
            issues.append(contentsOf: ReferenceCaptureIntentValidator.issues(
                intent: manifest.metadata.captureIntent,
                metadata: manifest.metadata,
                requireBeatSpec: false
            ).map { .captureIntentInvalid(detail: String(describing: $0)) })
            if manifest.metadata.captureIntent?.beatSpec != nil {
                issues.append(contentsOf: ReferenceWitnessedTimingValidator.issues(
                    manifest.metadata.witnessedTiming,
                    intent: manifest.metadata.captureIntent,
                    mediaTimeOrigin: manifest.metadata.mediaTimeOrigin
                ).map { .witnessedTimingInvalid(detail: $0) })
            }
        }
        if let sourceState = manifest.metadata.sourceState {
            if !sourceState.isTerminal {
                issues.append(.sourceStateInvalid(detail: "late transfer is still pending"))
            }
            switch sourceState {
            case .identityMismatch, .timedOut, .conflict:
                issues.append(.sourceStateInvalid(detail: sourceState.operatorSummary))
            case .linked, .notRequested, .unavailable, .waitingForLateTransfer:
                break
            }
        }
        return issues
    }

    /// Checks that compare the manifest against measured files.
    ///
    /// `measurements` is keyed by package-relative path. A declared artifact
    /// with no measurement is a missing file, never a pass.
    static func artifactIssues(
        _ manifest: ReferencePackageManifest,
        measurements: [String: (byteCount: Int64, sha256: String)]
    ) -> [ReferencePackageIssue] {
        var issues: [ReferencePackageIssue] = []
        for artifact in manifest.artifacts {
            guard let measurement = measurements[artifact.path] else {
                issues.append(.artifactFileMissing(path: artifact.path))
                continue
            }
            if measurement.sha256 != artifact.sha256 {
                issues.append(
                    .artifactHashMismatch(
                        path: artifact.path,
                        expected: artifact.sha256,
                        actual: measurement.sha256
                    )
                )
            }
            if measurement.byteCount != artifact.byteCount {
                issues.append(
                    .artifactSizeMismatch(
                        path: artifact.path,
                        expected: artifact.byteCount,
                        actual: measurement.byteCount
                    )
                )
            }
        }
        return issues
    }

    /// The registry entry an approved package becomes.
    ///
    /// Returns `nil` when the manifest does not pass `manifestIssues`, so a
    /// failing package can never be turned into a servable entry by accident.
    static func registryEntry(
        for manifest: ReferencePackageManifest,
        audioResourcePath: String,
        manifestResourcePath: String
    ) -> ReferenceRegistryEntry? {
        guard manifestIssues(manifest).isEmpty,
              let audio = manifest.artifact(role: .referenceAudio) else { return nil }
        return ReferenceRegistryEntry(
            referenceID: manifest.referenceID,
            technique: manifest.metadata.technique,
            pattern: manifest.metadata.pattern,
            bpm: manifest.metadata.bpm,
            referenceVersion: manifest.referenceVersion,
            lifecycleState: .published,
            audioResourcePath: audioResourcePath,
            manifestResourcePath: manifestResourcePath,
            audioSHA256: audio.sha256,
            phraseBeats: manifest.publishedPhraseBeats,
            startingPlatterDirection: manifest.metadata.startingPlatterDirection,
            approvedAt: manifest.approval.decidedAt,
            approvedBy: manifest.approval.decidedBy
        )
    }
}
