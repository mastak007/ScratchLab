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

    @Test("Baby Scratch fader is OPEN throughout — no closure is ever authored or rendered")
    func faderOpenThroughout() throws {
        let cycle = ScratchNotation.babyScratchCycle
        // The cycle authors no canonical fader edge channel. Per the
        // authority rule this is NOT an implicit open — but the per-stroke
        // fallback it triggers is `.open` on every stroke, so the resolved
        // fader timeline is OPEN end-to-end with zero closures.
        #expect(cycle.faderEvents.isEmpty)

        let notation = try #require(cycle.materialized(bpm: 79))
        let duration = notation.timelineDuration
        let spans = notation.faderAuthoritySpans(documentEnd: duration)

        // Every authoritative fader span is OPEN, and their union covers the
        // whole technique duration — no closed span, no gap a closed rail
        // could hide in.
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.state == .open })
        let openCoverage = spans.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
        #expect(approximatelyEqual(openCoverage, duration))

        // The authoritative state at any point inside the cycle resolves to
        // OPEN (checked at two interior times, not just the endpoints).
        let secondsPerBeat = 60.0 / 79.0
        #expect(notation.faderState(at: 0.25 * secondsPerBeat, documentEnd: duration) == .open)
        #expect(notation.faderState(at: 0.75 * secondsPerBeat, documentEnd: duration) == .open)
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

    @Test("Review reference target card resolves through the registry, not the legacy excerpt")
    func reviewReferenceTargetCardUsesRegistry() throws {
        let mac = try source("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        // The reference "Target notation" card must key off the canonical
        // registry (the same source the comparison card uses), never the
        // legacy bundled `ScratchNotation.babyScratch` ~5 s excerpt.
        #expect(mac.contains("reviewTargetReferenceNotation(for:"))
        #expect(mac.contains(
            "ScratchNotation.canonicalBeatPattern(forScratchID: scratchType.rawValue)"))
        // The legacy hardcoded source line is gone.
        #expect(!mac.contains(
            "(scratchType == .babyScratch) ? ScratchNotation.babyScratch : nil"))
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

// MARK: - Tear-capable canonical semantics

private let tearTimingBasis = "beat_canonical_tear_tests_v1"

private func platterEvidence(_ reason: String = "test_platter",
                             confidence: Double = 0.9) -> ScratchNotationEvidence {
    ScratchNotationEvidence(source: .platterTimeline, confidence: confidence, reason: reason)
}

private func faderEvidence(_ reason: String = "test_fader",
                           confidence: Double = 0.9) -> ScratchNotationEvidence {
    ScratchNotationEvidence(source: .crossfaderRaw, confidence: confidence, reason: reason)
}

private func motion(_ start: Double,
                    _ end: Double,
                    _ state: ScratchNotationMotionState,
                    evidence: ScratchNotationEvidence = platterEvidence())
-> ScratchNotation.PlatterMotionSegment {
    .init(startBeat: start, endBeat: end, state: state, evidence: evidence)
}

private func fader(_ start: Double,
                   _ end: Double,
                   _ state: ScratchNotationFaderState,
                   evidence: ScratchNotationEvidence = faderEvidence())
-> ScratchNotation.FaderInterval {
    .init(startBeat: start, endBeat: end, state: state, evidence: evidence)
}

private func gesturePattern(
    motionSegments: [ScratchNotation.PlatterMotionSegment],
    faderIntervals: [ScratchNotation.FaderInterval] = [],
    faderClicks: [ScratchNotation.FaderClick] = [],
    timingBasis: String = tearTimingBasis
) -> ScratchNotation.GesturePattern {
    .init(version: 1,
          scratchID: "tear_tests",
          timingBasis: timingBasis,
          beatsPerBar: nil,
          motionSegments: motionSegments,
          faderIntervals: faderIntervals,
          faderClicks: faderClicks)
}

@Suite("Tear motion vocabulary")
struct TearMotionVocabularyTests {

