//
//  NotationCandidateBuilder.swift
//  ScratchLab
//
//  Slice N: combines audio-onset candidates with optional motion /
//  classifier evidence into a final timeline.
//
//  Product invariant (this file is the enforcer):
//
//      Audio-onset candidates are NEVER deleted because identity is
//      missing or low-confidence. Instead they are kept and either
//      labelled (when fused confidence is high enough) or downgraded to
//      `.uncertain` with an `uncertaintyReason` string.
//
//  Inputs:
//    * `audioCandidates` — emitted by `AudioOnsetDetector`.
//    * `evidence`        — optional per-stamp classifier / motion
//      evidence. Each evidence record applies to candidates whose
//      timestamp falls within `evidenceMatchWindow`.
//
//  Output:
//    * `[NotationCandidate]` sorted by timestamp, every input audio
//      candidate represented exactly once.
//

import Foundation

/// One supporting-evidence record from the classifier and/or motion
/// pipelines. The builder will attach this evidence to any onset
/// whose timestamp lies within `evidenceMatchWindow` of `timestamp`.
public struct LabelEvidence: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let predictedClass: ScratchClassLabel?
    public let predictedFamily: String?
    public let classifierConfidence: Double?
    public let motionConfidence: Double?

    public init(
        timestamp: TimeInterval,
        predictedClass: ScratchClassLabel? = nil,
        predictedFamily: String? = nil,
        classifierConfidence: Double? = nil,
        motionConfidence: Double? = nil
    ) {
        self.timestamp = timestamp
        self.predictedClass = predictedClass
        self.predictedFamily = predictedFamily
        self.classifierConfidence = classifierConfidence
        self.motionConfidence = motionConfidence
    }
}

public struct NotationCandidateBuilderConfig: Equatable, Sendable {

    /// Half-window (in seconds) used to associate evidence to an onset.
    /// An onset at `t` matches evidence within `[t - w, t + w]`.
    public var evidenceMatchWindow: TimeInterval

    /// Minimum classifier confidence required to attach a label and
    /// upgrade `kind` from `.onset` to `.stroke`.
    public var labelMinClassifierConfidence: Double

    /// Minimum fusion confidence (audio + classifier + motion) required
    /// to upgrade an `.onset` to `.stroke`. Below this, the candidate
    /// stays as `.onset` (when no evidence matched) or becomes
    /// `.uncertain` (when evidence matched but was too weak).
    public var labelMinFusionConfidence: Double

    /// Fusion weights. The builder normalises across present modalities,
    /// so missing modalities (e.g. no motion) don't penalise the score.
    public var weightAudio: Double
    public var weightClassifier: Double
    public var weightMotion: Double

    public init(
        evidenceMatchWindow: TimeInterval = 0.150,
        labelMinClassifierConfidence: Double = 0.50,
        labelMinFusionConfidence: Double = 0.55,
        weightAudio: Double = 0.40,
        weightClassifier: Double = 0.40,
        weightMotion: Double = 0.20
    ) {
        self.evidenceMatchWindow = evidenceMatchWindow
        self.labelMinClassifierConfidence = labelMinClassifierConfidence
        self.labelMinFusionConfidence = labelMinFusionConfidence
        self.weightAudio = weightAudio
        self.weightClassifier = weightClassifier
        self.weightMotion = weightMotion
    }

    public static let `default` = NotationCandidateBuilderConfig()
}

public struct NotationCandidateBuilder: Sendable {

    public let config: NotationCandidateBuilderConfig

    public init(config: NotationCandidateBuilderConfig = .default) {
        self.config = config
    }

