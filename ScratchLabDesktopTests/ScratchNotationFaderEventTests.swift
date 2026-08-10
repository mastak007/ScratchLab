import Foundation
import Testing
@testable import ScratchLab

// MARK: - Shared helpers

/// Repo root, derived from this test file's path — same pattern as the
/// other canonical-model test suites.
private func faderEventTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func decodeBundledNotation(_ name: String) throws -> ScratchNotation {
    let url = faderEventTestsRepoRoot()
        .appendingPathComponent("ScratchLab/Resources/Notation/\(name)")
    return try JSONDecoder().decode(ScratchNotation.self, from: Data(contentsOf: url))
}

private func decodeNotation(fromJSON json: String) throws -> ScratchNotation {
    try JSONDecoder().decode(ScratchNotation.self, from: Data(json.utf8))
}

private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

/// A synthetic, tempo-free beat-authored pattern used to exercise the
/// generic fader-event infrastructure without authoring any real
/// technique's timing. One stroke (0...1 beat) plus a three-edge fader
/// stream independent of the stroke boundary: open at 0, closed mid-stroke
/// at 0.5, reopened after the stroke ends at 1.2.
private func syntheticPattern(
    faderEvents: [ScratchNotation.BeatPattern.BeatFaderEvent] = [
        .init(beat: 0.0, state: .open),
        .init(beat: 0.5, state: .closed),
        .init(beat: 1.2, state: .open)
    ]
) -> ScratchNotation.BeatPattern {
    ScratchNotation.BeatPattern(
        version: 1,
        scratchID: "synthetic_fader_fixture",
        timingBasis: "beat_canonical_fader_fixture_v1",
        beatsPerBar: nil,
        strokes: [
            .init(startBeat: 0.0, endBeat: 1.0,
                  direction: .forward, speedClassification: .medium, faderState: .open)
        ],
        faderEvents: faderEvents
    )
}

// MARK: - Generic fader-event infrastructure (synthetic fixtures only)

@Suite("Canonical fader-event infrastructure")
struct ScratchNotationFaderEventTests {

    // MARK: Empty channel

    @Test("Empty faderEvents means no authored edge channel and validates")
    func emptyFaderEventsValidates() {
        let pattern = syntheticPattern(faderEvents: [])
        #expect(pattern.faderEvents.isEmpty)
        #expect(pattern.validationIssues().isEmpty)

        let materialized = pattern.materialized(bpm: 120)
        #expect(materialized?.faderEvents.isEmpty == true)
        #expect(materialized?.validationIssues().isEmpty == true)
    }

    @Test("babyScratchCycle still has faderEvents == []")
    func babyScratchCycleUnaffected() {
        #expect(ScratchNotation.babyScratchCycle.faderEvents.isEmpty)
        #expect(ScratchNotation.babyScratchCycle.validationIssues().isEmpty)
        let materialized = ScratchNotation.babyScratchCycle.materialized(bpm: 79)
        #expect(materialized?.faderEvents.isEmpty == true)
    }

    // MARK: Baseline positive case