    @Test("Travel polarity is reported only for hand-driven travel")
    func travelPolarityIsOnlyForTravel() {
        #expect(ScratchNotationMotionState.forward.travelDirection == .forward)
        #expect(ScratchNotationMotionState.backward.travelDirection == .backward)
        #expect(ScratchNotationMotionState.stationary.travelDirection == nil)
        #expect(ScratchNotationMotionState.released.travelDirection == nil)
        #expect(ScratchNotationMotionState.unknown.travelDirection == nil)
    }

    @Test("Released free playback is motion, never a stationary hold")
    func releasedIsNotStationary() {
        #expect(ScratchNotationMotionState.released.isStationary == false)
        #expect(ScratchNotationMotionState.released.isTravel == false)
        #expect(ScratchNotationMotionState.stationary.isStationary)
        #expect(ScratchNotationMotionState.unknown.isStationary == false)
    }

    @Test("Direction lifts into the larger motion vocabulary without loss")
    func directionLiftsLosslessly() {
        for direction in [ScratchNotationDirection.forward, .backward] {
            let state = ScratchNotationMotionState(direction: direction)
            #expect(state.travelDirection == direction)
        }
    }

    @Test("Capture movement kinds bridge to exactly one motion state each")
    func movementKindBridge() {
        #expect(ScratchMovementKind.fastPush.motionState == .forward)
        #expect(ScratchMovementKind.normalPush.motionState == .forward)
        #expect(ScratchMovementKind.slowDrag.motionState == .forward)
        #expect(ScratchMovementKind.fastPull.motionState == .backward)
        #expect(ScratchMovementKind.normalPull.motionState == .backward)
        #expect(ScratchMovementKind.slowPullDrag.motionState == .backward)
        #expect(ScratchMovementKind.hold.motionState == .stationary)
        #expect(ScratchMovementKind.releaseNormalPlayback.motionState == .released)
    }

    @Test("Sustained fader states never map to a click kind")
    func sustainedFaderStatesAreNotClicks() {
        #expect(ScratchNotationFaderClickKind(faderEventKind: .open) == nil)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .closed) == nil)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .cut) == .cut)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .flareClick) == .flareClick)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .transformPulse) == .transformPulse)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .pulse) == .pulse)
        #expect(ScratchNotationFaderClickKind(faderEventKind: .unknown) == .unknown)
    }

    @Test("No platter-only source can establish fader state, and vice versa")
    func evidenceSourceCapabilitiesAreDisjointWhereItMatters() {
        #expect(ScratchNotationEvidenceSource.platterTimeline.canEstablishPlatterMotion)
        #expect(ScratchNotationEvidenceSource.platterTimeline.canEstablishFaderState == false)
        #expect(ScratchNotationEvidenceSource.watchMotion.canEstablishFaderState == false)
        #expect(ScratchNotationEvidenceSource.crossfaderRaw.canEstablishFaderState)
        #expect(ScratchNotationEvidenceSource.crossfaderRaw.canEstablishPlatterMotion == false)
        #expect(ScratchNotationEvidenceSource.audioOnset.canEstablishPlatterMotion == false)
        #expect(ScratchNotationEvidenceSource.audioOnset.canEstablishFaderState == false)
        // Unknown provenance establishes nothing; "we do not know what the
        // platter did" is a motion STATE, not an erased source.
        #expect(ScratchNotationEvidenceSource.unknown.canEstablishPlatterMotion == false)
        #expect(ScratchNotationEvidenceSource.unknown.canEstablishFaderState == false)
    }
}

@Suite("Evidence and correctable labels")
struct TearEvidenceAndLabelTests {

    @Test("A correction wins over the derivation and both stay inspectable")
    func correctionWinsAndDerivationSurvives() {
        let label = ScratchNotationMotionLabel(derived: .unknown, correction: .stationary)
        #expect(label.effective == .stationary)
        #expect(label.derived == .unknown)
        #expect(label.isCorrected)

        let agreeing = ScratchNotationMotionLabel(derived: .forward, correction: .forward)
        #expect(agreeing.effective == .forward)
        #expect(agreeing.isCorrected == false)

        let uncorrected = ScratchNotationMotionLabel(derived: .forward)
        #expect(uncorrected.effective == .forward)
        #expect(uncorrected.isCorrected == false)
    }

