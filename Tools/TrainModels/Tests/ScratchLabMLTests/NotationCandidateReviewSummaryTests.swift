//
//  NotationCandidateReviewSummaryTests.swift
//  ScratchLabMLTests — Slice R0
//
//  Behavioural coverage required by the slice spec:
//    * dense / noisy onsets get gated heavily by currentReviewSummary
//      while currentSummary keeps surfacing them all
//    * strong, well-separated onsets survive the Review gate ~1:1
//    * low-strength near-silence input doesn't flood Review with
//      candidates
//    * silence gaps never appear in the Review summary (detectSilenceGaps
//      is off in the review preset)
//    * the strength-ranked cap keeps the highest-strength candidates and
//      preserves time order; silence gaps pass through verbatim
//    * Slice P invariant carries through: uncertain candidates aren't
//      filtered out by the cap when there's room for them
//

import XCTest
@testable import ScratchLabML

final class NotationCandidateReviewSummaryTests: XCTestCase {

    private let sampleRate: Double = 44_100

    // MARK: Helpers

    private func makeImpulseSignal(
        durationSeconds: Double,
        impulseTimes: [Double],
        impulsePeak: Float = 0.7
    ) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var s = [Float](repeating: 0, count: count)
        for t in impulseTimes {
            let centre = Int(t * sampleRate)
            for offset in -32...32 {
                let i = centre + offset
                if i >= 0 && i < count {
                    s[i] += impulsePeak * Float(exp(-(Double(offset * offset)) / 80.0))
                }
            }
        }
        return s
    }

    // MARK: Detector preset surface

    func testReviewPresetIsStricterOnAllThreeKnobs() {
        let def = AudioOnsetDetectorConfig.default
        let review = AudioOnsetDetectorConfig.reviewPreview
        XCTAssertGreaterThan(review.silenceFloorDB, def.silenceFloorDB,
                             "review floor must be higher (less permissive)")
        XCTAssertGreaterThan(review.thresholdMultiplier, def.thresholdMultiplier,
                             "review threshold multiplier must be stricter")
        XCTAssertGreaterThan(review.minOnsetSpacingSeconds, def.minOnsetSpacingSeconds,
                             "review minimum spacing must be stricter")
        XCTAssertFalse(review.detectSilenceGaps,
                       "review preset should not emit silence-gap rows")
    }

    // MARK: Filter behaviour — dense vs sparse

    /// 30 impulses 80 ms apart: tighter than the review 200 ms spacing.
    /// `currentSummary()` should pick up most of them; the Review pass
    /// must collapse the run substantially.
    func testDenseImpulsesAreGatedForReview() {
        let acc = NotationCandidateAccumulator()
        let times = (0..<30).map { Double($0) * 0.08 + 0.20 }   // 0.20s, 0.28s, …
        let signal = makeImpulseSignal(durationSeconds: 3.0, impulseTimes: times)
        acc.pushSamples(signal, sampleRate: sampleRate)

        let raw = acc.currentSummary()
        let review = acc.currentReviewSummary()

        XCTAssertGreaterThan(raw.onsetCount, 20,
                             "default detector should still catch most of the dense run")
        XCTAssertLessThan(review.onsetCount + review.strokeCount, raw.onsetCount,
                          "review summary must be strictly smaller than raw on dense input")
        // 200 ms spacing on a 3 s span → at most ~15 onsets.
        XCTAssertLessThanOrEqual(review.onsetCount, 15)
    }

    /// Strong, well-separated impulses should survive both passes ~1:1.
    func testStrongSeparatedImpulsesSurviveReviewGate() {
        let acc = NotationCandidateAccumulator()
        let times = [0.30, 0.90, 1.60, 2.20, 2.80]  // ≥ 600 ms apart
        let signal = makeImpulseSignal(durationSeconds: 3.2,
                                       impulseTimes: times,
                                       impulsePeak: 0.85)
        acc.pushSamples(signal, sampleRate: sampleRate)

        let review = acc.currentReviewSummary()
        XCTAssertEqual(review.onsetCount, times.count,
                       "strong, well-separated impulses must all survive the Review gate")
        XCTAssertNotNil(review.firstTimestamp)
        XCTAssertNotNil(review.lastTimestamp)
    }

    /// Quiet, ambient-like signal: the review preset's −40 dB floor +
    /// 4× threshold should keep these out entirely.
    func testLowAmplitudeAmbientDoesNotFloodReview() {
        let acc = NotationCandidateAccumulator()
        // Random low-amplitude noise around −50 dBFS — below the
        // review preset's −40 dB floor but above default's −45 dB.
        let count = Int(2.0 * sampleRate)
        var state: UInt64 = 0xBEEF
        var s = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Double(state >> 32) / Double(UInt32.max)) * 2 - 1
            s[i] = u * 0.003     // ≈ −50 dBFS
        }
        acc.pushSamples(s, sampleRate: sampleRate)

        let review = acc.currentReviewSummary()
        XCTAssertEqual(review.onsetCount + review.strokeCount + review.uncertainCount, 0,
                       "review must not flood when input is ambient-quiet")
    }

    /// Silence gaps must not surface in the Review summary regardless
    /// of how the underlying audio looks. The review preset disables
    /// gap detection.
    func testReviewSummaryDoesNotIncludeSilenceGaps() {
        let acc = NotationCandidateAccumulator()
        // Loud onset, then 1 s of silence, then another onset — would
        // produce a silence gap row under the default detector.
        var signal = makeImpulseSignal(durationSeconds: 2.0,
                                       impulseTimes: [0.20, 1.60])
        for i in Int(0.30 * sampleRate)..<Int(1.50 * sampleRate) {
            signal[i] = 0
        }
        acc.pushSamples(signal, sampleRate: sampleRate)

        let raw = acc.currentSummary()
        let review = acc.currentReviewSummary()
        XCTAssertGreaterThan(raw.silenceGapCount, 0,
                             "sanity: default detector should still flag silence gaps")
        XCTAssertEqual(review.silenceGapCount, 0,
                       "review summary must not include silence-gap rows")
    }

    // MARK: capCandidatesByStrength

    func testCapKeepsStrongestAndReSortsByTimestamp() {
        // Strengths increase with timestamp, so the strongest are
        // chronologically late. After capping at 3 we should keep the
        // last three, but the returned array must still be ordered by
        // timestamp ascending.
        let candidates: [NotationCandidate] = (1...6).map { i in
            NotationCandidate(
                timestamp: Double(i) * 0.10,
                kind: .onset,
                strength: Double(i),
                audioConfidence: 0.5,
                source: .audioOnset
            )
        }
        let capped = NotationCandidateAccumulator.capCandidatesByStrength(
            candidates, maxCount: 3
        )
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(capped.map(\.timestamp)[0], 0.40, accuracy: 1e-9)
        XCTAssertEqual(capped.map(\.timestamp)[1], 0.50, accuracy: 1e-9)
        XCTAssertEqual(capped.map(\.timestamp)[2], 0.60, accuracy: 1e-9)
        XCTAssertEqual(capped.map(\.strength), [4.0, 5.0, 6.0])
    }

    func testCapBelowInputCountIsIdentity() {
        let candidates: [NotationCandidate] = (1...3).map { i in
            NotationCandidate(timestamp: Double(i) * 0.1, kind: .onset,
                              strength: Double(i), source: .audioOnset)
        }
        let capped = NotationCandidateAccumulator.capCandidatesByStrength(
            candidates, maxCount: 10
        )
        XCTAssertEqual(capped, candidates)
    }

    func testCapPreservesSilenceGapsVerbatim() {
        // 1 gap + 4 strokes; cap at 2 → 2 strongest strokes + the gap.
        let gap = NotationCandidate(
            timestamp: 0.05, kind: .silenceGap, strength: 0,
            endTimestamp: 0.15, audioConfidence: 1.0, source: .audioOnset
        )
        let strokes: [NotationCandidate] = (1...4).map { i in
            NotationCandidate(timestamp: 0.20 + Double(i) * 0.05,
                              kind: .onset, strength: Double(i),
                              source: .audioOnset)
        }
        let capped = NotationCandidateAccumulator.capCandidatesByStrength(
            strokes + [gap], maxCount: 2
        )
        XCTAssertEqual(capped.count, 3, "cap keeps 2 strokes + the gap intact")
        XCTAssertTrue(capped.contains(gap),
                      "silence gaps must pass through the cap verbatim")
        XCTAssertEqual(
            capped.filter { $0.kind == .onset }.map(\.strength),
            [3.0, 4.0],
            "the two strongest strokes survive, sorted by time"
        )
    }

    /// Slice P invariant — uncertain rows must not be discriminated
    /// against by the cap as long as they fit by strength. This
    /// protects against accidentally interpreting low classifier
    /// confidence as low-priority audio onset.
    func testCapDoesNotPreferentiallyDropUncertainCandidates() {
        let uncertain = NotationCandidate(
            timestamp: 0.10, kind: .uncertain, strength: 5.0,
            audioConfidence: 0.7, classifierConfidence: 0.20,
            predictedClass: .chirps, source: .fused
        )
        let weakOnset = NotationCandidate(
            timestamp: 0.20, kind: .onset, strength: 1.0,
            audioConfidence: 0.6, source: .audioOnset
        )
        let capped = NotationCandidateAccumulator.capCandidatesByStrength(
            [uncertain, weakOnset], maxCount: 1
        )
        XCTAssertEqual(capped, [uncertain],
                       "an uncertain candidate with stronger audio strength must outrank a weak onset")
    }

    // MARK: Reset clears both summaries when callers re-derive them

    func testCurrentReviewSummaryIsEmptyAfterReset() {
        let acc = NotationCandidateAccumulator()
        let signal = makeImpulseSignal(durationSeconds: 0.5, impulseTimes: [0.20])
        acc.pushSamples(signal, sampleRate: sampleRate)
        XCTAssertGreaterThan(acc.currentReviewSummary().envelopeFrameCount, 0)

        acc.reset()
        XCTAssertEqual(acc.currentReviewSummary(), .empty)
        XCTAssertEqual(acc.currentSummary(), .empty)
    }
}
