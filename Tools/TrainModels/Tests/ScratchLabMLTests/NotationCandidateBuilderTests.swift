//
//  NotationCandidateBuilderTests.swift
//  ScratchLabMLTests — Slice N
//
//  Behavioural coverage required by the slice spec:
//    * builder preserves audio onsets when no evidence is supplied
//    * matching evidence with high classifier + fused confidence upgrades
//      the candidate to `.stroke` and attaches identity
//    * matching evidence with LOW classifier confidence does NOT delete
//      the candidate — it becomes `.uncertain` with an `uncertaintyReason`
//    * evidence outside the match window is ignored, candidate stays
//      `.onset`
//    * silence-gap candidates pass through untouched
//    * fused confidence renormalises across present modalities
//

import XCTest
@testable import ScratchLabML

final class NotationCandidateBuilderTests: XCTestCase {

    // MARK: Helpers

    private func onset(at t: TimeInterval, audioConf: Double = 0.8) -> NotationCandidate {
        NotationCandidate(
            timestamp: t,
            kind: .onset,
            strength: 1.0,
            audioConfidence: audioConf,
            source: .audioOnset
        )
    }

    // MARK: Empty / pass-through

    func testEmptyInputProducesEmptyOutput() {
        let builder = NotationCandidateBuilder()
        XCTAssertEqual(builder.buildTimeline(audioCandidates: []).count, 0)
    }

