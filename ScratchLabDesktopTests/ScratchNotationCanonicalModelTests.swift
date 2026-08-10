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

// MARK: - Canonical technique registry boundaries

/// Every `BeatPattern` this repository has authored evidence for, to date.
/// Now backed by the production registry (`ScratchNotation.canonicalBeatPatterns`,
/// added when Practice Mode became a second call site needing the
/// enumeration). Adding an entry there requires the same repository-evidence
/// bar `babyScratchCycle` was held to (see the notation technique
/// evidence-matrix audit): a repeatable cycle with anchored platter
/// directions, beat positions, cycle duration, fader state, and a loop/reset
/// state — no guessing from PatternSignature/tips alone. As of this audit,
/// every other `ScratchLibrary` technique (19 primitives + 5 combos) is
/// PARTIAL or INSUFFICIENT; see the technique gap report.
private let allCanonicalBeatPatterns: [ScratchNotation.BeatPattern] = ScratchNotation.canonicalBeatPatterns

@Suite("Canonical technique registry boundaries")
struct CanonicalTechniqueRegistryTests {

    @Test("Canonical technique IDs are unique")
    func canonicalIDsAreUnique() {
        let ids = allCanonicalBeatPatterns.map(\.scratchID)
        #expect(ids.count == Set(ids).count)
    }

    @Test("Every canonical pattern maps to a real ScratchLibrary technique")
    func canonicalPatternsMapToRealTechniques() {
        for pattern in allCanonicalBeatPatterns {
            #expect(ScratchLibrary.shared.scratch(byID: pattern.scratchID) != nil)
        }
    }

    @Test("Only baby_scratch is canonical today — evidence-insufficient techniques stay unauthored")
    func onlyEvidencedTechniqueIsCanonical() {
        #expect(allCanonicalBeatPatterns.count == 1)
        #expect(allCanonicalBeatPatterns.map(\.scratchID) == ["baby_scratch"])

        // ScratchLibrary carries 20 primitive techniques; 19 of them remain
        // without a canonical BeatPattern because the repository does not
        // establish an anchored starting platter direction, an exact
        // audible/silent-return beat split, or an exact fader-edge beat
        // position for them (PatternSignature.rhythmPattern/waveformPattern
        // are audio-matching aids, not beat-position authorities — the
        // detector's own reference pattern for baby_scratch uses different
        // waveform values than ScratchLibrary's, confirming the two are not
        // interchangeable evidence sources).
        #expect(ScratchLibrary.shared.allScratches.count == 20)

        let nonCanonicalIDsWithPartialEvidence: Set<String> = [
            "forward_scratch", "backward_scratch", "release_scratch", "tear",
            "chirp", "scribble", "stab", "transform", "crab", "flare_1click",
            "orbit", "flare_2click", "twiddle", "boomerang", "hydroplane",
            "flare_3click", "autobahn", "military", "prizm"
        ]
        #expect(nonCanonicalIDsWithPartialEvidence.count == 19)
        let canonicalIDs = Set(allCanonicalBeatPatterns.map(\.scratchID))
        #expect(canonicalIDs.isDisjoint(with: nonCanonicalIDsWithPartialEvidence))
        for id in nonCanonicalIDsWithPartialEvidence {
            #expect(ScratchLibrary.shared.scratch(byID: id) != nil, "\(id) should still be a real technique, just not canonical yet")
        }

        // Combo scratches carry component references only (no timing/
        // direction/fader data at all), so they were never evidence
        // candidates in the first place.
        #expect(ScratchLibrary.shared.comboScratches.count == 5)
        let comboIDs = Set(ScratchLibrary.shared.comboScratches.map(\.id))
        #expect(canonicalIDs.isDisjoint(with: comboIDs))
    }

    @Test("Lookup by scratch ID returns the canonical pattern for baby_scratch")
    func lookupReturnsCanonicalPatternForBabyScratch() {
        let pattern = ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch")
        #expect(pattern?.scratchID == "baby_scratch")
        #expect(pattern == ScratchNotation.babyScratchCycle)
    }

    @Test("Lookup by scratch ID returns nil for evidence-insufficient and unknown techniques")
    func lookupReturnsNilForUnsupportedTechniques() {
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "forward_scratch") == nil)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "scribble") == nil)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "not_a_real_scratch_id") == nil)
    }
}

