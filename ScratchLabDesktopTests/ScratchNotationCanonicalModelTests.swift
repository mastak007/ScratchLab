import Foundation
import Testing
@testable import ScratchLab

// MARK: - Shared helpers

/// Repo root, derived from this test file's path — same pattern as the
/// source-string regression suites.
private func canonicalTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func decodeBundledNotation(_ name: String) throws -> ScratchNotation {
    let url = canonicalTestsRepoRoot()
        .appendingPathComponent("ScratchLab/Resources/Notation/\(name)")
    return try JSONDecoder().decode(ScratchNotation.self, from: Data(contentsOf: url))
}

private func decodeNotation(fromJSON json: String) throws -> ScratchNotation {
    try JSONDecoder().decode(ScratchNotation.self, from: Data(json.utf8))
}

private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Canonical Baby Scratch cycle

@Suite("Canonical Baby Scratch cycle")
struct BabyScratchCycleTests {

    @Test("Cycle shape matches the repository's technique definition")
    func cycleShapeMatchesTechniqueDefinition() throws {
        let cycle = ScratchNotation.babyScratchCycle

        #expect(cycle.strokes.count == 2)
        #expect(cycle.scratchID == CaptureSessionScratchType.babyScratch.rawValue)
        #expect(cycle.timingBasis.hasPrefix(ScratchNotation.beatAuthoredTimingBasisPrefix))

        // Direction: forward then backward, agreeing with the frame-anchored
        // polarity invariant.
        for (index, stroke) in cycle.strokes.enumerated() {
            #expect(stroke.direction == BabyScratchPolarity.direction(forStrokeAtIndex: index))
            #expect(stroke.faderState == BabyScratchPolarity.faderState)
            #expect(approximatelyEqual(stroke.durationBeats, 0.5))
        }

        // Contiguous — no implicit hold inside the cycle.
        #expect(cycle.strokes[0].endBeat == cycle.strokes[1].startBeat)

        // One cycle = 1.0 beat, in lockstep with the ScratchLibrary
        // technique definition the Formula catalog consumes.
        #expect(approximatelyEqual(cycle.durationBeats, 1.0))
        let technique = try #require(ScratchLibrary.shared.scratch(byID: "baby_scratch"))
        #expect(approximatelyEqual(cycle.durationBeats, technique.formulaDefaultBeats))

        #expect(cycle.validationIssues().isEmpty)
    }

    @Test("Materialization at BPM 79 derives the exact projected seconds")
    func materializationAt79() throws {
        let cycle = ScratchNotation.babyScratchCycle
        let notation = try #require(cycle.materialized(bpm: 79))
        let secondsPerBeat = 60.0 / 79.0

        #expect(notation.resolvedTimingDomain == .beats)
        #expect(notation.bpm == 79)
        #expect(notation.strokes.count == 2)
        #expect(approximatelyEqual(notation.strokes[0].startTime, 0))
        #expect(approximatelyEqual(notation.strokes[0].endTime, 0.5 * secondsPerBeat))
        #expect(approximatelyEqual(notation.strokes[1].startTime, 0.5 * secondsPerBeat))
        #expect(approximatelyEqual(notation.strokes[1].endTime, secondsPerBeat))
        #expect(approximatelyEqual(notation.timelineDuration, secondsPerBeat))
        // Beats remain authoritative in the materialized value.
        #expect(notation.strokes[0].startBeat == 0.0)
        #expect(notation.strokes[1].endBeat == 1.0)
        #expect(notation.validationIssues().isEmpty)
    }

    @Test("Materialization is deterministic and rejects unusable tempi")
    func materializationDeterminismAndGuards() {
        let cycle = ScratchNotation.babyScratchCycle
        #expect(cycle.materialized(bpm: 79) == cycle.materialized(bpm: 79))
        #expect(cycle.materialized(bpm: 0) == nil)
        #expect(cycle.materialized(bpm: -60) == nil)
        #expect(cycle.materialized(bpm: .nan) == nil)
        #expect(cycle.materialized(bpm: .infinity) == nil)
    }

