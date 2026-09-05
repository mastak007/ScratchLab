// ReferenceRegistry — the single source of truth, shared by iOS and macOS, for
// which techniques a learner may train against and which reference recording
// they hear.
//
// The product decision this file encodes: every reference recording bundled
// before the crossfader calibration work is DEPRECATED and untrusted. Its
// crossfader stream was normalized against an assumed 0…127 range rather than
// the calibrated active half, so its derived fader events cannot be relied on.
// Those assets are not deleted — they stay on disk until approved replacements
// exist — but they are not servable, and the registry will not fall back to
// them.
//
// The three states a technique can be in:
//
//   available    an approved, calibrated reference exists and is servable
//   awaitingReRecord   a deprecated legacy asset exists, but no approved
//                      replacement. NOT servable. The learner is told why.
//   unavailable  nothing exists at all
//
// `resolve(technique:)` returns an entry, never an optional recording plus a
// silent fallback. There is no code path from "no approved reference" to
// "play the old one".
//
// Foundation only. Pure value types plus one deterministic resolver.

import Foundation

// MARK: - Availability

/// Why a technique is or is not trainable right now.
enum ReferenceAvailability: Equatable, Sendable {
    /// An approved, calibrated reference is servable.
    case available(ReferenceRegistryEntry)
    /// A legacy asset exists but is deprecated and will not be served.
    /// Carries the deprecated asset's identifier for the audit trail only —
    /// nothing may play it.
    case awaitingReRecord(deprecatedAssetID: String?, reason: ReferenceDeprecationReason)
    /// Nothing exists for this technique.
    case unavailable

    var isTrainable: Bool {
        if case .available = self { return true }
        return false
    }

    var entry: ReferenceRegistryEntry? {
        if case .available(let entry) = self { return entry }
        return nil
    }

    /// Learner-facing explanation. Honest about the state, never implying a
    /// recording exists when one does not.
    func learnerMessage(for technique: ReferenceTechnique) -> String? {
        switch self {
        case .available:
            return nil
        case .awaitingReRecord(_, let reason):
            return "\(technique.displayName) is being re-recorded. \(reason.learnerExplanation)"
        case .unavailable:
            return "\(technique.displayName) has no reference recording yet."
        }
    }
}

/// Why a bundled asset was withdrawn.
enum ReferenceDeprecationReason: String, Codable, Equatable, Sendable {
    /// Recorded before crossfader calibration existed, so its fader stream was
    /// normalized against an assumed full-range fader.
    case uncalibratedCrossfader
    /// Too many derived fader events could not be classified.
    case unclassifiedFaderEvents
    /// Withdrawn by an operator for a reason recorded elsewhere.
    case operatorWithdrawn

    var learnerExplanation: String {
        switch self {
        case .uncalibratedCrossfader:
            return "Its crossfader timing could not be verified against calibrated hardware."
        case .unclassifiedFaderEvents:
            return "Too much of its crossfader movement could not be read reliably."
        case .operatorWithdrawn:
            return "It was withdrawn for review."
        }
    }

    var operatorExplanation: String {
        switch self {
        case .uncalibratedCrossfader:
            return "Recorded before crossfader calibration existed: its fader stream was normalized against an assumed 0–127 range, not the calibrated active half."
        case .unclassifiedFaderEvents:
            return "The share of unclassified derived fader events exceeded the publishing threshold."
        case .operatorWithdrawn:
            return "Withdrawn by an operator."
        }
    }
}

// MARK: - Entries

/// One published reference a learner can be served.
struct ReferenceRegistryEntry: Codable, Equatable, Sendable, Identifiable {
    /// Stable key: technique + pattern. A technique may have several patterns.
    let referenceID: String
    let technique: ReferenceTechnique
    let pattern: ReferencePatternIdentity
    let bpm: Int
    let referenceVersion: Int
    let lifecycleState: ReferenceLifecycleState
    /// Bundle-relative path of the reference audio, e.g.
    /// `"References/baby_scratch/quarter_notes_v1.wav"`.
    let audioResourcePath: String
    /// Bundle-relative path of the package manifest that describes it.
    let manifestResourcePath: String
    /// SHA-256 of the audio, from the approved package.
    let audioSHA256: String
    /// Length of the published phrase, in beats.
    let phraseBeats: Int
    let startingPlatterDirection: ReferenceStartingPlatterDirection
    let approvedAt: Date
    let approvedBy: String

    var id: String { referenceID }

    /// Duration of the published phrase in seconds at its authored BPM.
    var phraseDurationSeconds: Double {
        bpm > 0 ? Double(phraseBeats) * 60.0 / Double(bpm) : 0
    }