    func testNoEvidencePreservesEveryAudioCandidate() {
        let inputs = [onset(at: 0.10), onset(at: 0.50), onset(at: 1.20)]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: [])
        XCTAssertEqual(out.count, inputs.count)
        for c in out {
            XCTAssertEqual(c.kind, .onset)
            XCTAssertNil(c.predictedClass)
            XCTAssertNil(c.predictedFamily)
            XCTAssertNil(c.classifierConfidence)
        }
    }

    // MARK: Identity attachment

    func testHighConfidenceEvidenceUpgradesToStrokeWithIdentity() {
        let inputs = [onset(at: 0.50, audioConf: 0.8)]
        let evidence = [LabelEvidence(
            timestamp: 0.50,
            predictedClass: .chirps,
            predictedFamily: "chirp_family",
            classifierConfidence: 0.85,
            motionConfidence: 0.70
        )]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: evidence)
        XCTAssertEqual(out.count, 1)
        guard let c = out.first else { return XCTFail() }
        XCTAssertEqual(c.kind, .stroke)
        XCTAssertEqual(c.predictedClass, .chirps)
        XCTAssertEqual(c.predictedFamily, "chirp_family")
        XCTAssertEqual(c.classifierConfidence, 0.85)
        XCTAssertEqual(c.motionConfidence, 0.70)
        XCTAssertEqual(c.source, .fused)
        XCTAssertNil(c.uncertaintyReason)
    }

    // MARK: PRODUCT INVARIANT — low classifier confidence must not delete

    func testLowClassifierConfidenceDoesNotDeleteCandidate() {
        let inputs = [onset(at: 0.50, audioConf: 0.8)]
        let evidence = [LabelEvidence(
            timestamp: 0.50,
            predictedClass: .chirps,
            predictedFamily: "chirp_family",
            classifierConfidence: 0.20,    // well below threshold
            motionConfidence: 0.30
        )]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: evidence)
        XCTAssertEqual(out.count, 1, "candidate must survive low classifier confidence")
        guard let c = out.first else { return XCTFail() }
        XCTAssertEqual(c.kind, .uncertain, "should be downgraded to uncertain, not dropped")
        XCTAssertNotNil(c.uncertaintyReason)
        // Identity is still surfaced (so the UI can hint, e.g. "maybe chirps?")
        XCTAssertEqual(c.predictedClass, .chirps)
        XCTAssertEqual(c.classifierConfidence, 0.20)
        XCTAssertEqual(c.timestamp, 0.50)
    }

    func testEvidenceWithoutIdentityDowngradesNotDeletes() {
        let inputs = [onset(at: 0.50)]
        let evidence = [LabelEvidence(
            timestamp: 0.50,
            predictedClass: nil,
            predictedFamily: nil,
            classifierConfidence: 0.80,
            motionConfidence: nil
        )]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: evidence)
        XCTAssertEqual(out.count, 1)
        guard let c = out.first else { return XCTFail() }
        XCTAssertEqual(c.kind, .uncertain)
        XCTAssertNotNil(c.uncertaintyReason)
    }

    // MARK: Window matching

    func testEvidenceOutsideMatchWindowIsIgnored() {
        // Default window is 150ms; evidence is 400ms away.
        let inputs = [onset(at: 0.50)]
        let evidence = [LabelEvidence(
            timestamp: 0.90,
            predictedClass: .tears,
            predictedFamily: "tear_family",
            classifierConfidence: 0.95
        )]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: evidence)
        XCTAssertEqual(out.count, 1)
        guard let c = out.first else { return XCTFail() }
        XCTAssertEqual(c.kind, .onset, "evidence outside window must not attach")
        XCTAssertNil(c.predictedClass)
        XCTAssertNil(c.classifierConfidence)
    }

    func testNearestEvidenceWinsWhenMultipleAreInWindow() {
        // Two evidences within the 150ms window — nearer one should attach.
        let inputs = [onset(at: 0.50)]
        let evidence = [
            LabelEvidence(
                timestamp: 0.40,
                predictedClass: .tears,
                predictedFamily: "tear_family",
                classifierConfidence: 0.92,
                motionConfidence: 0.80
            ),
            LabelEvidence(
                timestamp: 0.55,
                predictedClass: .chirps,
                predictedFamily: "chirp_family",
                classifierConfidence: 0.92,
                motionConfidence: 0.80
            ),
        ]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: inputs, evidence: evidence)
        XCTAssertEqual(out.first?.predictedClass, .chirps,
                       "0.55 is nearer to 0.50 than 0.40")
    }

    // MARK: Pass-through for non-onset kinds

    func testSilenceGapPassesThroughUntouched() {
        let gap = NotationCandidate(
            timestamp: 0.20,
            kind: .silenceGap,
            strength: 0,
            endTimestamp: 0.80,
            audioConfidence: 1.0,
            source: .audioOnset
        )
        let evidence = [LabelEvidence(
            timestamp: 0.50,
            predictedClass: .chirps,
            predictedFamily: "chirp_family",
            classifierConfidence: 0.99,
            motionConfidence: 0.99
        )]
        let builder = NotationCandidateBuilder()
        let out = builder.buildTimeline(audioCandidates: [gap], evidence: evidence)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .silenceGap)
        XCTAssertNil(out.first?.predictedClass,
                     "silence gaps must not be relabelled by classifier evidence")
    }

    // MARK: Fusion math

    func testFusionRenormalisesAcrossMissingModalities() {
        let builder = NotationCandidateBuilder()
        // All three modalities present: weighted average.
        let all3 = builder.fusedConfidence(audio: 0.8, classifier: 0.6, motion: 0.4)
        // Weights default to 0.4/0.4/0.2 ⇒ 0.8*0.4 + 0.6*0.4 + 0.4*0.2 = 0.64
        XCTAssertEqual(all3, 0.64, accuracy: 1e-6)
        // Motion missing: 0.8*0.4 + 0.6*0.4 normalised by 0.8 = 0.7
        let noMotion = builder.fusedConfidence(audio: 0.8, classifier: 0.6, motion: nil)
        XCTAssertEqual(noMotion, 0.7, accuracy: 1e-6)
        // Only audio: returns audio.
        let onlyAudio = builder.fusedConfidence(audio: 0.5, classifier: nil, motion: nil)
        XCTAssertEqual(onlyAudio, 0.5, accuracy: 1e-6)
        // None: zero, no NaN.
        let none = builder.fusedConfidence(audio: nil, classifier: nil, motion: nil)
        XCTAssertEqual(none, 0)
    }

    // MARK: End-to-end integration with the detector

    func testDetectorPlusBuilderEndToEndPreservesAllOnsets() {
        // 5 evenly spaced impulses; pretend the classifier was confident
        // about three of them and unsure about two. Expect:
        //   - 3 strokes, 2 uncertain, 0 dropped.
        let sampleRate = 44_100.0
        let impulseTimes = [0.20, 0.50, 0.80, 1.10, 1.40]
        let durationS = 1.6
        let count = Int(durationS * sampleRate)
        var signal = [Float](repeating: 0, count: count)
        for t in impulseTimes {
            let centre = Int(t * sampleRate)
            for offset in -32...32 {
                let idx = centre + offset
                if idx >= 0 && idx < count {
                    signal[idx] += 0.7 * Float(exp(-(Double(offset * offset)) / 80.0))
                }
            }
        }
        let detector = AudioOnsetDetector()
        let onsets = detector.detect(samples: signal).filter { $0.kind == .onset }
        XCTAssertEqual(onsets.count, impulseTimes.count)

        // Three confident, two unsure.
        let evidence: [LabelEvidence] = [
            LabelEvidence(timestamp: 0.20, predictedClass: .chirps,
                          predictedFamily: "chirp_family",
                          classifierConfidence: 0.85, motionConfidence: 0.70),
            LabelEvidence(timestamp: 0.50, predictedClass: .chirps,
                          predictedFamily: "chirp_family",
                          classifierConfidence: 0.30, motionConfidence: 0.40),
            LabelEvidence(timestamp: 0.80, predictedClass: .chirps,
                          predictedFamily: "chirp_family",
                          classifierConfidence: 0.90, motionConfidence: 0.80),
            LabelEvidence(timestamp: 1.10, predictedClass: .chirps,
                          predictedFamily: "chirp_family",
                          classifierConfidence: 0.25, motionConfidence: 0.30),
            LabelEvidence(timestamp: 1.40, predictedClass: .chirps,
                          predictedFamily: "chirp_family",
                          classifierConfidence: 0.88, motionConfidence: 0.75),
        ]

        let builder = NotationCandidateBuilder()
        let timeline = builder.buildTimeline(audioCandidates: onsets, evidence: evidence)
        XCTAssertEqual(timeline.count, impulseTimes.count,
                       "no candidates may be dropped")
        XCTAssertEqual(timeline.filter { $0.kind == .stroke }.count, 3)
        XCTAssertEqual(timeline.filter { $0.kind == .uncertain }.count, 2)
        XCTAssertEqual(timeline.filter { $0.kind == .onset }.count, 0)
        for c in timeline.filter({ $0.kind == .uncertain }) {
            XCTAssertNotNil(c.uncertaintyReason)
        }
    }

    // MARK: Codable surface for builder inputs

    func testLabelEvidenceIsSendable() {
        // Ensure the type is `Sendable` (compile-time check via concurrency).
        let ev = LabelEvidence(
            timestamp: 0.5,
            predictedClass: .chirps,
            predictedFamily: "chirp_family",
            classifierConfidence: 0.7,
            motionConfidence: 0.6
        )
        XCTAssertEqual(ev.predictedClass, .chirps)
    }
}
