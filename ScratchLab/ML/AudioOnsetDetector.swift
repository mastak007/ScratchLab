//
//  AudioOnsetDetector.swift
//  ScratchLab
//
//  Slice N: pure-Swift, deterministic onset detector. No UI dependency,
//  no Combine, no AVFoundation. Takes either raw mono PCM samples or a
//  pre-computed RMS envelope and returns `[NotationCandidate]`.
//
//  Why time-domain (no FFT)?
//    * Onsets in scratching are dominated by sudden energy changes.
//      A log-RMS novelty function captures them reliably.
//    * Avoiding FFT keeps the implementation deterministic across
//      platforms and trivially unit-testable from synthetic input.
//    * A spectral version can be added later behind the same protocol
//      without breaking callers.
//
//  Algorithm:
//    1. Frame the input at `frameSize` with `hopSize` step.
//    2. Per frame: RMS → log-RMS in dBFS.
//    3. Novelty[n] = max(0, logRMS[n] − logRMS[n−1]).
//    4. Adaptive threshold per frame = local-window median + multiplier *
//       local-window MAD (median absolute deviation). Robust to outliers.
//    5. Peak pick: novelty above threshold AND a strict local maximum AND
//       last accepted onset older than `minOnsetSpacingSeconds`.
//    6. Optional silence-gap pass: stretches where dB < silenceFloor for
//       at least `silenceGapMinSeconds` produce `.silenceGap` candidates.
//

import Foundation

public struct AudioOnsetDetectorConfig: Equatable, Sendable {

    /// Sample rate of the input PCM. Ignored when calling the
    /// envelope-based detection entry point — that one takes
    /// `frameDurationSeconds` directly.
    public var sampleRate: Double

    /// Window size used to compute per-frame RMS.
    public var frameSize: Int

    /// Step between successive frames. Determines time resolution
    /// (≈ `hopSize / sampleRate` seconds per frame).
    public var hopSize: Int

    /// Below this dBFS the frame is treated as silence (no onset can
    /// fire here). Same floor used for `.silenceGap` detection.
    public var silenceFloorDB: Double

    /// Multiplier on the local MAD when computing the adaptive threshold.
    /// Higher = stricter (fewer onsets).
    public var thresholdMultiplier: Double

    /// Half-width (in frames) of the local window used for the adaptive
    /// threshold. The full window covers `2*localWindowHalfFrames + 1`
    /// frames around each candidate.
    public var localWindowHalfFrames: Int

    /// Minimum spacing between successive accepted onsets. Suppresses
    /// double-triggers from a single attack.
    public var minOnsetSpacingSeconds: TimeInterval

    /// Minimum gap duration (frames-below-floor) to emit a `.silenceGap`
    /// candidate.
    public var silenceGapMinSeconds: TimeInterval

    /// Toggle silence-gap pass.
    public var detectSilenceGaps: Bool

    public init(
        sampleRate: Double = 44_100,
        frameSize: Int = 1024,
        hopSize: Int = 512,
        silenceFloorDB: Double = -45.0,
        thresholdMultiplier: Double = 2.5,
        localWindowHalfFrames: Int = 8,
        minOnsetSpacingSeconds: TimeInterval = 0.06,
        silenceGapMinSeconds: TimeInterval = 0.20,
        detectSilenceGaps: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.hopSize = hopSize
        self.silenceFloorDB = silenceFloorDB
        self.thresholdMultiplier = thresholdMultiplier
        self.localWindowHalfFrames = localWindowHalfFrames
        self.minOnsetSpacingSeconds = minOnsetSpacingSeconds
        self.silenceGapMinSeconds = silenceGapMinSeconds
        self.detectSilenceGaps = detectSilenceGaps
    }

    public static let `default` = AudioOnsetDetectorConfig()
}

public struct AudioOnsetDetector: Sendable {

    public let config: AudioOnsetDetectorConfig

    public init(config: AudioOnsetDetectorConfig = .default) {
        self.config = config
    }

    /// Detect candidates from raw mono PCM `Float` samples in `[-1, 1]`.
    public func detect(samples: [Float]) -> [NotationCandidate] {
        let envelope = computeLogRMSEnvelope(samples: samples)
        let frameDuration = Double(config.hopSize) / config.sampleRate
        return detectFromLogRMS(envelope: envelope, frameDurationSeconds: frameDuration)
    }

    /// Detect candidates from a pre-computed log-RMS envelope (dBFS values
    /// at uniform `frameDurationSeconds` spacing).
    public func detect(envelopeDB: [Double], frameDurationSeconds: TimeInterval) -> [NotationCandidate] {
        return detectFromLogRMS(envelope: envelopeDB, frameDurationSeconds: frameDurationSeconds)
    }

    // MARK: Internals

