//
//  NotationCandidateDiagnosticsTests.swift
//  ScratchLabMLTests — Slice O
//
//  Behavioural coverage required by the slice spec:
//    * summary counts onsets / strokes / uncertain / silence gaps correctly
//    * empty input → .empty
//    * noisy/low-energy audio → zero candidates
//    * clear impulse audio → non-zero candidates with sensible timestamps
//    * unknown identity is preserved (isClassified stays false)
//    * accumulator handles a sample-rate change by resetting deterministically
//    * diagnostics code does not require any model file or bundle resource
//

import XCTest
@testable import ScratchLabML

final class NotationCandidateDiagnosticsTests: XCTestCase {

    // MARK: Helpers

    private let sampleRate: Double = 44_100

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
                let idx = centre + offset
                if idx >= 0 && idx < count {
                    s[idx] += impulsePeak * Float(exp(-(Double(offset * offset)) / 80.0))
                }
            }
        }
        return s
    }

    private func makeNoise(durationSeconds: Double, peak: Float = 0.002) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var state: UInt64 = 0xC0FFEE
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Double(state >> 32) / Double(UInt32.max)) * 2 - 1
            out[i] = u * peak
        }
        return out
    }

    // MARK: Summary

    func testEmptySummary() {
        let s = NotationCandidateDiagnosticsSummary.empty
        XCTAssertEqual(s.candidateCount, 0)
        XCTAssertEqual(s.onsetCount, 0)
        XCTAssertEqual(s.strokeCount, 0)
        XCTAssertEqual(s.uncertainCount, 0)
        XCTAssertEqual(s.silenceGapCount, 0)
        XCTAssertEqual(s.cutCount, 0)
        XCTAssertNil(s.firstTimestamp)
        XCTAssertNil(s.lastTimestamp)
        XCTAssertEqual(s.meanStrength, 0)
        XCTAssertEqual(s.strongestStrength, 0)
        XCTAssertFalse(s.isClassified)
    }

    func testSummarizeCountsKindsCorrectly() {
        let candidates: [NotationCandidate] = [
            NotationCandidate(timestamp: 0.10, kind: .onset,      strength: 1.0, audioConfidence: 0.5, source: .audioOnset),
            NotationCandidate(timestamp: 0.20, kind: .silenceGap, strength: 0.0, endTimestamp: 0.40, audioConfidence: 1.0, source: .audioOnset),
            NotationCandidate(timestamp: 0.50, kind: .stroke,     strength: 2.0, audioConfidence: 0.8, classifierConfidence: 0.9, predictedClass: .chirps, source: .fused),
            NotationCandidate(timestamp: 0.80, kind: .uncertain,  strength: 1.5, audioConfidence: 0.7, classifierConfidence: 0.3, source: .fused),
            NotationCandidate(timestamp: 1.00, kind: .cut,        strength: 0.5, source: .audioOnset),
        ]
        let s = NotationCandidateDiagnosticsSummary.summarize(candidates: candidates)
        XCTAssertEqual(s.candidateCount, 5)
        XCTAssertEqual(s.onsetCount, 1)
        XCTAssertEqual(s.strokeCount, 1)
        XCTAssertEqual(s.uncertainCount, 1)
        XCTAssertEqual(s.silenceGapCount, 1)
        XCTAssertEqual(s.cutCount, 1)
        // Mean and strongest are computed over stroke-like kinds only
        // (onset + stroke + uncertain + cut), excluding silence gaps.
        // Strengths: 1.0, 2.0, 1.5, 0.5 → mean = 1.25, max = 2.0.
        XCTAssertEqual(s.meanStrength, 1.25, accuracy: 1e-6)
        XCTAssertEqual(s.strongestStrength, 2.0)
        // First and last skip the silence gap.
        XCTAssertEqual(s.firstTimestamp, 0.10)
        XCTAssertEqual(s.lastTimestamp, 1.00)
        XCTAssertTrue(s.isClassified, "stroke had a predictedClass")
    }

    /// Slice N invariant carries through Slice O: an unidentified onset
    /// must remain in the summary; isClassified stays false.
    func testUnknownIdentityPreservedInSummary() {
        let candidates: [NotationCandidate] = [
            NotationCandidate(timestamp: 0.10, kind: .onset, strength: 1.0,
                              audioConfidence: 0.5, source: .audioOnset),
            NotationCandidate(timestamp: 0.30, kind: .uncertain, strength: 1.2,
                              audioConfidence: 0.6, classifierConfidence: 0.2, source: .fused),
        ]
        let s = NotationCandidateDiagnosticsSummary.summarize(candidates: candidates)
        XCTAssertEqual(s.candidateCount, 2)
        XCTAssertFalse(s.isClassified, "no candidate has identity attached")
        XCTAssertEqual(s.onsetCount, 1)
        XCTAssertEqual(s.uncertainCount, 1)
    }

    // MARK: Accumulator — basic flow

    func testAccumulatorEmptyByDefault() {
        let acc = NotationCandidateAccumulator()
        XCTAssertEqual(acc.envelopeFrameCount, 0)
        XCTAssertNil(acc.sampleRate)
        XCTAssertEqual(acc.currentSummary(), .empty)
    }

    func testAccumulatorClearImpulsesProduceCandidates() {
        let acc = NotationCandidateAccumulator()
        let signal = makeImpulseSignal(
            durationSeconds: 1.0,
            impulseTimes: [0.20, 0.50, 0.80]
        )
        acc.pushSamples(signal, sampleRate: sampleRate)
        let summary = acc.currentSummary()
        XCTAssertEqual(summary.onsetCount, 3, "three clean impulses should yield three onsets")
        XCTAssertGreaterThan(summary.envelopeFrameCount, 0)
        XCTAssertGreaterThan(summary.envelopeDurationSeconds, 0)
        XCTAssertNotNil(summary.firstTimestamp)
        XCTAssertNotNil(summary.lastTimestamp)
        // Identity is never set by audio-only diagnostics.
        XCTAssertFalse(summary.isClassified)
    }

    func testAccumulatorLowEnergyNoiseProducesNoOnsets() {
        let acc = NotationCandidateAccumulator()
        let noise = makeNoise(durationSeconds: 1.0, peak: 0.002) // ~ -54 dBFS
        acc.pushSamples(noise, sampleRate: sampleRate)
        let summary = acc.currentSummary()
        XCTAssertEqual(summary.onsetCount, 0)
        XCTAssertEqual(summary.strokeCount, 0)
        XCTAssertEqual(summary.uncertainCount, 0)
        // The whole window should register as silence gaps when the
        // gap-detection pass is enabled (it is by default).
        XCTAssertGreaterThanOrEqual(summary.silenceGapCount, 1)
    }

    func testAccumulatorEmptyPushIsNoOp() {
        let acc = NotationCandidateAccumulator()
        acc.pushSamples([], sampleRate: sampleRate)
        XCTAssertEqual(acc.envelopeFrameCount, 0)
        XCTAssertEqual(acc.currentSummary(), .empty)
    }

    func testAccumulatorIncrementalPushesEqualSinglePush() {
        // Streaming the same signal in chunks should produce the same
        // summary as one big push — important for the live capture path.
        let signal = makeImpulseSignal(
            durationSeconds: 1.5,
            impulseTimes: [0.30, 0.70, 1.10]
        )
        let big = NotationCandidateAccumulator()
        big.pushSamples(signal, sampleRate: sampleRate)
        let oneShot = big.currentSummary()

        let stream = NotationCandidateAccumulator()
        let chunk = 1024
        var i = 0
        while i < signal.count {
            let end = min(i + chunk, signal.count)
            stream.pushSamples(Array(signal[i..<end]), sampleRate: sampleRate)
            i = end
        }
        let chunked = stream.currentSummary()
        XCTAssertEqual(chunked.onsetCount, oneShot.onsetCount)
        XCTAssertEqual(chunked.envelopeFrameCount, oneShot.envelopeFrameCount)
    }

    // MARK: Accumulator — sample-rate handling

    func testAccumulatorResetsOnSampleRateChange() {
        let acc = NotationCandidateAccumulator()
        let s1 = makeImpulseSignal(durationSeconds: 0.5, impulseTimes: [0.20])
        acc.pushSamples(s1, sampleRate: sampleRate)
        XCTAssertGreaterThan(acc.envelopeFrameCount, 0)
        // Push at a different rate — should clear the envelope and
        // re-lock to the new rate. This protects the published summary
        // from frame-time mismatches if the audio device changes.
        let s2: [Float] = Array(repeating: 0.4, count: 480)
        acc.pushSamples(s2, sampleRate: 48_000)
        XCTAssertEqual(acc.sampleRate, 48_000)
    }

    // MARK: Accumulator — reset

    func testAccumulatorResetClearsState() {
        let acc = NotationCandidateAccumulator()
        let signal = makeImpulseSignal(durationSeconds: 0.5, impulseTimes: [0.10, 0.30])
        acc.pushSamples(signal, sampleRate: sampleRate)
        XCTAssertGreaterThan(acc.envelopeFrameCount, 0)
        acc.reset()
        XCTAssertEqual(acc.envelopeFrameCount, 0)
        XCTAssertNil(acc.sampleRate)
        XCTAssertEqual(acc.currentSummary(), .empty)
    }

    // MARK: Bounded buffer

    func testAccumulatorRespectsCapacity() {
        let cap = 32
        let acc = NotationCandidateAccumulator(capacityFrames: cap)
        // Push enough audio to overflow the buffer.
        let chunk = makeImpulseSignal(durationSeconds: 2.0, impulseTimes: [0.5, 1.0, 1.5])
        acc.pushSamples(chunk, sampleRate: sampleRate)
        XCTAssertLessThanOrEqual(acc.envelopeFrameCount, cap)
    }

    // MARK: No bundle / model assumptions

    func testNoBundleOrModelLoadsRequired() {
        // Building both types must not touch any bundled resource or
        // .mlmodel file. If anyone wires that in by accident this test
        // will surface it as a runtime failure when run under SwiftPM
        // (which has no app bundle resources at all).
        let acc = NotationCandidateAccumulator()
        let signal = makeImpulseSignal(durationSeconds: 0.5, impulseTimes: [0.20])
        acc.pushSamples(signal, sampleRate: sampleRate)
        _ = acc.currentSummary()
        XCTAssertGreaterThan(acc.envelopeFrameCount, 0)
    }

    // MARK: Codable

    func testSummaryCodableRoundTrip() throws {
        let s = NotationCandidateDiagnosticsSummary(
            candidateCount: 4, onsetCount: 2, strokeCount: 1, uncertainCount: 1,
            silenceGapCount: 0, cutCount: 0,
            firstTimestamp: 0.10, lastTimestamp: 0.85,
            meanStrength: 1.1, strongestStrength: 1.7,
            envelopeFrameCount: 128, envelopeDurationSeconds: 1.5,
            isClassified: true
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(NotationCandidateDiagnosticsSummary.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