    @Test("Correcting a label never rewrites the raw evidence it sits on")
    func correctionDoesNotRewriteEvidence() {
        let evidence = ScratchNotationEvidence(source: .platterTimeline,
                                               confidence: 0.31,
                                               reason: "cc6_steps=0_over_118ms",
                                               rawSampleCount: 12)
        let segment = ScratchNotation.PlatterMotionSegment(
            span: .init(startBeat: 0, endBeat: 1),
            label: .init(derived: .unknown, correction: .stationary),
            evidence: evidence
        )
        #expect(segment.state == .stationary)
        #expect(segment.label.derived == .unknown)
        #expect(segment.evidence == evidence)
        #expect(segment.evidence.confidence == 0.31)
        #expect(segment.evidence.reason == "cc6_steps=0_over_118ms")
        #expect(segment.evidence.rawSampleCount == 12)
    }

    @Test("The memberwise initializer clamps confidence into 0...1")
    func memberwiseInitClampsConfidence() {
        #expect(ScratchNotationEvidence(source: .authored, confidence: 4, reason: "r").confidence == 1)
        #expect(ScratchNotationEvidence(source: .authored, confidence: -3, reason: "r").confidence == 0)
        #expect(ScratchNotationEvidence(source: .authored, confidence: .nan, reason: "r").confidence == 0)
    }

    @Test("Decoding stays tolerant; validation reports the out-of-range confidence")
    func decodingIsTolerantAndValidationIsStrict() throws {
        let json = """
        {
          "version": 1,
          "scratchID": "tear_tests",
          "timingBasis": "\(tearTimingBasis)",
          "motionSegments": [
            {
              "span": {"startBeat": 0, "endBeat": 1},
              "label": {"derived": "forward"},
              "evidence": {"source": "platterTimeline", "confidence": 7.5, "reason": "decoded"}
            }
          ],
          "faderIntervals": [],
          "faderClicks": []
        }
        """
        let pattern = try JSONDecoder().decode(ScratchNotation.GesturePattern.self,
                                               from: Data(json.utf8))
        #expect(pattern.motionSegments.first?.evidence.confidence == 7.5)
        let issues = pattern.validationIssues()
        #expect(issues.contains { $0.contains("confidence must be finite and within 0...1") })
    }

    @Test("An empty evidence reason is a validation issue, not a silent default")
    func emptyReasonIsAnIssue() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 1, .forward, evidence: platterEvidence(""))
        ])
        #expect(pattern.validationIssues().contains { $0.contains("evidence reason must not be empty") })
    }
}

@Suite("Tear gesture derivation")
struct TearGestureDerivationTests {