    @Test("A structurally invalid BeatPattern cannot be materialized")
    func invalidBeatPatternCannotBeMaterialized() {
        // Overlapping beat spans — structurally invalid, so the boundary
        // into seconds-ready notation must refuse it at any tempo.
        let overlapping = ScratchNotation.BeatPattern(
            version: 1, scratchID: "baby_scratch",
            timingBasis: "beat_canonical_cycle_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 0.6, direction: .forward,
                            speedClassification: .medium, faderState: .open),
                      .init(startBeat: 0.5, endBeat: 1.0, direction: .backward,
                            speedClassification: .medium, faderState: .open)])
        #expect(!overlapping.validationIssues().isEmpty)
        #expect(overlapping.materialized(bpm: 79) == nil)
        #expect(overlapping.materialized(bpm: 120) == nil)
    }

    @Test("Reprojection at a new tempo equals direct materialization")
    func reprojectionMatchesDirectMaterialization() throws {
        let cycle = ScratchNotation.babyScratchCycle
        let at79 = try #require(cycle.materialized(bpm: 79))
        #expect(at79.projectedToSeconds(bpm: 100) == cycle.materialized(bpm: 100))
    }

    @Test("Beat projection agrees with TimingGrid's beats↔seconds conversion")
    func projectionCrossCheckedAgainstTimingGrid() throws {
        let grid = try #require(TimingGrid(beatsPerMinute: 79,
                                           beatsPerBar: 4,
                                           subdivisionsPerBeat: 2,
                                           origin: 0))
        let notation = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 79))
        for stroke in notation.strokes {
            let startBeat = try #require(stroke.startBeat)
            let endBeat = try #require(stroke.endBeat)
            // Half-beat endpoints land exactly on the grid's subdivision
            // lattice at subdivisionsPerBeat == 2.
            let startPosition = GridPosition(bar: 0,
                                             beat: Int(startBeat),
                                             subdivision: Int(startBeat * 2) % 2,
                                             subdivisionPhase: 0)
            let endPosition = GridPosition(bar: 0,
                                           beat: Int(endBeat),
                                           subdivision: Int(endBeat * 2) % 2,
                                           subdivisionPhase: 0)
            #expect(approximatelyEqual(grid.time(of: startPosition), stroke.startTime))
            #expect(approximatelyEqual(grid.time(of: endPosition), stroke.endTime))
        }
    }

    @Test("Materialized cycle flows through the existing LaneContent adapter")
    func laneContentAcceptsMaterializedCycle() throws {
        let notation = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 79))
        let content = LaneContent(notation: notation, beatsPerMinute: 79)
        #expect(content.strokes.count == 2)
        #expect(content.loops)
        #expect(approximatelyEqual(content.duration, 60.0 / 79.0))
    }
}

// MARK: - Timing authority

@Suite("ScratchNotation timing authority")
struct ScratchNotationTimingAuthorityTests {

    private let beatAuthoredJSON = """
    {
      "version": 1,
      "scratchID": "baby_scratch",
      "timingBasis": "beat_canonical_cycle_v1",
      "bpm": 120,
      "strokes": [
        { "startBeat": 0.0, "endBeat": 0.5, "direction": "forward",
          "speedClassification": "medium", "faderState": "open" },
        { "startBeat": 0.5, "endBeat": 1.0, "direction": "backward",
          "speedClassification": "medium", "faderState": "open" }
      ]
    }
    """

    @Test("Beat-authored document decodes with seconds derived from beats")
    func beatAuthoredDocumentDerivesSeconds() throws {
        let notation = try decodeNotation(fromJSON: beatAuthoredJSON)
        #expect(notation.resolvedTimingDomain == .beats)
        #expect(notation.bpm == 120)
        #expect(approximatelyEqual(notation.strokes[0].endTime, 0.25))
        #expect(approximatelyEqual(notation.strokes[1].endTime, 0.5))
        #expect(notation.demoStart == 0)
        #expect(approximatelyEqual(notation.demoEnd, 0.5))
        #expect(notation.validationIssues().isEmpty)
    }

