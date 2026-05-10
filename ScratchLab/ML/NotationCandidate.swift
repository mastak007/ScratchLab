//
//  NotationCandidate.swift
//  ScratchLab
//
//  Slice N: a notation candidate represents *something happened on the
//  timeline at this time* — an onset, a cut, a stroke, a silence gap, or
//  an uncertain stroke we can't yet identify. Identity (which scratch?)
//  is optional.
//
//  Product invariant: a likely stroke MUST produce a candidate even when
//  classifier identity is unknown. Low classifier confidence may downgrade
//  the candidate to `.uncertain` but must NEVER delete it.
//

import Foundation

/// A single timeline event that the notation pipeline can render or display.
///
/// Identity (`predictedClass`, `predictedFamily`, `classifierConfidence`)
/// is optional — audio-only candidates carry only the timing fields. The
/// notation layer is expected to render every candidate; uncertainty is
/// expressed via `kind == .uncertain` and `uncertaintyReason`, not by
/// dropping the row.
public struct NotationCandidate: Codable, Equatable, Sendable {

    /// What kind of event this candidate represents.
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Audio onset only — we know a sound started, identity unknown.
        case onset
        /// A short break / cut between strokes. Has an `endTimestamp`.
        case cut
        /// A confidently-identified stroke (audio + supporting evidence).
        case stroke
        /// A region where audio fell below the silence floor for at least
        /// `silenceGapMinSeconds`. Has an `endTimestamp`.
        case silenceGap
        /// We're confident *something* happened here, but classifier or
        /// motion evidence was insufficient to label it. Render with a
        /// distinct visual treatment in the UI.
        case uncertain
    }

    /// Where this candidate's evidence originated. `fused` means multiple
    /// modalities agreed.
    public enum Source: String, Codable, Equatable, Sendable {
        case audioOnset
        case motion
        case classifier
        case fused
    }

    public let timestamp: TimeInterval
    public let endTimestamp: TimeInterval?
    public let kind: Kind
    public let strength: Double
    public let audioConfidence: Double?
    public let motionConfidence: Double?
    public let classifierConfidence: Double?
    public let predictedFamily: String?
    public let predictedClass: ScratchClassLabel?
    public let uncertaintyReason: String?
    public let source: Source

    public init(
        timestamp: TimeInterval,
        kind: Kind = .onset,
        strength: Double,
        endTimestamp: TimeInterval? = nil,
        audioConfidence: Double? = nil,
        motionConfidence: Double? = nil,
        classifierConfidence: Double? = nil,
        predictedFamily: String? = nil,
        predictedClass: ScratchClassLabel? = nil,
        uncertaintyReason: String? = nil,
        source: Source = .audioOnset
    ) {
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.kind = kind
        self.strength = strength
        self.audioConfidence = audioConfidence
        self.motionConfidence = motionConfidence
        self.classifierConfidence = classifierConfidence
        self.predictedFamily = predictedFamily
        self.predictedClass = predictedClass
        self.uncertaintyReason = uncertaintyReason
        self.source = source
    }

    /// Duration in seconds when `endTimestamp` is present, else nil.
    public var duration: TimeInterval? {
        endTimestamp.map { $0 - timestamp }
    }

    /// True when identity (class or family) is attached.
    public var hasIdentity: Bool {
        predictedClass != nil || predictedFamily != nil
    }
}