    @Test("One internal hold yields one tear with two subdivisions")
    func oneHoldYieldsTwoSubdivisions() throws {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.25, .forward),
            motion(0.25, 0.375, .stationary),
            motion(0.375, 0.75, .forward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 1)
        let tear = try #require(gestures.first)
        #expect(tear.direction == .forward)
        #expect(tear.isTear)
        #expect(tear.tearHoldCount == 1)
        #expect(tear.subdivisionCount == 2)
        #expect(tear.internalHolds == [.init(startBeat: 0.25, endBeat: 0.375)])
        #expect(tear.subdivisions == [.init(startBeat: 0, endBeat: 0.25),
                                      .init(startBeat: 0.375, endBeat: 0.75)])
        #expect(tear.span == .init(startBeat: 0, endBeat: 0.75))
        #expect(pattern.tears.count == 1)
    }

    @Test("N internal tear holds always produce N+1 subdivisions")
    func nHoldsProduceNPlusOneSubdivisions() throws {
        for holdCount in 0...4 {
            var segments: [ScratchNotation.PlatterMotionSegment] = []
            var beat = 0.0
            for index in 0...holdCount {
                segments.append(motion(beat, beat + 0.25, .forward))
                beat += 0.25
                if index < holdCount {
                    segments.append(motion(beat, beat + 0.125, .stationary))
                    beat += 0.125
                }
            }
            let pattern = gesturePattern(motionSegments: segments)
            #expect(pattern.validationIssues().isEmpty)
            #expect(pattern.gestures.count == 1)
            let gesture = try #require(pattern.gestures.first)
            #expect(gesture.tearHoldCount == holdCount)
            #expect(gesture.subdivisionCount == holdCount + 1)
            #expect(gesture.isTear == (holdCount > 0))
        }
    }

    @Test("A direction reversal is not a tear hold")
    func reversalIsNotATearHold() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.5, 1.0, .backward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 2)
        #expect(gestures.allSatisfy { $0.tearHoldCount == 0 })
        #expect(gestures.allSatisfy { $0.subdivisionCount == 1 })
        #expect(gestures.allSatisfy { $0.isTear == false })
        #expect(gestures.map(\.direction) == [.forward, .backward])
        #expect(pattern.reversalBeats == [0.5])
        #expect(pattern.tears.isEmpty)
    }

    @Test("A stationary interval that precedes a reversal is not a tear hold")
    func holdBeforeReversalIsNotATearHold() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.5, 0.75, .stationary),
            motion(0.75, 1.25, .backward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 2)
        #expect(gestures.allSatisfy { $0.tearHoldCount == 0 })
        #expect(gestures.map(\.span) == [.init(startBeat: 0, endBeat: 0.5),
                                         .init(startBeat: 0.75, endBeat: 1.25)])
        // The turnaround here is separated by a stationary interval, so it is
        // not an instantaneous reversal.
        #expect(pattern.reversalBeats.isEmpty)
    }

    @Test("A released interval ends the gesture and is never a tear hold")
    func releaseIsNotATearHold() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.5, 1.5, .released),
            motion(1.5, 2.0, .forward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 2)
        #expect(gestures.allSatisfy { $0.direction == .forward })
        #expect(gestures.allSatisfy { $0.tearHoldCount == 0 })
        #expect(gestures.allSatisfy { $0.subdivisionCount == 1 })
        #expect(pattern.tears.isEmpty)
    }

    @Test("Unknown motion ends the gesture rather than joining it")
    func unknownMotionEndsTheGesture() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.5, 0.75, .unknown),
            motion(0.75, 1.25, .forward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 2)
        #expect(gestures.allSatisfy { $0.tearHoldCount == 0 })
        #expect(pattern.tears.isEmpty)
    }

    @Test("Leading and trailing stationary intervals are not tear holds")
    func boundaryHoldsAreNotTearHolds() throws {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.25, .stationary),
            motion(0.25, 0.75, .forward),
            motion(0.75, 1.0, .stationary)
        ])
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 1)
        let gesture = try #require(gestures.first)
        #expect(gesture.tearHoldCount == 0)
        #expect(gesture.subdivisionCount == 1)
        #expect(gesture.span == .init(startBeat: 0.25, endBeat: 0.75))
    }

    @Test("A fader click inside a travel span does not subdivide the gesture")
    func clickIsNotATearHold() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1.0, .forward)],
            faderIntervals: [fader(0, 1.0, .open)],
            faderClicks: [.init(beat: 0.5, kind: .transformPulse, evidence: faderEvidence())]
        )
        #expect(pattern.validationIssues().isEmpty)
        let gestures = pattern.gestures
        #expect(gestures.count == 1)
        let gesture = try #require(gestures.first)
        #expect(gesture.tearHoldCount == 0)
        #expect(gesture.subdivisionCount == 1)
        #expect(gesture.isTear == false)
        // The click is real fader evidence, and it changes no platter state.
        #expect(pattern.faderClicks.count == 1)
        #expect(pattern.correlatedState(atBeat: 0.5) == .sounding)
    }

    @Test("A stream with no travel produces no gestures")
    func stationaryOnlyStreamHasNoGestures() {
        let pattern = gesturePattern(motionSegments: [motion(0, 1.0, .stationary)])
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.gestures.isEmpty)
        #expect(pattern.tears.isEmpty)
    }
}

@Suite("Stream correlation: hold, ghost and ghost-hold")
struct TearStreamCorrelationTests {