    /// A learner may only be served an approved or published entry.
    var isServable: Bool { lifecycleState.isPlayableByLearner }
}

/// A legacy asset kept on disk but withdrawn from service.
///
/// Retained rather than deleted so an approved replacement can be compared
/// against it, and so nothing is destroyed before its replacement exists.
struct DeprecatedReferenceAsset: Codable, Equatable, Sendable, Identifiable {
    let assetID: String
    let technique: ReferenceTechnique?
    /// Bundle-relative path, kept for the audit trail. Never served.
    let resourcePath: String
    let reason: ReferenceDeprecationReason
    let deprecatedAt: Date

    var id: String { assetID }
}

// MARK: - Registry

/// The registry document: what is published, and what has been withdrawn.
struct ReferenceRegistryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_reference_registry_v1"

    let schemaVersion: String
    let generatedAt: Date
    let entries: [ReferenceRegistryEntry]
    let deprecatedAssets: [DeprecatedReferenceAsset]
    /// Techniques enabled for user training. The authoring brief's minimum
    /// required set, plus anything else the product has turned on. Being
    /// listed here does NOT make a technique trainable — an approved entry
    /// still has to exist.
    let trainingEnabledTechniques: [ReferenceTechnique]

    init(
        schemaVersion: String = ReferenceRegistryDocument.currentSchemaVersion,
        generatedAt: Date,
        entries: [ReferenceRegistryEntry],
        deprecatedAssets: [DeprecatedReferenceAsset],
        trainingEnabledTechniques: [ReferenceTechnique]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = entries
        self.deprecatedAssets = deprecatedAssets
        self.trainingEnabledTechniques = trainingEnabledTechniques
    }

    /// The registry state this build ships with today: nothing approved, every
    /// pre-calibration bundled reference withdrawn, the full training set
    /// waiting on CXL's re-records.
    ///
    /// Written out explicitly rather than left implicit, so "no reference is
    /// currently servable" is a fact in the code that a test can assert
    /// against, not an accident of an empty array.
    static func withdrawnLegacyBaseline(
        deprecatedAssets: [DeprecatedReferenceAsset],
        generatedAt: Date
    ) -> ReferenceRegistryDocument {
        ReferenceRegistryDocument(
            generatedAt: generatedAt,
            entries: [],
            deprecatedAssets: deprecatedAssets,
            trainingEnabledTechniques: ReferenceTechnique.minimumRequiredSet
        )
    }
}

/// Resolves what a learner may be served. Deterministic and total.
struct ReferenceRegistry: Equatable, Sendable {
    let document: ReferenceRegistryDocument

    init(document: ReferenceRegistryDocument) {
        self.document = document
    }

    /// The servable entry for `technique`, or the reason there isn't one.
    ///
    /// When several approved entries exist for a technique, the highest
    /// `referenceVersion` wins; ties break on the most recent approval. A
    /// deprecated asset is NEVER a candidate — the only thing the deprecated
    /// list contributes is a better explanation of the absence.
    func resolve(
        technique: ReferenceTechnique,
        patternID: String? = nil
    ) -> ReferenceAvailability {
        let candidates = document.entries
            .filter { $0.technique == technique && $0.isServable }
            .filter { patternID == nil || $0.pattern.id == patternID }
            .sorted { lhs, rhs in
                if lhs.referenceVersion == rhs.referenceVersion {
                    return lhs.approvedAt > rhs.approvedAt
                }
                return lhs.referenceVersion > rhs.referenceVersion
            }

        if let best = candidates.first {
            return .available(best)
        }
        if let deprecated = document.deprecatedAssets.first(where: { $0.technique == technique }) {
            return .awaitingReRecord(
                deprecatedAssetID: deprecated.assetID,
                reason: deprecated.reason
            )
        }
        return .unavailable
    }

    /// Every technique the product wants trainable, with its current state.
    /// Drives the training UI directly: a non-`available` technique is shown
    /// disabled with its reason, never hidden and never silently substituted.
    func trainingAvailability() -> [(technique: ReferenceTechnique, availability: ReferenceAvailability)] {
        document.trainingEnabledTechniques.map { ($0, resolve(technique: $0)) }
    }

    var trainableTechniques: [ReferenceTechnique] {
        trainingAvailability().filter { $0.availability.isTrainable }.map(\.technique)
    }

    var techniquesAwaitingReRecord: [ReferenceTechnique] {
        trainingAvailability().compactMap { pair in
            if case .awaitingReRecord = pair.availability { return pair.technique }
            return nil
        }
    }

    /// `true` when nothing at all is servable. The state this build ships in.
    var isEmptyOfServableReferences: Bool {
        document.entries.filter(\.isServable).isEmpty
    }
}