// MARK: - Canonical playhead (LaneClock over a materialized BeatPattern)

/// Practice Mode's target-notation playhead is `LaneClock.looping`, fed the
/// duration of a `BeatPattern` materialized at the session BPM — no separate
/// playhead type or timer. These tests exercise that composition directly,
/// pure and without SwiftUI.
@Suite("Canonical playhead (LaneClock over a materialized BeatPattern)")
struct CanonicalPlayheadTests {

    private func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test("Playhead position at the start, middle, and end of the loop")
    func positionsAtStartMidEnd() throws {
        let notation = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        let start = Date()
        let clock = LaneClock.looping(start: start, duration: content.duration)

        #expect(approximatelyEqual(clock.now(at: start), 0))
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(content.duration / 2)),
                                   content.duration / 2))
        let almostEnd = content.duration * 0.999
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(almostEnd)), almostEnd))
    }

    @Test("The loop wraps exactly at the canonical pattern's duration, every cycle")
    func loopWrapsAtExactBoundary() throws {
        let notation = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        let start = Date()
        let clock = LaneClock.looping(start: start, duration: content.duration)

        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(content.duration)), 0))
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(content.duration * 2)), 0))
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(content.duration * 5)), 0))
    }

    @Test("Restarting the clock resets the playhead deterministically")
    func restartResetsPlayhead() throws {
        let notation = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        let firstStart = Date()
        let midway = firstStart.addingTimeInterval(content.duration * 0.5)
        let firstClock = LaneClock.looping(start: firstStart, duration: content.duration)
        #expect(approximatelyEqual(firstClock.now(at: midway), content.duration * 0.5))

        // A restart re-stamps the clock origin — exactly what
        // PracticeModeView.startSession() does to notationClockStartDate.
        // The same wall-clock instant now reads as phase 0 again, not
        // wherever the previous session's clock had drifted to.
        let restartedClock = LaneClock.looping(start: midway, duration: content.duration)
        #expect(approximatelyEqual(restartedClock.now(at: midway), 0))
    }

    @Test("Changing BPM rescales the loop duration; the canonical pattern stays beat-relative")
    func bpmChangeRescalesLoopDuration() throws {
        let slow = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 60))
        let fast = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 120))
        // Same authored beats regardless of tempo — bpm only projects, never
        // re-authors, the pattern.
        #expect(slow.strokes[1].endBeat == fast.strokes[1].endBeat)

        let slowContent = LaneContent(notation: slow, beatsPerMinute: 60)
        let fastContent = LaneContent(notation: fast, beatsPerMinute: 120)
        #expect(approximatelyEqual(slowContent.duration, 1.0))
        #expect(approximatelyEqual(fastContent.duration, 0.5))

        let start = Date()
        let slowClock = LaneClock.looping(start: start, duration: slowContent.duration)
        let fastClock = LaneClock.looping(start: start, duration: fastContent.duration)
        // At the same wall-clock instant, the shorter (faster-tempo) loop has
        // already wrapped once while the slower one has not.
        let t = start.addingTimeInterval(0.6)
        #expect(approximatelyEqual(slowClock.now(at: t), 0.6))
        #expect(approximatelyEqual(fastClock.now(at: t), 0.1))
    }

    @Test("A pattern longer than one beat loops over its own full duration, not 1 beat")
    func nonUnitBeatPatternLoopsOverItsOwnDuration() throws {
        let twoBeatPattern = ScratchNotation.BeatPattern(
            version: 1, scratchID: "test_two_beat",
            timingBasis: "beat_canonical_test_fixture_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 1.0, direction: .forward,
                            speedClassification: .medium, faderState: .open),
                      .init(startBeat: 1.0, endBeat: 2.0, direction: .backward,
                            speedClassification: .medium, faderState: .open)])
        #expect(approximatelyEqual(twoBeatPattern.durationBeats, 2.0))

        let notation = try #require(twoBeatPattern.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        #expect(approximatelyEqual(content.duration, 1.0)) // 2 beats @ 120bpm = 1s

        let start = Date()
        let clock = LaneClock.looping(start: start, duration: content.duration)
        // Wraps at 1s (2 beats), not at 0.5s (1 beat).
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(0.5)), 0.5))
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(1.0)), 0))
    }

    @Test("A fader edge inside the stroke span never shrinks the loop duration")
    func faderWithinStrokeSpanDoesNotAlterDuration() throws {
        let pattern = ScratchNotation.BeatPattern(
            version: 1, scratchID: "test_fader_within",
            timingBasis: "beat_canonical_test_fixture_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 1.0, direction: .forward,
                            speedClassification: .medium, faderState: .open),
                      .init(startBeat: 1.0, endBeat: 2.0, direction: .backward,
                            speedClassification: .medium, faderState: .open)],
            faderEvents: [.init(beat: 0, state: .open),
                          .init(beat: 1.5, state: .closed)])
        // Fader's last edge (1.5) is inside the strokes' span (2.0) — the
        // union is still driven by the strokes.
        #expect(approximatelyEqual(pattern.durationBeats, 2.0))

        let notation = try #require(pattern.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        #expect(approximatelyEqual(content.duration, 1.0))
    }

    @Test("A fader edge past the last stroke extends the loop — union of both streams")
    func faderPastStrokesExtendsDuration() throws {
        let pattern = ScratchNotation.BeatPattern(
            version: 1, scratchID: "test_fader_extends",
            timingBasis: "beat_canonical_test_fixture_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 1.0, direction: .forward,
                            speedClassification: .medium, faderState: .open)],
            faderEvents: [.init(beat: 0, state: .open),
                          .init(beat: 1.0, state: .closed),
                          .init(beat: 2.5, state: .open)])
        // Fader's last edge (2.5) extends past the last stroke (1.0) — the
        // union-of-streams duration must be driven by the fader stream here.
        #expect(approximatelyEqual(pattern.durationBeats, 2.5))

        let notation = try #require(pattern.materialized(bpm: 120))
        let content = LaneContent(notation: notation, beatsPerMinute: 120)
        // 2.5 beats @ 120bpm = 1.25s — the loop must run this long, not stop
        // at the stroke-only 0.5s.
        #expect(approximatelyEqual(content.duration, 1.25))

        let start = Date()
        let clock = LaneClock.looping(start: start, duration: content.duration)
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(1.25)), 0))
        #expect(approximatelyEqual(clock.now(at: start.addingTimeInterval(0.8)), 0.8))
    }
}