    @Test("The nine correlations are distinct and never conflated")
    func correlationGrid() {
        typealias State = ScratchNotationCorrelatedState
        #expect(State.correlate(motion: .forward, fader: .open) == .sounding)
        #expect(State.correlate(motion: .backward, fader: .open) == .sounding)
        #expect(State.correlate(motion: .forward, fader: .closed) == .ghost)
        #expect(State.correlate(motion: .backward, fader: .closed) == .ghost)
        #expect(State.correlate(motion: .stationary, fader: .open) == .hold)
        #expect(State.correlate(motion: .stationary, fader: .closed) == .ghostHold)
        #expect(State.correlate(motion: .released, fader: .open) == .releasedSounding)
        #expect(State.correlate(motion: .released, fader: .closed) == .releasedMuted)
        #expect(State.correlate(motion: .unknown, fader: .open) == .unknown)
        #expect(State.correlate(motion: .unknown, fader: .closed) == .unknown)
    }

    @Test("An absent fader observation is unknown, never implicitly open or closed")
    func absentFaderIsUnknown() {
        for motionState in ScratchNotationMotionState.allCases {
            #expect(ScratchNotationCorrelatedState.correlate(motion: motionState, fader: nil) == .unknown)
        }
        let pattern = gesturePattern(motionSegments: [motion(0, 1.0, .stationary)])
        #expect(pattern.faderState(atBeat: 0.5) == nil)
        #expect(pattern.correlatedState(atBeat: 0.5) == .unknown)
    }

    @Test("Hold, ghost and ghost-hold are read off the two independent streams")
    func holdGhostAndGhostHoldAreDistinguished() {
        let pattern = gesturePattern(
            motionSegments: [
                motion(0, 1.0, .forward),
                motion(1.0, 2.0, .stationary),
                motion(2.0, 3.0, .backward),
                motion(3.0, 4.0, .stationary)
            ],
            faderIntervals: [
                fader(0, 2.0, .open),
                fader(2.0, 4.0, .closed)
            ]
        )
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.correlatedState(atBeat: 0.5) == .sounding)
        #expect(pattern.correlatedState(atBeat: 1.5) == .hold)
        #expect(pattern.correlatedState(atBeat: 2.5) == .ghost)
        #expect(pattern.correlatedState(atBeat: 3.5) == .ghostHold)
    }

    @Test("Fader edges need not align with platter boundaries")
    func streamsAreIndependentlyTimed() {
        let pattern = gesturePattern(
            motionSegments: [
                motion(0, 1.0, .forward),
                motion(1.0, 2.0, .stationary)
            ],
            faderIntervals: [
                fader(0, 0.75, .open),
                fader(0.75, 2.0, .closed)
            ]
        )
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.correlatedState(atBeat: 0.5) == .sounding)
        #expect(pattern.correlatedState(atBeat: 0.9) == .ghost)
        #expect(pattern.correlatedState(atBeat: 1.5) == .ghostHold)
    }

    @Test("A zero-velocity platter interval never creates a phantom click")
    func zeroVelocityCreatesNoPhantomClick() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.25, .forward),
            motion(0.25, 0.5, .stationary, evidence: ScratchNotationEvidence(
                source: .platterTimeline,
                confidence: 0.95,
                reason: "cc6_steps=0_over_118ms",
                rawSampleCount: 0
            )),
            motion(0.5, 1.0, .forward)
        ])
        #expect(pattern.validationIssues().isEmpty)
        // The hold is a real tear hold on the platter stream…
        #expect(pattern.gestures.first?.tearHoldCount == 1)
        // …and it contributes nothing whatsoever to the fader stream.
        #expect(pattern.faderClicks.isEmpty)
        #expect(pattern.faderIntervals.isEmpty)
        #expect(pattern.faderState(atBeat: 0.375) == nil)
        #expect(pattern.correlatedState(atBeat: 0.375) == .unknown)
    }

    @Test("Platter provenance cannot back a fader click")
    func platterSourcedClickIsRejected() {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1.0, .stationary)],
            faderClicks: [.init(beat: 0.5,
                                kind: .cut,
                                evidence: platterEvidence("derived_from_zero_velocity"))]
        )
        #expect(pattern.validationIssues().contains {
            $0.contains("faderClick 0") && $0.contains("cannot establish fader state")
        })
    }

    @Test("Fader provenance cannot back a platter motion segment")
    func faderSourcedMotionIsRejected() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 1.0, .stationary, evidence: faderEvidence("crossfader_only"))
        ])
        #expect(pattern.validationIssues().contains {
            $0.contains("motionSegment 0") && $0.contains("cannot establish platter motion")
        })
    }
}

