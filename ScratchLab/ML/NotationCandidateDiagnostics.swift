//
//  NotationCandidateDiagnostics.swift
//  ScratchLab
//
//  Slice O: pure-Swift, deterministic diagnostics surface that turns a
//  stream of audio samples into a `NotationCandidateDiagnosticsSummary`
//  using the existing `AudioOnsetDetector`. No UI, no Combine, no
//  AVFoundation, no model files. Lives in ScratchLab/ML/ so the SwiftPM
//  ScratchLabML library can unit-test it identically to how the iOS app
//  compiles it.
//
//  Product invariant (inherited from Slice N): low classifier confidence
//  must NOT delete candidates. This file only summarises — it never
//  filters out uncertain or unidentified candidates. The summary
//  exposes counts so the diagnostics view can show "Identity: not
//  classified" honestly when nothing is identified yet.
//

import Foundation

/// Aggregate snapshot of the candidates currently detectable from the
/// accumulated audio envelope. Codable + Equatable so it can be inspected
/// in tests, persisted to a debug log on demand, or rendered directly.
public struct NotationCandidateDiagnosticsSummary: Codable, Equatable, Sendable {
    public let candidateCount: Int
    public let onsetCount: Int
    public let strokeCount: Int
    public let uncertainCount: Int
    public let silenceGapCount: Int
    public let cutCount: Int
    public let firstTimestamp: TimeInterval?
    public let lastTimestamp: TimeInterval?
    public let meanStrength: Double
    public let strongestStrength: Double
    public let envelopeFrameCount: Int
    public let envelopeDurationSeconds: TimeInterval
    public let isClassified: Bool

    public init(
        candidateCount: Int,
        onsetCount: Int,
        strokeCount: Int,
        uncertainCount: Int,
        silenceGapCount: Int,
        cutCount: Int,
        firstTimestamp: TimeInterval?,
        lastTimestamp: TimeInterval?,
        meanStrength: Double,
        strongestStrength: Double,
        envelopeFrameCount: Int,
        envelopeDurationSeconds: TimeInterval,
        isClassified: Bool
    ) {
        self.candidateCount = candidateCount
        self.onsetCount = onsetCount
        self.strokeCount = strokeCount
        self.uncertainCount = uncertainCount
        self.silenceGapCount = silenceGapCount
        self.cutCount = cutCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.meanStrength = meanStrength
        self.strongestStrength = strongestStrength
        self.envelopeFrameCount = envelopeFrameCount
        self.envelopeDurationSeconds = envelopeDurationSeconds
        self.isClassified = isClassified
    }

    public static let empty = NotationCandidateDiagnosticsSummary(
        candidateCount: 0,
        onsetCount: 0,
        strokeCount: 0,
        uncertainCount: 0,
        silenceGapCount: 0,
        cutCount: 0,
        firstTimestamp: nil,
        lastTimestamp: nil,
        meanStrength: 0,
        strongestStrength: 0,
        envelopeFrameCount: 0,
        envelopeDurationSeconds: 0,
        isClassified: false
    )

    /// Build a summary from a sorted list of candidates. Mean / strongest
    /// strength are computed over stroke-like kinds (onset, stroke,
    /// uncertain, cut) — `silenceGap` candidates carry zero strength by
    /// construction and are reported separately as `silenceGapCount`.
    public static func summarize(
        candidates: [NotationCandidate],
        envelopeFrameCount: Int = 0,
        envelopeDurationSeconds: TimeInterval = 0
    ) -> NotationCandidateDiagnosticsSummary {
        var onset = 0, stroke = 0, uncertain = 0, gap = 0, cut = 0
        var first: TimeInterval? = nil
        var last: TimeInterval? = nil
        var sumStrength = 0.0
        var countStrength = 0
        var strongest = 0.0
        var classified = false

        for c in candidates {
            switch c.kind {
            case .onset:      onset += 1
            case .stroke:     stroke += 1
            case .uncertain:  uncertain += 1
            case .silenceGap: gap += 1
            case .cut:        cut += 1
            }
            if c.kind != .silenceGap {
                if first == nil { first = c.timestamp }
                last = c.timestamp
                sumStrength += c.strength
                countStrength += 1
                if c.strength > strongest { strongest = c.strength }
            }
            if c.hasIdentity { classified = true }
        }

        let mean = countStrength > 0 ? sumStrength / Double(countStrength) : 0.0
        return NotationCandidateDiagnosticsSummary(
            candidateCount: candidates.count,
            onsetCount: onset,
            strokeCount: stroke,
            uncertainCount: uncertain,
            silenceGapCount: gap,
            cutCount: cut,
            firstTimestamp: first,
            lastTimestamp: last,
            meanStrength: mean,
            strongestStrength: strongest,
            envelopeFrameCount: envelopeFrameCount,
            envelopeDurationSeconds: envelopeDurationSeconds,
            isClassified: classified
        )
    }
}