    /// Per-frame log-RMS in dBFS. Uses non-overlapping framing of size
    /// `hopSize`; the `frameSize` field is held for future API symmetry
    /// with overlapping-frame strategies but the time-domain RMS over
    /// non-overlapping hops is sufficient for onset detection.
    func computeLogRMSEnvelope(samples: [Float]) -> [Double] {
        guard !samples.isEmpty, config.hopSize > 0 else { return [] }
        let hop = config.hopSize
        let frameCount = samples.count / hop
        var out = [Double](repeating: -120.0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * hop
            let end = min(start + hop, samples.count)
            var sumSq = 0.0
            for j in start..<end {
                let s = Double(samples[j])
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Double(max(1, end - start)))
            out[i] = 20.0 * log10(max(rms, 1e-10))
        }
        return out
    }

    func detectFromLogRMS(envelope: [Double], frameDurationSeconds: TimeInterval) -> [NotationCandidate] {
        guard envelope.count >= 3, frameDurationSeconds > 0 else { return [] }

        // Novelty function: half-wave-rectified positive change in log-RMS.
        var novelty = [Double](repeating: 0, count: envelope.count)
        for i in 1..<envelope.count {
            let delta = envelope[i] - envelope[i - 1]
            novelty[i] = max(0, delta)
        }

        // Adaptive threshold: local median + multiplier * local MAD.
        let half = max(1, config.localWindowHalfFrames)
        let mult = config.thresholdMultiplier
        var threshold = [Double](repeating: 0, count: envelope.count)
        var window = [Double](repeating: 0, count: 2 * half + 1)
        for i in 0..<envelope.count {
            let lo = max(0, i - half)
            let hi = min(envelope.count - 1, i + half)
            let span = hi - lo + 1
            for k in 0..<span { window[k] = novelty[lo + k] }
            let med = median(of: window, count: span)
            let mad = medianAbsoluteDeviation(of: window, count: span, median: med)
            // A small floor on the threshold prevents trivial peaks
            // when the signal is essentially silent.
            threshold[i] = max(med + mult * mad, 0.5)
        }

        // Minimum onset spacing in frames.
        let spacingFrames = max(1, Int(ceil(config.minOnsetSpacingSeconds / frameDurationSeconds)))

        // Peak pick.
        var onsets: [NotationCandidate] = []
        var lastAcceptedIndex = -spacingFrames - 1
        for i in 1..<(envelope.count - 1) {
            if envelope[i] < config.silenceFloorDB { continue }
            let n = novelty[i]
            if n <= threshold[i] { continue }
            if !(n >= novelty[i - 1] && n >= novelty[i + 1]) { continue }
            // Strict local max — equality OK on either side, but require
            // strict on at least one side to avoid plateau double-fires.
            if n == novelty[i - 1] && n == novelty[i + 1] { continue }
            if (i - lastAcceptedIndex) < spacingFrames { continue }
            lastAcceptedIndex = i
            // Map novelty to an audioConfidence in [0, 1] using the
            // ratio of novelty to threshold. Confidence is bounded.
            let ratio = threshold[i] > 0 ? min(1.0, n / (threshold[i] * 2.0)) : 0.5
            onsets.append(NotationCandidate(
                timestamp: Double(i) * frameDurationSeconds,
                kind: .onset,
                strength: n,
                audioConfidence: ratio,
                source: .audioOnset
            ))
        }

        // Optional silence-gap pass.
        if config.detectSilenceGaps {
            let minGapFrames = max(1, Int(ceil(config.silenceGapMinSeconds / frameDurationSeconds)))
            var gapStart: Int? = nil
            for i in 0..<envelope.count {
                let isSilent = envelope[i] < config.silenceFloorDB
                if isSilent {
                    if gapStart == nil { gapStart = i }
                } else if let s = gapStart {
                    if i - s >= minGapFrames {
                        onsets.append(NotationCandidate(
                            timestamp: Double(s) * frameDurationSeconds,
                            kind: .silenceGap,
                            strength: 0,
                            endTimestamp: Double(i) * frameDurationSeconds,
                            audioConfidence: 1.0,
                            source: .audioOnset
                        ))
                    }
                    gapStart = nil
                }
            }
            if let s = gapStart, envelope.count - s >= minGapFrames {
                onsets.append(NotationCandidate(
                    timestamp: Double(s) * frameDurationSeconds,
                    kind: .silenceGap,
                    strength: 0,
                    endTimestamp: Double(envelope.count) * frameDurationSeconds,
                    audioConfidence: 1.0,
                    source: .audioOnset
                ))
            }
        }

        return onsets.sorted { $0.timestamp < $1.timestamp }
    }

    private func median(of buffer: [Double], count: Int) -> Double {
        guard count > 0 else { return 0 }
        var slice = Array(buffer.prefix(count))
        slice.sort()
        if count % 2 == 1 { return slice[count / 2] }
        return 0.5 * (slice[count / 2 - 1] + slice[count / 2])
    }

    private func medianAbsoluteDeviation(of buffer: [Double], count: Int, median: Double) -> Double {
        guard count > 0 else { return 0 }
        var dev = [Double](repeating: 0, count: count)
        for i in 0..<count { dev[i] = abs(buffer[i] - median) }
        dev.sort()
        if count % 2 == 1 { return dev[count / 2] }
        return 0.5 * (dev[count / 2 - 1] + dev[count / 2])
    }
}