    @Test("Provided seconds in a beat-authored document are ignored, never trusted")
    func beatAuthoredDecoderIgnoresProvidedSeconds() throws {
        let json = beatAuthoredJSON.replacingOccurrences(
            of: "{ \"startBeat\": 0.0, \"endBeat\": 0.5,",
            with: "{ \"startTime\": 100.0, \"endTime\": 200.0, \"startBeat\": 0.0, \"endBeat\": 0.5,"
        )
        let notation = try decodeNotation(fromJSON: json)
        #expect(approximatelyEqual(notation.strokes[0].startTime, 0))
        #expect(approximatelyEqual(notation.strokes[0].endTime, 0.25))
        #expect(notation.validationIssues().isEmpty)
    }

    @Test("Beat-authored document without bpm fails decoding — never reclassified")
    func beatAuthoredWithoutBPMFailsDecoding() {
        let json = beatAuthoredJSON.replacingOccurrences(of: "\"bpm\": 120,", with: "")
        #expect(throws: (any Error).self) {
            _ = try decodeNotation(fromJSON: json)
        }
    }

    @Test("Beat-authored stroke missing beat fields fails decoding")
    func beatAuthoredStrokeMissingBeatsFailsDecoding() {
        let json = beatAuthoredJSON.replacingOccurrences(of: "\"endBeat\": 0.5, ", with: "")
        #expect(throws: (any Error).self) {
            _ = try decodeNotation(fromJSON: json)
        }
    }

    @Test("Legacy beat_quantized basis stays seconds-authored")
    func legacyBeatQuantizedBasisResolvesSeconds() {
        #expect(ScratchNotation.resolvedTimingDomain(
            timingBasis: "beat_quantized_BPM79_body6beats_v4") == .seconds)
        #expect(ScratchNotation.resolvedTimingDomain(
            timingBasis: "authored_deterministic_v1") == .seconds)
        #expect(ScratchNotation.resolvedTimingDomain(
            timingBasis: "beat_canonical_cycle_v1") == .beats)
    }

    @Test("Hand-built beat-authored values cannot silently disagree")
    func handBuiltDisagreementFailsValidation() {
        // Seconds off the beat projection by far more than the tolerance.
        let disagreeing = ScratchNotation(
            version: 1, scratchID: "baby_scratch",
            demoStart: 0, demoEnd: 1, phraseStart: 0, phraseEnd: 1,
            timingBasis: "beat_canonical_cycle_v1", bpm: 100, beatsPerBar: nil,
            strokes: [ScratchNotation.Stroke(startTime: 0, endTime: 0.9,
                                             direction: .forward,
                                             speedClassification: .medium,
                                             faderState: .open,
                                             startBeat: 0, endBeat: 0.5)]
        )
        #expect(!disagreeing.validationIssues().isEmpty)

        // Beat-basis ScratchNotation without bpm is invalid — tempo-free
        // patterns live in BeatPattern, not here.
        let tempoFree = ScratchNotation(
            version: 1, scratchID: "baby_scratch",
            demoStart: 0, demoEnd: 1, phraseStart: 0, phraseEnd: 1,
            timingBasis: "beat_canonical_cycle_v1", bpm: nil, beatsPerBar: nil,
            strokes: [ScratchNotation.Stroke(startTime: 0, endTime: 0.5,
                                             direction: .forward,
                                             speedClassification: .medium,
                                             faderState: .open,
                                             startBeat: 0, endBeat: 0.5)]
        )
        #expect(tempoFree.validationIssues().contains { $0.contains("BeatPattern") })
    }

    @Test("Beat-authored fixture round-trips through Codable")
    func beatAuthoredRoundTrip() throws {
        let decoded = try decodeNotation(fromJSON: beatAuthoredJSON)
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(ScratchNotation.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    @Test("BeatPattern validation flags non-beat basis and beat-order violations")
    func beatPatternValidation() {
        let wrongBasis = ScratchNotation.BeatPattern(
            version: 1, scratchID: "baby_scratch",
            timingBasis: "authored_deterministic_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 0.5, direction: .forward,
                            speedClassification: .medium, faderState: .open)])
        #expect(!wrongBasis.validationIssues().isEmpty)

        let overlapping = ScratchNotation.BeatPattern(
            version: 1, scratchID: "baby_scratch",
            timingBasis: "beat_canonical_cycle_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 0.6, direction: .forward,
                            speedClassification: .medium, faderState: .open),
                      .init(startBeat: 0.5, endBeat: 1.0, direction: .backward,
                            speedClassification: .medium, faderState: .open)])
        #expect(!overlapping.validationIssues().isEmpty)
    }
}