@Suite("Tear pattern validation")
struct TearPatternValidationTests {

    @Test("A well-formed tear pattern reports no issues")
    func wellFormedPatternIsValid() {
        let pattern = gesturePattern(
            motionSegments: [
                motion(0, 0.25, .forward),
                motion(0.25, 0.375, .stationary),
                motion(0.375, 0.75, .forward)
            ],
            faderIntervals: [fader(0, 0.75, .open)],
            faderClicks: [.init(beat: 0.375, kind: .cut, widthBeats: 0.01, evidence: faderEvidence())]
        )
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.durationBeats == 0.75)
    }

    @Test("The platter stream must begin at beat 0")
    func platterStreamMustStartAtZero() {
        let pattern = gesturePattern(motionSegments: [motion(0.25, 1.0, .forward)])
        #expect(pattern.validationIssues().contains { $0.contains("must begin at beat 0") })
    }

    @Test("The platter stream must be contiguous — no undeclared gaps")
    func platterStreamMustBeContiguous() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.25, .forward),
            motion(0.5, 1.0, .forward)
        ])
        #expect(pattern.validationIssues().contains { $0.contains("leaves a gap after motionSegment 0") })
    }

    @Test("Overlapping platter segments are illegal")
    func platterSegmentsMayNotOverlap() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.25, 1.0, .backward)
        ])
        #expect(pattern.validationIssues().contains { $0.contains("overlaps motionSegment 0") })
    }

    @Test("Unsorted platter segments surface as an overlap, never as a silent reorder")
    func unsortedPlatterSegmentsAreIllegal() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 1.0, .forward),
            motion(0.0, 0.5, .backward)
        ])
        #expect(pattern.validationIssues().contains { $0.contains("overlaps motionSegment 0") })
    }

    @Test("Adjacent platter segments may not repeat the same state")
    func adjacentPlatterStatesMayNotRepeat() {
        let pattern = gesturePattern(motionSegments: [
            motion(0, 0.5, .forward),
            motion(0.5, 1.0, .forward)
        ])
        #expect(pattern.validationIssues().contains {
            $0.contains("adjacent motion segments must not repeat the same state")
        })
    }

    @Test("An instantaneous platter segment is illegal — instants belong to the click channel")
    func instantaneousPlatterSegmentIsIllegal() {
        let pattern = gesturePattern(motionSegments: [motion(0, 0, .stationary)])
        #expect(pattern.validationIssues().contains {
            $0.contains("motionSegment 0") && $0.contains("must be a bounded interval")
        })
    }

    @Test("An instantaneous fader interval is illegal — it would be a click")
    func instantaneousFaderIntervalIsIllegal() {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1.0, .forward)],
            faderIntervals: [fader(0.5, 0.5, .closed)]
        )
        #expect(pattern.validationIssues().contains {
            $0.contains("faderInterval 0") && $0.contains("must be a bounded interval")
        })
    }

    @Test("Overlapping fader intervals are illegal, but gaps are legal")
    func faderIntervalsMayGapButNotOverlap() {
        let overlapping = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderIntervals: [fader(0, 1.0, .open), fader(0.5, 2.0, .closed)]
        )
        #expect(overlapping.validationIssues().contains { $0.contains("overlaps faderInterval 0") })

        let gapped = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderIntervals: [fader(0, 0.5, .open), fader(1.0, 2.0, .open)]
        )
        #expect(gapped.validationIssues().isEmpty)
        #expect(gapped.faderState(atBeat: 0.75) == nil)
        #expect(gapped.correlatedState(atBeat: 0.75) == .unknown)

        // Abutting is different from gapped: touching intervals must carry
        // different states, or they are one interval written twice.
        let abutting = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderIntervals: [fader(0, 1.0, .open), fader(1.0, 2.0, .open)]
        )
        #expect(abutting.validationIssues().contains {
            $0.contains("abutting fader intervals must not repeat the same state")
        })
    }

    @Test("Fader clicks must be finite, non-negative and strictly increasing")
    func faderClickOrdering() {
        let unordered = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderClicks: [.init(beat: 1.0, kind: .cut, evidence: faderEvidence()),
                          .init(beat: 1.0, kind: .cut, evidence: faderEvidence())]
        )
        #expect(unordered.validationIssues().contains { $0.contains("must strictly increase") })

        let negative = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderClicks: [.init(beat: -0.5, kind: .cut, evidence: faderEvidence())]
        )
        #expect(negative.validationIssues().contains { $0.contains("beat must be >= 0") })

        let nonFinite = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderClicks: [.init(beat: .infinity, kind: .cut, evidence: faderEvidence())]
        )
        #expect(nonFinite.validationIssues().contains { $0.contains("beat must be finite") })
    }

    @Test("A click width, when stated, must be a positive finite measurement")
    func clickWidthMustBePositive() {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 2.0, .forward)],
            faderClicks: [.init(beat: 1.0, kind: .cut, widthBeats: 0, evidence: faderEvidence())]
        )
        #expect(pattern.validationIssues().contains { $0.contains("widthBeats") })
    }

    @Test("A pattern may not claim seconds authorship")
    func timingBasisMustDeclareBeatAuthorship() {
        let pattern = gesturePattern(motionSegments: [motion(0, 1.0, .forward)],
                                     timingBasis: "detected_capture")
        #expect(pattern.validationIssues().contains { $0.contains("does not declare beat authorship") })
    }

    @Test("Non-finite platter bounds are reported without cascading")
    func nonFiniteBoundsAreReported() {
        let pattern = gesturePattern(motionSegments: [motion(0, .nan, .forward)])
        let issues = pattern.validationIssues()
        #expect(issues.contains { $0.contains("motionSegment 0: startBeat/endBeat must be finite") })
        #expect(issues.count == 1)
    }

    @Test("beatsPerBar, when present, must be positive")
    func beatsPerBarMustBePositive() {
        let pattern = ScratchNotation.GesturePattern(version: 1,
                                                     scratchID: "tear_tests",
                                                     timingBasis: tearTimingBasis,
                                                     beatsPerBar: 0,
                                                     motionSegments: [motion(0, 1.0, .forward)])
        #expect(pattern.validationIssues().contains { $0.contains("beatsPerBar must be > 0") })
    }
}