/// Streams audio samples in, maintains a bounded log-RMS envelope, and
/// produces `NotationCandidateDiagnosticsSummary` snapshots on demand.
///
/// The accumulator is single-threaded; if a caller needs concurrent
/// pushes/queries it must wrap calls in its own queue or actor. Tests
/// drive it synchronously.
public final class NotationCandidateAccumulator {

    public let detectorConfig: AudioOnsetDetectorConfig
    public let capacityFrames: Int

    private let hopSize: Int
    private var detector: AudioOnsetDetector
    private var observedSampleRate: Double?
    private var frameDuration: TimeInterval = 0
    private var residualSamples: [Float] = []
    private var envelope: [Double] = []

    public init(
        detectorConfig: AudioOnsetDetectorConfig = .default,
        capacityFrames: Int = 8192
    ) {
        self.detectorConfig = detectorConfig
        self.capacityFrames = max(1, capacityFrames)
        self.hopSize = max(1, detectorConfig.hopSize)
        self.detector = AudioOnsetDetector(config: detectorConfig)
    }

    public var envelopeFrameCount: Int { envelope.count }
    public var sampleRate: Double? { observedSampleRate }

    /// Push raw mono PCM samples in `[-1, 1]` at the given sample rate.
    /// The first call locks the accumulator to that sample rate; if a
    /// later call passes a different rate the buffer is reset to
    /// preserve frame-time consistency in the published summary.
    public func pushSamples(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        if let prev = observedSampleRate, prev != sampleRate {
            reset()
        }
        if observedSampleRate == nil {
            observedSampleRate = sampleRate
            frameDuration = Double(hopSize) / sampleRate
            var cfg = detectorConfig
            cfg.sampleRate = sampleRate
            detector = AudioOnsetDetector(config: cfg)
        }

        residualSamples.append(contentsOf: samples)
        let hop = self.hopSize
        var consumed = 0
        while consumed + hop <= residualSamples.count {
            var sumSq = 0.0
            let end = consumed + hop
            for j in consumed..<end {
                let s = Double(residualSamples[j])
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Double(hop))
            envelope.append(20.0 * log10(max(rms, 1e-10)))
            consumed += hop
        }
        if consumed > 0 {
            residualSamples.removeFirst(consumed)
        }
        if envelope.count > capacityFrames {
            envelope.removeFirst(envelope.count - capacityFrames)
        }
    }

    /// Run the detector against the current envelope and return a
    /// summary. Cheap enough to call on every UI tick — the detector is
    /// O(n) over the bounded envelope.
    public func currentSummary() -> NotationCandidateDiagnosticsSummary {
        guard !envelope.isEmpty, frameDuration > 0 else { return .empty }
        let candidates = detector.detect(
            envelopeDB: envelope,
            frameDurationSeconds: frameDuration
        )
        let duration = Double(envelope.count) * frameDuration
        return .summarize(
            candidates: candidates,
            envelopeFrameCount: envelope.count,
            envelopeDurationSeconds: duration
        )
    }