// MARK: - Legacy regression (behaviour frozen)

@Suite("ScratchNotation legacy regression")
struct ScratchNotationLegacyRegressionTests {

    @Test("All three bundled resources decode exactly as before",
          arguments: [
            ("baby_scratch.json", 12, 4.7),
            ("baby_scratch_full_76.json", 76, 41.501),
            ("baby_scratch_full_76_beat_quantized.json", 76, 41.501)
          ])
    func bundledResourcesDecodeUnchanged(name: String, strokeCount: Int, phraseEnd: Double) throws {
        let notation = try decodeBundledNotation(name)
        #expect(notation.strokes.count == strokeCount)
        #expect(approximatelyEqual(try #require(notation.phraseEnd), phraseEnd))
        #expect(notation.bpm == nil)
        #expect(notation.beatsPerBar == nil)
        #expect(notation.resolvedTimingDomain == .seconds)
        #expect(notation.strokes.allSatisfy { $0.startBeat == nil && $0.endBeat == nil })
        // Seconds-authored notation refuses beat reprojection.
        #expect(notation.projectedToSeconds(bpm: 100) == nil)
    }

    @Test("Authored 12-stroke excerpt keeps its exact stroke timing and holds")
    func authoredExcerptTimingUnchanged() throws {
        let notation = try decodeBundledNotation("baby_scratch.json")
        #expect(approximatelyEqual(notation.strokes[0].startTime, 0.0))
        #expect(approximatelyEqual(notation.strokes[0].endTime, 0.3))
        #expect(approximatelyEqual(notation.strokes[11].startTime, 4.4))
        #expect(approximatelyEqual(notation.strokes[11].endTime, 4.7))
        #expect(approximatelyEqual(notation.timelineDuration, 4.7))
        // Implicit-gap hold convention unchanged: 0.1 s between strokes.
        #expect(approximatelyEqual(notation.strokeSegments[0].holdAfter, 0.1))
    }

    @Test("Bundled resources round-trip through the new Codable conformance",
          arguments: ["baby_scratch.json",
                      "baby_scratch_full_76.json",
                      "baby_scratch_full_76_beat_quantized.json"])
    func bundledResourcesRoundTrip(name: String) throws {
        let decoded = try decodeBundledNotation(name)
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(ScratchNotation.self, from: reencoded)
        #expect(redecoded == decoded)
    }

    @Test("Seconds-authored notation with incidental beat annotations cannot be reprojected")
    func incidentalBeatsAreNotReprojectable() {
        let legacyWithAnnotations = ScratchNotation(
            version: 1, scratchID: "baby",
            demoStart: 0, demoEnd: 1, phraseStart: 0, phraseEnd: 1,
            timingBasis: "authored_deterministic_v1",
            strokes: [ScratchNotation.Stroke(startTime: 0, endTime: 0.5,
                                             direction: .forward,
                                             speedClassification: .medium,
                                             faderState: .open,
                                             startBeat: 0, endBeat: 0.5)]
        )
        #expect(legacyWithAnnotations.resolvedTimingDomain == .seconds)
        #expect(legacyWithAnnotations.projectedToSeconds(bpm: 100) == nil)
    }
}