// MARK: - Registry-driven comparison surfaces (source-string regression)

/// Pins the Phase-4 rule that every target-vs-performed surface keys off the
/// canonical registry — never a hardcoded technique — so a future technique
/// added to `canonicalBeatPatterns` lights up Practice and Review comparison
/// with no per-surface edits, and unsupported techniques fail gracefully.
@Suite("Registry-driven comparison surfaces")
struct RegistryDrivenComparisonSurfaceTests {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: canonicalTestsRepoRoot()
            .appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Review comparison card resolves its target through the registry")
    func reviewCardUsesRegistry() throws {
        let mac = try source("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        #expect(mac.contains(
            "ScratchNotation.canonicalBeatPattern(forScratchID: scratchType.rawValue)"))
        // Graceful refusal, never a guessed target.
        #expect(mac.contains("comparison stays off rather than guessing one"))
    }

    @Test("Review comparison derives windows and tolerances, no magic beats")
    func reviewCardDerivesWindows() throws {
        let mac = try source("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        #expect(mac.contains("ScratchComparisonWindows.derived("))
        #expect(mac.contains("NotationFeedbackState.lateOffsetThresholdMs"))
    }

    @Test("Practice's no-target branch is a graceful placeholder, not invented notation")
    func practicePlaceholderIsGraceful() throws {
        let practice = try source("ScratchLab/Views/PracticeModeView.swift")
        #expect(practice.contains("Target notation isn't available for"))
        // The target lane still resolves through the registry alone.
        #expect(practice.contains(
            "ScratchNotation.canonicalBeatPattern(forScratchID: scratch.id)"))
    }

    @Test("Chart overlay defaults nil so pre-existing charts render unchanged")
    func chartOverlayDefaultsNil() throws {
        let chart = try source("ScratchLabDesktop/Views/ScratchPhraseChartView.swift")
        #expect(chart.contains("var comparisonOverlay: ScratchComparisonOverlay? = nil"))
    }
}