    @Test("open@0.0 -> closed@0.5 -> open@0.7 validates")
    func baselineEdgeSequenceValidates() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 0.5, state: .closed),
            .init(beat: 0.7, state: .open)
        ])
        #expect(pattern.validationIssues().isEmpty)
    }

    // MARK: Independence from stroke boundaries

    @Test("Fader timing is independent of stroke timing")
    func faderTimingIndependentOfStrokes() {
        // Default synthetic pattern: stroke spans 0...1 beat, but the third
        // fader edge (1.2) lands after the stroke ends entirely.
        let pattern = syntheticPattern()
        #expect(pattern.validationIssues().isEmpty)
        #expect(approximatelyEqual(pattern.durationBeats, 1.2))
    }

    @Test("Fader edge exactly on a platter stroke boundary validates")
    func faderEdgeOnStrokeBoundaryValidates() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 1.0, state: .closed)   // coincides with the stroke's endBeat
        ])
        #expect(pattern.validationIssues().isEmpty)
    }

    // MARK: Validation failures

    @Test("First event after beat 0 fails")
    func firstEventNotAtZeroFails() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.2, state: .closed)
        ])
        #expect(!pattern.validationIssues().isEmpty)
    }

    @Test("Duplicate/same-beat fader edges fail")
    func duplicateBeatEdgesFail() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 0.5, state: .closed),
            .init(beat: 0.5, state: .open)
        ])
        #expect(!pattern.validationIssues().isEmpty)
    }

    @Test("Adjacent same-state events fail")
    func adjacentSameStateFails() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 0.5, state: .open)
        ])
        #expect(!pattern.validationIssues().isEmpty)
    }

    @Test("Negative/non-finite beat fails")
    func negativeOrNonFiniteBeatFails() {
        let negative = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: -0.1, state: .closed)
        ])
        #expect(!negative.validationIssues().isEmpty)

        let nonFinite = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: .nan, state: .closed)
        ])
        #expect(!nonFinite.validationIssues().isEmpty)
    }

    @Test("Invalid BeatPattern refuses materialization")
    func invalidPatternRefusesMaterialization() {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 0.5, state: .open)   // adjacent same-state — invalid
        ])
        #expect(!pattern.validationIssues().isEmpty)
        #expect(pattern.materialized(bpm: 120) == nil)
    }

    // MARK: Materialization

    @Test("Materialization at a known BPM projects event times correctly")
    func materializationProjectsCorrectTimes() throws {
        let pattern = syntheticPattern(faderEvents: [
            .init(beat: 0.0, state: .open),
            .init(beat: 0.5, state: .closed),
            .init(beat: 0.7, state: .open)
        ])
        let materialized = try #require(pattern.materialized(bpm: 120))
        let secondsPerBeat = 60.0 / 120.0

        #expect(materialized.faderEvents.count == 3)
        #expect(approximatelyEqual(materialized.faderEvents[0].time, 0.0))
        #expect(approximatelyEqual(materialized.faderEvents[1].time, 0.5 * secondsPerBeat))
        #expect(approximatelyEqual(materialized.faderEvents[2].time, 0.7 * secondsPerBeat))
        #expect(materialized.faderEvents[0].state == .open)
        #expect(materialized.faderEvents[1].state == .closed)
        #expect(materialized.faderEvents[2].state == .open)
        #expect(materialized.faderEvents[0].beat == 0.0)
        #expect(materialized.faderEvents[2].beat == 0.7)
        #expect(materialized.validationIssues().isEmpty)
    }

    @Test("Materialization deterministic")
    func materializationIsDeterministic() {
        let pattern = syntheticPattern()
        #expect(pattern.materialized(bpm: 100) == pattern.materialized(bpm: 100))
    }

    @Test("Materialized end time is the union of stroke and fader-event horizons")
    func materializedEndUnionsBothStreams() throws {
        // Fader event at beat 1.2 ends after the stroke (which ends at 1.0).
        let pattern = syntheticPattern()
        let materialized = try #require(pattern.materialized(bpm: 60))
        // At 60 BPM, 1 beat == 1 second, so the fader stream's 1.2-beat
        // edge should drive demoEnd/phraseEnd/timelineDuration, not the
        // stroke's 1.0-beat end.
        #expect(approximatelyEqual(materialized.demoEnd, 1.2))
        #expect(approximatelyEqual(materialized.phraseEnd ?? -1, 1.2))
        #expect(approximatelyEqual(materialized.timelineDuration, 1.2))
    }

    // MARK: Timing-authority rules (JSON, beat-authored)

    private let beatAuthoredFaderJSON = """
    {
      "version": 1,
      "scratchID": "synthetic_fader_fixture",
      "timingBasis": "beat_canonical_fader_fixture_v1",
      "bpm": 100,
      "strokes": [
        { "startBeat": 0.0, "endBeat": 1.0, "direction": "forward",
          "speedClassification": "medium", "faderState": "open" }
      ],
      "faderEvents": [
        { "beat": 0.0, "state": "open" },
        { "beat": 0.5, "state": "closed" }
      ]
    }
    """

    @Test("Beat-authored JSON derives time from beats")
    func beatAuthoredJSONDerivesTime() throws {
        let notation = try decodeNotation(fromJSON: beatAuthoredFaderJSON)
        #expect(notation.faderEvents.count == 2)
        #expect(approximatelyEqual(notation.faderEvents[0].time, 0.0))
        #expect(approximatelyEqual(notation.faderEvents[1].time, 0.3))
        #expect(notation.faderEvents[1].beat == 0.5)
        #expect(notation.validationIssues().isEmpty)
    }

    @Test("Provided seconds time in beat-authored JSON is ignored")
    func beatAuthoredJSONIgnoresProvidedTime() throws {
        let json = beatAuthoredFaderJSON.replacingOccurrences(
            of: "{ \"beat\": 0.5, \"state\": \"closed\" }",
            with: "{ \"time\": 999.0, \"beat\": 0.5, \"state\": \"closed\" }"
        )
        let notation = try decodeNotation(fromJSON: json)
        #expect(approximatelyEqual(notation.faderEvents[1].time, 0.3))
        #expect(notation.validationIssues().isEmpty)
    }

    @Test("Missing bpm for beat-authored JSON fails decoding")
    func beatAuthoredJSONMissingBPMFailsDecoding() {
        let json = beatAuthoredFaderJSON.replacingOccurrences(of: "\"bpm\": 100,", with: "")
        #expect(throws: (any Error).self) {
            _ = try decodeNotation(fromJSON: json)
        }
    }

    @Test("Hand-built beat/time disagreement fails validation")
    func handBuiltDisagreementFailsValidation() {
        let disagreeing = ScratchNotation(
            version: 1, scratchID: "synthetic_fader_fixture",
            demoStart: 0, demoEnd: 1, phraseStart: 0, phraseEnd: 1,
            timingBasis: "beat_canonical_fader_fixture_v1", bpm: 100, beatsPerBar: nil,
            strokes: [],
            faderEvents: [
                ScratchNotation.FaderEvent(time: 0.0, state: .open, beat: 0.0),
                ScratchNotation.FaderEvent(time: 999.0, state: .closed, beat: 0.5)
            ]
        )
        #expect(!disagreeing.validationIssues().isEmpty)
    }

    // MARK: Legacy regression

    @Test("Legacy bundled notation decodes with faderEvents == []",
          arguments: ["baby_scratch.json",
                      "baby_scratch_full_76.json",
                      "baby_scratch_full_76_beat_quantized.json"])
    func legacyBundledNotationHasEmptyFaderEvents(name: String) throws {
        let notation = try decodeBundledNotation(name)
        #expect(notation.faderEvents.isEmpty)
        #expect(notation.validationIssues().isEmpty)
    }

    // MARK: Codable round-trip

    @Test("Codable round-trip remains stable")
    func codableRoundTripStable() throws {
        let pattern = syntheticPattern()
        let materialized = try #require(pattern.materialized(bpm: 133))
        let reencoded = try JSONEncoder().encode(materialized)
        let redecoded = try JSONDecoder().decode(ScratchNotation.self, from: reencoded)
        #expect(redecoded == materialized)
    }

    @Test("Beat-authored fader-event JSON round-trips through Codable")
    func beatAuthoredFaderJSONRoundTrips() throws {
        let decoded = try decodeNotation(fromJSON: beatAuthoredFaderJSON)
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(ScratchNotation.self, from: reencoded)
        #expect(redecoded == decoded)
    }
}