    /// Build the final timeline.
    ///
    /// - Parameters:
    ///   - audioCandidates: output of `AudioOnsetDetector.detect(...)`.
    ///   - evidence: optional supporting evidence; default is empty,
    ///     in which case audio candidates pass through unchanged.
    /// - Returns: timeline sorted by timestamp. Every audio onset is
    ///   represented exactly once, identity attached when fusion is
    ///   confident, otherwise downgraded to `.uncertain` (when
    ///   evidence existed but was weak) or kept as the original
    ///   `.onset` (when no evidence matched).
    public func buildTimeline(
        audioCandidates: [NotationCandidate],
        evidence: [LabelEvidence] = []
    ) -> [NotationCandidate] {
        // Pre-sort evidence so the per-onset lookup is linear-ish.
        let sortedEvidence = evidence.sorted { $0.timestamp < $1.timestamp }

        var output: [NotationCandidate] = []
        output.reserveCapacity(audioCandidates.count)

        for cand in audioCandidates {
            // Silence gaps and existing strokes / cuts pass through.
            if cand.kind != .onset {
                output.append(cand)
                continue
            }
            guard let match = nearestEvidence(to: cand.timestamp, in: sortedEvidence) else {
                output.append(cand)
                continue
            }
            output.append(combine(onset: cand, evidence: match))
        }
        return output.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Internals

    func nearestEvidence(to timestamp: TimeInterval, in sorted: [LabelEvidence]) -> LabelEvidence? {
        guard !sorted.isEmpty else { return nil }
        let window = config.evidenceMatchWindow
        var best: LabelEvidence?
        var bestDelta = TimeInterval.infinity
        // Linear scan is fine — these arrays are tiny in practice and
        // we never want to break the contract of "associate by nearest
        // within window".
        for ev in sorted {
            let delta = abs(ev.timestamp - timestamp)
            if delta > window { continue }
            if delta < bestDelta {
                bestDelta = delta
                best = ev
            }
        }
        return best
    }

    func combine(onset: NotationCandidate, evidence: LabelEvidence) -> NotationCandidate {
        let fusion = fusedConfidence(
            audio: onset.audioConfidence,
            classifier: evidence.classifierConfidence,
            motion: evidence.motionConfidence
        )
        let classifierOK = (evidence.classifierConfidence ?? 0) >= config.labelMinClassifierConfidence
        let fusionOK = fusion >= config.labelMinFusionConfidence
        let identityAvailable = evidence.predictedClass != nil || evidence.predictedFamily != nil

        // High-confidence stroke: upgrade to `.stroke`, attach identity.
        if classifierOK && fusionOK && identityAvailable {
            return NotationCandidate(
                timestamp: onset.timestamp,
                kind: .stroke,
                strength: onset.strength,
                endTimestamp: onset.endTimestamp,
                audioConfidence: onset.audioConfidence,
                motionConfidence: evidence.motionConfidence,
                classifierConfidence: evidence.classifierConfidence,
                predictedFamily: evidence.predictedFamily,
                predictedClass: evidence.predictedClass,
                uncertaintyReason: nil,
                source: .fused
            )
        }

        // Evidence existed but was too weak / had no identity. Preserve
        // the candidate as `.uncertain` with a reason — never delete it.
        let reason = uncertaintyReason(
            classifierConfidence: evidence.classifierConfidence,
            fusion: fusion,
            identityAvailable: identityAvailable
        )
        return NotationCandidate(
            timestamp: onset.timestamp,
            kind: .uncertain,
            strength: onset.strength,
            endTimestamp: onset.endTimestamp,
            audioConfidence: onset.audioConfidence,
            motionConfidence: evidence.motionConfidence,
            classifierConfidence: evidence.classifierConfidence,
            predictedFamily: evidence.predictedFamily,
            predictedClass: evidence.predictedClass,
            uncertaintyReason: reason,
            source: .fused
        )
    }

    func fusedConfidence(audio: Double?, classifier: Double?, motion: Double?) -> Double {
        var weightSum = 0.0
        var score = 0.0
        if let a = audio { score += config.weightAudio * a; weightSum += config.weightAudio }
        if let c = classifier { score += config.weightClassifier * c; weightSum += config.weightClassifier }
        if let m = motion { score += config.weightMotion * m; weightSum += config.weightMotion }
        return weightSum > 0 ? score / weightSum : 0
    }

    func uncertaintyReason(classifierConfidence: Double?, fusion: Double, identityAvailable: Bool) -> String {
        if !identityAvailable {
            return "evidence present but no class/family attached"
        }
        if let c = classifierConfidence, c < config.labelMinClassifierConfidence {
            return "classifier confidence \(String(format: "%.2f", c)) below threshold \(String(format: "%.2f", config.labelMinClassifierConfidence))"
        }
        if fusion < config.labelMinFusionConfidence {
            return "fusion confidence \(String(format: "%.2f", fusion)) below threshold \(String(format: "%.2f", config.labelMinFusionConfidence))"
        }
        return "evidence too weak to label confidently"
    }
}