    /// Slice R0 — same envelope, stricter detector pass, capped output.
    /// Used to feed the Review preview surface so reviewers see a few
    /// dozen meaningful timing candidates instead of hundreds of noisy
    /// transients. Defaults to `AudioOnsetDetectorConfig.reviewPreview`
    /// for the detector pass and an 80-candidate cap as a fail-safe; if
    /// the stricter config already produces fewer than `maxCandidates`
    /// the cap is a no-op (verified by tests). Caller may override
    /// either knob; raw / Advanced reporting continues to use
    /// `currentSummary()` unchanged.
    public func currentReviewSummary(
        detectorConfig: AudioOnsetDetectorConfig = .reviewPreview,
        maxCandidates: Int = 80
    ) -> NotationCandidateDiagnosticsSummary {
        guard let capped = computeReviewCandidates(
            detectorConfig: detectorConfig,
            maxCandidates: maxCandidates
        ) else { return .empty }
        let duration = Double(envelope.count) * frameDuration
        return .summarize(
            candidates: capped,
            envelopeFrameCount: envelope.count,
            envelopeDurationSeconds: duration
        )
    }

    /// Slice R1 — timestamps of the stroke-like candidates that feed the
    /// Review preview, after the same stricter detector pass + cap that
    /// `currentReviewSummary` uses. Returned in ascending timestamp order.
    /// Silence-gap candidates are excluded — they aren't strokes and have
    /// no place on a timing-mark strip. This is the only API meant to
    /// drive Review visual timing marks; raw `currentSummary()` output
    /// must not be used for Review marks because it over-emits and is
    /// uncapped.
    public func currentReviewMarks(
        detectorConfig: AudioOnsetDetectorConfig = .reviewPreview,
        maxCandidates: Int = 80
    ) -> [TimeInterval] {
        guard let capped = computeReviewCandidates(
            detectorConfig: detectorConfig,
            maxCandidates: maxCandidates
        ) else { return [] }
        return capped
            .filter { $0.kind != .silenceGap }
            .map(\.timestamp)
    }

    private func computeReviewCandidates(
        detectorConfig: AudioOnsetDetectorConfig,
        maxCandidates: Int
    ) -> [NotationCandidate]? {
        guard !envelope.isEmpty, frameDuration > 0 else { return nil }
        var cfg = detectorConfig
        if let observed = observedSampleRate {
            cfg.sampleRate = observed
        }
        let reviewDetector = AudioOnsetDetector(config: cfg)
        let raw = reviewDetector.detect(
            envelopeDB: envelope,
            frameDurationSeconds: frameDuration
        )
        return NotationCandidateAccumulator.capCandidatesByStrength(
            raw,
            maxCount: maxCandidates
        )
    }

    /// If `candidates.count <= maxCount` returns the input unchanged.
    /// Otherwise keeps the `maxCount` strongest candidates (by
    /// `strength`) and returns them re-sorted by `timestamp` so the
    /// summary's `firstTimestamp` / `lastTimestamp` semantics still
    /// hold. Silence gaps are kept verbatim — they don't compete for
    /// the strength-ranked slot.
    static func capCandidatesByStrength(
        _ candidates: [NotationCandidate],
        maxCount: Int
    ) -> [NotationCandidate] {
        guard maxCount > 0 else { return [] }
        let gaps = candidates.filter { $0.kind == .silenceGap }
        let strokeLike = candidates.filter { $0.kind != .silenceGap }
        if strokeLike.count <= maxCount { return candidates }
        let topN = strokeLike
            .sorted { $0.strength > $1.strength }
            .prefix(maxCount)
        let combined = Array(topN) + gaps
        return combined.sorted { $0.timestamp < $1.timestamp }
    }

    /// Drop all buffered samples and envelope frames. The next push
    /// re-locks to the supplied sample rate.
    public func reset() {
        envelope.removeAll(keepingCapacity: true)
        residualSamples.removeAll(keepingCapacity: true)
        observedSampleRate = nil
        frameDuration = 0
    }
}