@Suite("Baby Scratch under the tear-capable model")
struct BabyScratchTearCompatibilityTests {

    @Test("Baby remains forward, turnaround, backward with the fader open throughout")
    func babyIsUnchanged() throws {
        let pattern = try #require(ScratchNotation.babyScratchGesturePattern)
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.scratchID == CaptureSessionScratchType.babyScratch.rawValue)
        #expect(pattern.timingBasis == ScratchNotation.babyScratchCycle.timingBasis)

        #expect(pattern.motionSegments.map(\.state) == [.forward, .backward])
        #expect(pattern.motionSegments.map(\.startBeat) == [0.0, 0.5])
        #expect(pattern.motionSegments.map(\.endBeat) == [0.5, 1.0])

        // Fader open throughout, as one coalesced interval — never two.
        #expect(pattern.faderIntervals.count == 1)
        #expect(pattern.faderIntervals.first?.state == .open)
        #expect(pattern.faderIntervals.first?.span == ScratchNotation.BeatSpan(startBeat: 0, endBeat: 1.0))
        #expect(pattern.faderClicks.isEmpty)

        // The turnaround is an instantaneous reversal, not a tear hold.
        #expect(pattern.reversalBeats == [0.5])
        #expect(pattern.gestures.count == 2)
        #expect(pattern.gestures.map(\.direction) == [.forward, .backward])
        #expect(pattern.gestures.allSatisfy { $0.tearHoldCount == 0 })
        #expect(pattern.gestures.allSatisfy { $0.subdivisionCount == 1 })
        #expect(pattern.tears.isEmpty)

