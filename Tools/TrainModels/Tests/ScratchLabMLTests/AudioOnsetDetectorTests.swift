//
//  AudioOnsetDetectorTests.swift
//  ScratchLabMLTests — Slice N
//
//  Behavioural coverage required by the slice spec:
//    * single impulse → exactly one onset near the impulse time
//    * multiple evenly spaced impulses → one onset each
//    * minimum spacing suppresses double-triggers from a single attack
//    * low-energy noise produces no onsets
//    * silence-gap detection emits a `.silenceGap` for sustained silence
//    * outputs are sorted by timestamp
//    * NotationCandidate Codable round-trip is stable
//

import XCTest
@testable import ScratchLabML

final class AudioOnsetDetectorTests: XCTestCase {

    // MARK: Helpers

    private let sampleRate: Double = 44_100

    /// Build a synthetic mono PCM signal with `count` samples at `sampleRate`,
    /// silent except for short impulse bursts at the given `impulseTimes`.
    /// Each impulse is a windowed click with peak 0.7.
    private func makeImpulseSignal(
        durationSeconds: Double,
        impulseTimes: [Double],
        impulsePeak: Float = 0.7
    ) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var s = [Float](repeating: 0, count: count)
        let impulseWidth = 64
        for t in impulseTimes {
            let centre = Int(t * sampleRate)
            let lo = max(0, centre - impulseWidth / 2)
            let hi = min(count - 1, centre + impulseWidth / 2)
            for i in lo...hi {
                let d = Double(i - centre)
                let env = Float(exp(-(d * d) / 80.0))
                s[i] += impulsePeak * env
            }
        }
        return s
    }

    /// Build low-amplitude white noise (deterministic via seeded LCG).
    private func makeNoise(durationSeconds: Double, peak: Float = 0.005) -> [Float] {
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

    // MARK: Impulse detection

    func testSingleImpulseProducesExactlyOneOnset() {
        let signal = makeImpulseSignal(durationSeconds: 1.0, impulseTimes: [0.5])
        let detector = AudioOnsetDetector()
        let candidates = detector.detect(samples: signal)
        let onsets = candidates.filter { $0.kind == .onset }
        XCTAssertEqual(onsets.count, 1, "expected exactly one onset for a single impulse")
        guard let first = onsets.first else { return XCTFail("no onset") }
        XCTAssertEqual(first.source, .audioOnset)
        XCTAssertEqual(first.timestamp, 0.5, accuracy: 0.05,
                       "onset should land within ±50ms of the impulse")
        XCTAssertGreaterThan(first.strength, 0)
        XCTAssertNotNil(first.audioConfidence)
        XCTAssertNil(first.predictedClass, "audio-only onset has no identity")
        XCTAssertNil(first.predictedFamily)
    }

    func testEvenlySpacedImpulsesProduceOneOnsetEach() {
        // 4 impulses, 250ms apart.
        let times = [0.20, 0.45, 0.70, 0.95]
        let signal = makeImpulseSignal(durationSeconds: 1.5, impulseTimes: times)
        let detector = AudioOnsetDetector()
        let onsets = detector.detect(samples: signal).filter { $0.kind == .onset }
        XCTAssertEqual(onsets.count, times.count,
                       "expected one onset per impulse")
        for (i, t) in times.enumerated() {
            XCTAssertEqual(onsets[i].timestamp, t, accuracy: 0.05,
                           "onset \(i) misaligned (got \(onsets[i].timestamp), expected \(t))")
        }
    }

    func testMinimumSpacingSuppressesDoubleTriggers() {
        // Two impulses 30ms apart — closer than the default 60ms spacing.
        let times = [0.50, 0.530]
        let signal = makeImpulseSignal(durationSeconds: 1.0, impulseTimes: times)
        let detector = AudioOnsetDetector()
        let onsets = detector.detect(samples: signal).filter { $0.kind == .onset }
        XCTAssertEqual(onsets.count, 1,
                       "min spacing 60ms should collapse the 30ms-apart pair")
    }

    func testLowEnergyNoiseProducesNoOnsets() {
        let noise = makeNoise(durationSeconds: 1.0, peak: 0.002)  // ~ -54 dBFS
        let detector = AudioOnsetDetector()
        let onsets = detector.detect(samples: noise).filter { $0.kind == .onset }
        XCTAssertEqual(onsets.count, 0,
                       "noise below the silence floor should not generate onsets")
    }

    // MARK: Silence-gap detection

    func testSilenceGapDetectionEmitsGapCandidate() {
        // 2 s total: impulse at 0.1s, then 1s of silence, then impulse at 1.4s.
        var signal = makeImpulseSignal(
            durationSeconds: 2.0,
            impulseTimes: [0.1, 1.4]
        )
        // Force a clean silence floor between 0.2 s and 1.3 s (already silent
        // by construction; explicit zero-write defends against numerical
        // residue).
        let lo = Int(0.2 * sampleRate)
        let hi = Int(1.3 * sampleRate)
        for i in lo..<hi { signal[i] = 0 }
        let detector = AudioOnsetDetector()
        let candidates = detector.detect(samples: signal)
        let onsets = candidates.filter { $0.kind == .onset }
        let gaps = candidates.filter { $0.kind == .silenceGap }
        XCTAssertEqual(onsets.count, 2)
        XCTAssertGreaterThanOrEqual(gaps.count, 1)
        // The longest gap should cover most of the silent stretch.
        let longest = gaps.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
        XCTAssertNotNil(longest)
        XCTAssertGreaterThan(longest?.duration ?? 0, 0.5)
    }

    func testSilenceGapCanBeDisabled() {
        var cfg = AudioOnsetDetectorConfig()
        cfg.detectSilenceGaps = false
        let detector = AudioOnsetDetector(config: cfg)
        var signal = makeImpulseSignal(durationSeconds: 2.0, impulseTimes: [0.1, 1.4])
        let lo = Int(0.2 * sampleRate)
        let hi = Int(1.3 * sampleRate)
        for i in lo..<hi { signal[i] = 0 }
        let gaps = detector.detect(samples: signal).filter { $0.kind == .silenceGap }
        XCTAssertEqual(gaps.count, 0, "silence-gap pass should be off")
    }

    // MARK: Output shape

    func testOutputIsSortedByTimestamp() {
        let signal = makeImpulseSignal(
            durationSeconds: 2.0,
            impulseTimes: [0.10, 0.95, 0.40, 1.55, 1.10]
        )
        let detector = AudioOnsetDetector()
        let out = detector.detect(samples: signal)
        let stamps = out.map(\.timestamp)
        XCTAssertEqual(stamps, stamps.sorted(),
                       "candidates must be sorted by timestamp")
    }

    func testEnvelopeEntryPointMatchesPCMEntryPoint() {
        // Both entry points should produce the same onsets when fed the
        // same underlying log-RMS envelope.
        let signal = makeImpulseSignal(
            durationSeconds: 1.0,
            impulseTimes: [0.25, 0.70]
        )
        let detector = AudioOnsetDetector()
        let envelope = detector.computeLogRMSEnvelope(samples: signal)
        let frameDuration = Double(detector.config.hopSize) / detector.config.sampleRate
        let fromPCM = detector.detect(samples: signal).filter { $0.kind == .onset }
        let fromEnv = detector.detect(envelopeDB: envelope, frameDurationSeconds: frameDuration)
            .filter { $0.kind == .onset }
        XCTAssertEqual(fromPCM.map(\.timestamp), fromEnv.map(\.timestamp))
    }

    // MARK: Codable

    func testNotationCandidateCodableRoundTrip() throws {
        let original = NotationCandidate(
            timestamp: 1.234,
            kind: .stroke,
            strength: 0.42,
            endTimestamp: 1.50,
            audioConfidence: 0.8,
            motionConfidence: 0.6,
            classifierConfidence: 0.7,
            predictedFamily: "chirp_family",
            predictedClass: .chirps,
            uncertaintyReason: nil,
            source: .fused
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotationCandidate.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyInputProducesNoCandidates() {
        let detector = AudioOnsetDetector()
        XCTAssertEqual(detector.detect(samples: []).count, 0)
        XCTAssertEqual(detector.detect(envelopeDB: [], frameDurationSeconds: 0.01).count, 0)
    }
}