        #expect(pattern.correlatedState(atBeat: 0.25) == .sounding)
        #expect(pattern.correlatedState(atBeat: 0.75) == .sounding)
        #expect(pattern.durationBeats == 1.0)
    }

    @Test("Lifting an authored pattern leaves the authored cycle untouched")
    func liftIsNonDestructive() {
        let before = ScratchNotation.babyScratchCycle
        _ = before.gesturePattern()
        #expect(ScratchNotation.babyScratchCycle == before)
        #expect(ScratchNotation.babyScratchCycle.strokes.count == 2)
        #expect(ScratchNotation.babyScratchCycle.faderEvents.isEmpty)
        #expect(ScratchNotation.babyScratchCycle.validationIssues().isEmpty)
    }

    @Test("An authored inter-stroke gap becomes an explicit stationary interval")
    func authoredGapBecomesStationary() throws {
        let authored = ScratchNotation.BeatPattern(
            version: 1,
            scratchID: "tear_lift",
            timingBasis: tearTimingBasis,
            beatsPerBar: nil,
            strokes: [
                .init(startBeat: 0, endBeat: 0.25,
                      direction: .forward, speedClassification: .medium, faderState: .open),
                .init(startBeat: 0.5, endBeat: 0.75,
                      direction: .forward, speedClassification: .medium, faderState: .open)
            ]
        )
        #expect(authored.validationIssues().isEmpty)
        let pattern = try #require(authored.gesturePattern())
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.motionSegments.map(\.state) == [.forward, .stationary, .forward])
        #expect(pattern.motionSegments[1].span == .init(startBeat: 0.25, endBeat: 0.5))
        #expect(pattern.motionSegments[1].evidence.source == .authored)
        #expect(pattern.motionSegments[1].evidence.reason
                == ScratchNotation.BeatPattern.authoredGapEvidenceReason)

        // The gap is a tear hold: one same-direction gesture, two subdivisions.
        let gesture = try #require(pattern.gestures.first)
        #expect(pattern.gestures.count == 1)
        #expect(gesture.isTear)
        #expect(gesture.tearHoldCount == 1)
        #expect(gesture.subdivisionCount == 2)

        // Per-stroke fader state describes strokes only — the gap is unknown,
        // never implicitly open.
        #expect(pattern.faderIntervals.count == 2)
        #expect(pattern.faderState(atBeat: 0.375) == nil)
        #expect(pattern.correlatedState(atBeat: 0.375) == .unknown)
        #expect(pattern.correlatedState(atBeat: 0.1) == .sounding)
    }

    @Test("Authored fader edges are authoritative when present")
    func authoredFaderEdgesWin() throws {
        let authored = ScratchNotation.BeatPattern(
            version: 1,
            scratchID: "tear_lift_ghost",
            timingBasis: tearTimingBasis,
            beatsPerBar: nil,
            strokes: [
                .init(startBeat: 0, endBeat: 0.5,
                      direction: .forward, speedClassification: .medium, faderState: .open),
                .init(startBeat: 0.5, endBeat: 1.0,
                      direction: .backward, speedClassification: .medium, faderState: .open)
            ],
            faderEvents: [
                .init(beat: 0, state: .open),
                .init(beat: 0.5, state: .closed)
            ]
        )
        #expect(authored.validationIssues().isEmpty)
        let pattern = try #require(authored.gesturePattern())
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.faderIntervals.map(\.state) == [.open, .closed])
        // The backward stroke says `.open`, the authoritative edge stream says
        // `.closed` — the edge stream wins, so this reads as a ghost.
        #expect(pattern.correlatedState(atBeat: 0.25) == .sounding)
        #expect(pattern.correlatedState(atBeat: 0.75) == .ghost)
    }

    @Test("A stroke-less pattern lifts to nil rather than an empty guess")
    func strokelessPatternLiftsToNil() {
        let empty = ScratchNotation.BeatPattern(version: 1,
                                                scratchID: "tear_empty",
                                                timingBasis: tearTimingBasis,
                                                beatsPerBar: nil,
                                                strokes: [])
        #expect(empty.gesturePattern() == nil)
    }
}
