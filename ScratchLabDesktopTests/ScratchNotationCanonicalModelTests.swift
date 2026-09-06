import Foundation
import Testing
@testable import ScratchLab

#if DEBUG
@Suite("Internal authored canonical tear templates")
struct AuthoredTearTemplateTests {
    typealias Template = ScratchNotation.TearTemplate
    private typealias Record = ScratchNotation.GestureRecord

    private func template(id: String = "test.tear.v1", form: Template.Form = .forward,
                          holds: Int = 1, ratio: [Double] = [1, 1],
                          duration: Double = 1, holdDuration: Double = 0.0625) -> Template {
        .init(id: id, form: form, holdCount: holds, subdivisionRatio: ratio,
              gestureDurationBeats: duration, holdDurationBeats: holdDuration)
    }

    private func replacing(_ record: Record, direction: ScratchNotationDirection? = nil,
                           subdivisions: [Record.Subdivision]? = nil, holds: [Record.TearHold]? = nil,
                           fader: [Record.FaderSpan]? = nil, edges: [Record.FaderTransition]? = nil) -> Record {
        .init(id: record.id, direction: direction ?? record.direction, timingDomain: record.timingDomain,
              coordinateSpace: record.coordinateSpace, evidence: record.evidence,
              subdivisions: subdivisions ?? record.subdivisions, internalHolds: holds ?? record.internalHolds,
              faderTransitions: edges ?? record.faderTransitions, faderIntervals: fader ?? record.faderIntervals)
    }

    @Test("Catalog has exactly the versioned directional/orbit equal/unequal tear family")
    func catalogBoundary() {
        var expected = Set<String>()
        for count in 1...3 {
            for form in ["forward", "backward", "forward-backward"] {
                for rhythm in ["equal", "unequal"] {
                    expected.insert("scratchlab.tear.\(count).\(form).\(rhythm).v1")
                }
            }
        }
        let actual = ScratchNotation.internalCanonicalTearTemplates.map(\.id)
        #expect(actual.count == 18)
        #expect(Set(actual) == expected)
        let unequalRatios = [1: [1.0, 2.0], 2: [1.0, 2.0, 1.0], 3: [1.0, 2.0, 2.0, 1.0]]
        for template in ScratchNotation.internalCanonicalTearTemplates {
            let expectedRatio = template.id.contains(".unequal.")
                ? unequalRatios[template.holdCount] : Array(repeating: 1.0, count: template.holdCount + 1)
            #expect(template.subdivisionRatio == expectedRatio)
            #expect(template.gestureDurationBeats == 1)
            #expect(template.holdDurationBeats == 0.0625)
        }
        #expect(ScratchNotation.internalCanonicalGestureRecords(forTemplateID: "tear") == nil)
        #expect(ScratchNotation.internalCanonicalGestureRecords(forTemplateID: "orbit") == nil)
        #expect(ScratchNotation.internalCanonicalGestureRecords(forTemplateID: "scratchlab.tear.4.forward.equal.v1") == nil)
    }

    @Test("All templates expand into continuous authored beat records", arguments: ScratchNotation.internalCanonicalTearTemplates)
    func everyTemplate(_ template: Template) throws {
        #expect(template.validationIssues().isEmpty)
        let records = try #require(ScratchNotation.internalCanonicalGestureRecords(forTemplateID: template.id))
        #expect(records == template.expanded())
        #expect(template.expansionValidationIssues(records).isEmpty)
        #expect(records.map(\.direction) == template.form.directions)
        #expect(records.first?.subdivisions.first?.span.startTime == 0)
        #expect(records.last?.subdivisions.last?.span.endTime == template.durationBeats)
        var totalDuration = 0.0
        for (index, record) in records.enumerated() {
            #expect(record.id == "\(template.id)/gesture/\(index)")
            #expect(record.validationIssues().isEmpty)
            #expect(record.tearLabel == "tear\(template.holdCount)")
            #expect(record.subdivisions.count == template.holdCount + 1)
            #expect(record.internalHolds.count == template.holdCount)
            #expect(record.timingDomain == .beats)
            #expect(record.measuredSubdivisionRatio == nil)
            #expect(record.authoredSubdivisionRatio == template.subdivisionRatio)
            #expect(record.evidence.provenance == .authored)
            #expect(record.evidence.observation.source == .authored)
            #expect(record.evidence.observation.rawSampleCount == nil)
            #expect(record.faderTransitions.isEmpty)
            #expect(record.faderIntervals.count == 1)
            #expect(record.faderIntervals[0].state == .open)
            #expect(record.classifiedIntervals.allSatisfy { $0.state == .sounding || $0.state == .hold })
            let movingTime = record.subdivisions.reduce(0) { $0 + $1.span.duration }
            let ratioSum = template.subdivisionRatio.reduce(0, +)
            for (sliceIndex, slice) in record.subdivisions.enumerated() {
                #expect(slice.id == "\(record.id)/motion/\(sliceIndex)")
                #expect(slice.measuredCurve == nil)
                #expect(approximatelyEqual(slice.span.duration / movingTime, template.subdivisionRatio[sliceIndex] / ratioSum))
                let curve = try #require(slice.targetCurve)
                let sign = record.direction == .forward ? 1.0 : -1.0
                #expect((try #require(curve.endPosition) - #require(curve.startPosition)) * sign > 0)
                if sliceIndex < template.holdCount {
                    let hold = record.internalHolds[sliceIndex]
                    #expect(hold.id == "\(record.id)/hold/\(sliceIndex)")
                    #expect(hold.label.effective == .stationary)
                    #expect(hold.span.startTime == slice.span.endTime)
                    #expect(hold.span.endTime == record.subdivisions[sliceIndex + 1].span.startTime)
                    #expect(hold.position == curve.endPosition)
                    #expect(hold.position == record.subdivisions[sliceIndex + 1].targetCurve?.startPosition)
                    #expect(approximatelyEqual(hold.span.duration, 1.0 / 16))
                }
            }
            totalDuration += movingTime + record.internalHolds.reduce(0) { $0 + $1.span.duration }
            if index > 0 {
                #expect(records[index - 1].subdivisions.last?.span.endTime == record.subdivisions.first?.span.startTime)
                #expect(records[index - 1].subdivisions.last?.targetCurve?.endPosition == record.subdivisions.first?.targetCurve?.startPosition)
            }
        }
        #expect(approximatelyEqual(totalDuration, template.durationBeats))
    }

    @Test("Unequal two-tear target has exact 1:2:1 moving times and explicit holds")
    func unequalSnapshot() throws {
        let records = try #require(ScratchNotation.internalCanonicalGestureRecords(
            forTemplateID: "scratchlab.tear.2.forward-backward.unequal.v1"))
        #expect(records.flatMap { $0.subdivisions.map { [$0.span.startTime, $0.span.endTime] } } == [
            [0, 0.21875], [0.28125, 0.71875], [0.78125, 1],
            [1, 1.21875], [1.28125, 1.71875], [1.78125, 2]
        ])
        #expect(records.flatMap { $0.internalHolds.map { [$0.span.startTime, $0.span.endTime] } } == [
            [0.21875, 0.28125], [0.71875, 0.78125], [1.21875, 1.28125], [1.71875, 1.78125]
        ])
        #expect(records[0].subdivisions.first?.targetCurve?.startPosition == 0)
        #expect(records[0].subdivisions.last?.targetCurve?.endPosition == 1)
        #expect(records[1].subdivisions.first?.targetCurve?.startPosition == 1)
        #expect(records[1].subdivisions.last?.targetCurve?.endPosition == 0)
    }

    @Test("Expansion and record serialization are deterministic", arguments: ScratchNotation.internalCanonicalTearTemplates)
    func deterministic(_ template: Template) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try #require(template.expanded())
        let bytes = try encoder.encode(first)
        #expect(bytes == (try encoder.encode(#require(template.expanded()))))
        #expect(try JSONDecoder().decode([Record].self, from: bytes) == first)
        let retimed = self.template(id: template.id, form: template.form, holds: template.holdCount,
            ratio: template.subdivisionRatio, duration: 2, holdDuration: 0.125)
        let slower = try #require(retimed.expanded())
        #expect(first.map(\.id) == slower.map(\.id))
        #expect(first.flatMap { $0.subdivisions.map(\.id) } == slower.flatMap { $0.subdivisions.map(\.id) })
        #expect(first.flatMap { $0.internalHolds.map(\.id) } == slower.flatMap { $0.internalHolds.map(\.id) })
    }

    @Test("Bad ratios, counts, durations and IDs fail without partial expansion")
    func malformedDefinitions() {
        let invalid = [
            template(id: ""), template(holds: 0), template(holds: 4), template(holds: Int.max),
            template(ratio: []), template(ratio: [1]), template(ratio: [1, 1, 1]),
            template(ratio: [0, 1]), template(ratio: [-1, 2]), template(ratio: [.nan, 1]),
            template(ratio: [.infinity, 1]), template(ratio: [.greatestFiniteMagnitude, .greatestFiniteMagnitude]),
            template(duration: 0), template(duration: -1), template(duration: .nan), template(duration: .infinity),
            template(form: .forwardBackward, duration: .greatestFiniteMagnitude),
            template(holdDuration: 0), template(holdDuration: -1), template(holdDuration: .nan),
            template(holdDuration: .infinity), template(holdDuration: 1), template(holdDuration: 2)
        ]
        for candidate in invalid {
            #expect(!candidate.validationIssues().isEmpty)
            #expect(candidate.expanded() == nil)
        }
        #expect(template(ratio: [.leastNonzeroMagnitude, .greatestFiniteMagnitude]).expanded() == nil)
        #expect(template(holdDuration: .leastNonzeroMagnitude).expanded() == nil)
    }

    @Test("Authoring validation rejects broken direction, continuity, ratios, count and fader")
    func invalidExpansions() throws {
        let template = template()
        let record = try #require(template.expanded()?.first)
        let slice = record.subdivisions[0]
        let curve = try #require(slice.targetCurve)
        let hold = record.internalHolds[0]
        let reversedCurve = Record.MotionCurve(points: [
            .init(time: slice.span.startTime, position: 0.5), .init(time: slice.span.endTime, position: 0)
        ], evidence: curve.evidence)
        let badCurve = Record.Subdivision(id: slice.id, span: slice.span, evidence: slice.evidence,
            targetCurve: reversedCurve, authoredDurationWeight: 1)
        let badWeight = Record.Subdivision(id: slice.id, span: slice.span, evidence: slice.evidence,
            targetCurve: curve, authoredDurationWeight: 2)
        let badHold = Record.TearHold(id: hold.id, span: hold.span, label: hold.label, evidence: hold.evidence, position: 0.9)
        let gap = Record.TearHold(id: hold.id, span: .init(startTime: hold.span.startTime + 0.01, endTime: hold.span.endTime),
            label: hold.label, evidence: hold.evidence, position: hold.position)
        let closed = Record.FaderSpan(id: "closed", span: record.faderIntervals[0].span, state: .closed, evidence: record.evidence)
        let invalid = [
            replacing(record, direction: .backward), replacing(record, subdivisions: [badCurve, record.subdivisions[1]]),
            replacing(record, subdivisions: [badWeight, record.subdivisions[1]]), replacing(record, holds: [badHold]),
            replacing(record, holds: [gap]), replacing(record, holds: []), replacing(record, fader: []),
            replacing(record, fader: [closed]), replacing(record, edges: [
                .init(id: "click", time: 0.5, state: .closed, evidence: record.evidence)
            ])
        ]
        for candidate in invalid { #expect(!template.expansionValidationIssues([candidate]).isEmpty) }
        #expect(!template.expansionValidationIssues([]).isEmpty)
        #expect(!template.expansionValidationIssues([record, record]).isEmpty)
        // Valid records can still violate this template's total/ratio contract.
        let longer = try #require(self.template(duration: 2).expanded())
        #expect(!template.expansionValidationIssues(longer).isEmpty)
        let unequal = try #require(self.template(ratio: [1, 2]).expanded())
        #expect(!template.expansionValidationIssues(unequal).isEmpty)
    }

    @Test("Factory output renders through the shared target path at selected tempos", arguments: [60.0, 120.0, 173.0])
    func sharedRenderer(_ bpm: Double) throws {
        let records = try #require(ScratchNotation.internalCanonicalGestureRecords(
            forTemplateID: "scratchlab.tear.3.forward-backward.unequal.v1"))
        let frame = try #require(ScratchStrokeGeometry.CanonicalFrame(timeRange: 0...(2 * 60 / bpm),
            positionRange: 0...1, coordinateSpace: .samplePosition, beatsPerMinute: bpm))
        let result = ScratchStrokeGeometry.canonicalGeometry(records: records, layer: .target, frame: frame)
        #expect(result.missingMotion.isEmpty)
        #expect(!result.hasUnplacedEvidence)
        #expect(result.faderEdges.isEmpty)
        #expect(result.fader.allSatisfy { $0.state == .open })
        #expect(result.motion.segments.count == 14)
        let performance = ScratchStrokeGeometry.canonicalGeometry(records: records, layer: .performance, frame: frame)
        #expect(performance.missingMotion.count > 0)
    }

    @Test("Internal targets do not promote curriculum techniques or captured references")
    func productionBoundary() {
        #expect(ScratchNotation.canonicalBeatPatterns.map(\.scratchID) == ["baby_scratch"])
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "tear") == nil)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "orbit") == nil)
        for template in ScratchNotation.internalCanonicalTearTemplates {
            #expect(ScratchNotation.canonicalBeatPattern(forScratchID: template.id) == nil)
        }
        #expect(ScratchLibrary.shared.allScratches.count == 20)
        #expect(ScratchLibrary.shared.comboScratches.count == 5)
        #expect(ScratchLibrary.shared.scratch(byID: "tear")?.faderRequired == false)
        #expect(ScratchLibrary.shared.scratch(byID: "orbit")?.faderRequired == true)
        #expect(ReferenceTechnique.minimumRequiredSet.filter(\.hasVerifiedTargetSemantics).map(\.id) == ["baby_scratch"])
    }
}
#endif

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

// MARK: - Prompt 2: lossless gesture records (no app consumer)

private typealias TearRecord = ScratchNotation.GestureRecord

private func recordEvidence(_ provenance: ScratchNotationProvenance = .measured,
                            source: ScratchNotationEvidenceSource = .platterTimeline) -> TearRecord.Evidence {
    .init(provenance: provenance,
          observation: .init(source: source, confidence: 0.87, reason: "fixture_observation", rawSampleCount: 17))
}

private func losslessTearFixture() -> TearRecord {
    let evidence = recordEvidence()
    let authored = recordEvidence(.authored, source: .authored)
    let spans: [TearRecord.TimeSpan] = [
        .init(startTime: 0.125, endTime: 0.375),
        .init(startTime: 0.5, endTime: 1),
        .init(startTime: 1.25, endTime: 2)
    ]
    let subdivisions = spans.enumerated().map { index, span in
        let start = Double(index) - 0.4
        return TearRecord.Subdivision(
            id: "motion-\(index)", span: span, evidence: evidence,
            measuredCurve: .init(points: [
                .init(time: span.startTime, position: start),
                .init(time: span.startTime + span.duration * 0.13, position: start + 0.09),
                .init(time: span.startTime + span.duration * 0.67, position: start + 0.83),
                .init(time: span.endTime, position: start + 1)
            ], evidence: evidence),
            targetCurve: .init(points: [
                .init(time: span.startTime, position: start),
                .init(time: span.endTime, position: start + 1)
            ], evidence: authored), authoredDurationWeight: [1, 2, 1][index])
    }
    return .init(id: "gesture-stable", direction: .forward, timingDomain: .seconds,
                 coordinateSpace: .samplePosition, evidence: evidence, subdivisions: subdivisions,
                 internalHolds: [
                    .init(id: "pause-a", span: .init(startTime: 0.375, endTime: 0.5),
                          label: .init(derived: .stationary), evidence: evidence, position: 0.6),
                    .init(id: "pause-b", span: .init(startTime: 1, endTime: 1.25),
                          label: .init(derived: .stationary), evidence: evidence, position: 1.6)
                 ], faderTransitions: [
                    .init(id: "edge-close", time: 0.625, state: .closed,
                          evidence: recordEvidence(source: .crossfaderRaw)),
                    .init(id: "edge-open", time: 1.125, state: .open,
                          evidence: recordEvidence(source: .crossfaderRaw))
                 ], faderIntervals: [
                    .init(id: "fader-a", span: .init(startTime: 0.125, endTime: 0.625), state: .open,
                          evidence: recordEvidence(source: .crossfaderRaw)),
                    .init(id: "fader-b", span: .init(startTime: 0.625, endTime: 1.125), state: .closed,
                          evidence: recordEvidence(source: .crossfaderRaw)),
                    .init(id: "fader-c", span: .init(startTime: 1.125, endTime: 2), state: .open,
                          evidence: recordEvidence(source: .crossfaderRaw))
                 ])
}

private func recordJSON(_ record: TearRecord) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
}

private func decodeRecord(_ json: [String: Any]) throws -> TearRecord {
    try JSONDecoder().decode(TearRecord.self, from: JSONSerialization.data(withJSONObject: json))
}

@Suite("Lossless canonical tear records")
struct TearGestureRecordTests {
    @Test("Captured curves, authored curves, identities and evidence round-trip exactly")
    func capturedRoundTrip() throws {
        let original = losslessTearFixture()
        #expect(original.validationIssues().isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(TearRecord.self, from: data)
        #expect(decoded == original)
        #expect(try encoder.encode(decoded) == data)
        #expect(decoded.subdivisions.map(\.id) == ["motion-0", "motion-1", "motion-2"])
        #expect(decoded.subdivisions[0].measuredCurve?.startPosition == -0.4)
        #expect(decoded.subdivisions[2].measuredCurve?.endPosition == 2.6)
        #expect(decoded.subdivisions[0].measuredCurve?.points.count == 4)
        #expect(decoded.tearLabel == "tear2")
        #expect(decoded.authoredSubdivisionRatio == [1, 2, 1])
        #expect(decoded.measuredSubdivisionRatio == [1.0 / 6, 1.0 / 3, 0.5])
        #expect(decoded.classifiedIntervals == original.classifiedIntervals)
        let json = try recordJSON(decoded)
        #expect(json["tearLabel"] == nil)
        #expect(json["measuredSubdivisionRatio"] == nil)
        #expect(json["classifiedIntervals"] == nil)
        #expect(json["version"] == nil)
    }

    @Test("Tempo-free authored targets retain arbitrary curves and do not claim measured ratios")
    func authoredRoundTrip() throws {
        let evidence = recordEvidence(.authored, source: .authored)
        let record = TearRecord(id: "target-gesture", direction: .backward, timingDomain: .beats,
            coordinateSpace: .platterRevolutions, evidence: evidence,
            subdivisions: [.init(id: "target-motion", span: .init(startTime: 0, endTime: 0.75), evidence: evidence,
                targetCurve: .init(points: [.init(time: 0, position: 3), .init(time: 0.18, position: 2.27),
                                          .init(time: 0.75, position: -0.5)], evidence: evidence))])
        let decoded = try decodeRecord(recordJSON(record))
        #expect(decoded == record)
        #expect(decoded.validationIssues().isEmpty)
        #expect(decoded.measuredSubdivisionRatio == nil)
        #expect(decoded.authoredSubdivisionRatio == nil)
        #expect(decoded.tearLabel == nil)
    }

    @Test("Fader boundaries partition moving and stationary intervals independently")
    func intervalClassification() {
        let record = losslessTearFixture()
        #expect(record.classifiedIntervals.map(\.state) == [.sounding, .hold, .sounding, .ghost, .ghostHold, .hold, .sounding])
        #expect(record.classifiedIntervals.map(\.audibility) == [.audible, .silent, .audible, .silent, .silent, .silent, .audible])
        #expect(record.classifiedIntervals[3].span == .init(startTime: 0.625, endTime: 1))
    }

    @Test("Edges alone never extend fader evidence or create phantom clicks")
    func absentFaderIntervalsStayUnknown() throws {
        var json = try recordJSON(losslessTearFixture())
        json["faderIntervals"] = []
        let record = try decodeRecord(json)
        #expect(record.validationIssues().isEmpty)
        #expect(record.classifiedIntervals.allSatisfy { $0.audibility == .unknown })
        #expect(record.tearLabel == "tear2")
        #expect(record.faderTransitions.count == 2)
    }

    @Test("Fader gaps remain unknown without affecting the tear count")
    func faderGap() throws {
        var json = try recordJSON(losslessTearFixture())
        var intervals = try #require(json["faderIntervals"] as? [[String: Any]])
        intervals.remove(at: 1)
        json["faderIntervals"] = intervals
        let record = try decodeRecord(json)
        #expect(record.validationIssues().isEmpty)
        #expect(record.classifiedIntervals.map(\.state) == [.sounding, .hold, .sounding, .unknown, .unknown, .hold, .sounding])
        #expect(record.tearLabel == "tear2")
    }

    @Test("Every provenance value and its raw observation survive Codable", arguments: ScratchNotationProvenance.allCases)
    func provenanceRoundTrip(_ provenance: ScratchNotationProvenance) throws {
        let evidence = recordEvidence(provenance)
        let data = try JSONEncoder().encode(evidence)
        #expect(try JSONDecoder().decode(TearRecord.Evidence.self, from: data) == evidence)
    }

    @Test("Manual correction preserves derived label and measured evidence")
    func manualCorrection() throws {
        var json = try recordJSON(losslessTearFixture())
        var holds = try #require(json["internalHolds"] as? [[String: Any]])
        holds[0]["label"] = ["derived": "unknown", "correction": "stationary"]
        json["internalHolds"] = holds
        let record = try decodeRecord(json)
        #expect(record.validationIssues().isEmpty)
        #expect(record.tearLabel == "tear2")
        #expect(record.internalHolds[0].label.derived == .unknown)
        #expect(record.internalHolds[0].label.isCorrected)
        #expect(record.internalHolds[0].evidence == losslessTearFixture().internalHolds[0].evidence)
        #expect(try decodeRecord(recordJSON(record)) == record)
    }

    @Test("Release, unknown and travelling intervals cannot be counted as stationary holds",
          arguments: ["released", "unknown", "forward", "backward"])
    func nonStationaryHold(_ state: String) throws {
        var json = try recordJSON(losslessTearFixture())
        var holds = try #require(json["internalHolds"] as? [[String: Any]])
        holds[0]["label"] = ["derived": state]
        json["internalHolds"] = holds
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.tearLabel == nil)
        #expect(record.classifiedIntervals.allSatisfy { $0.audibility == .unknown })
    }

    @Test("Malformed bounds and missing holds are retained but cannot assert a tear",
          arguments: ["zeroWidth", "missingHold", "unboundedHold", "unordered", "duplicateID"])
    func malformedMotion(_ variant: String) throws {
        var json = try recordJSON(losslessTearFixture())
        var subdivisions = try #require(json["subdivisions"] as? [[String: Any]])
        var holds = try #require(json["internalHolds"] as? [[String: Any]])
        switch variant {
        case "zeroWidth": holds[0]["span"] = ["startTime": 0.375, "endTime": 0.375]
        case "missingHold": holds.removeLast()
        case "unboundedHold": holds[1]["span"] = ["startTime": 1.0, "endTime": 4.0]
        case "unordered": subdivisions.swapAt(0, 1)
        default: subdivisions[0]["id"] = "motion-1"
        }
        json["subdivisions"] = subdivisions
        json["internalHolds"] = holds
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.tearLabel == nil)
        #expect(try decodeRecord(recordJSON(record)) == record)
    }

    @Test("Unsupported fader provenance cannot create an audible assertion")
    func phantomFaderGuard() throws {
        var json = try recordJSON(losslessTearFixture())
        var intervals = try #require(json["faderIntervals"] as? [[String: Any]])
        let motion = try #require(json["evidence"] as? [String: Any])
        for index in intervals.indices { intervals[index]["evidence"] = motion }
        json["faderIntervals"] = intervals
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.classifiedIntervals.allSatisfy { $0.audibility == .unknown })
        #expect(record.tearLabel == "tear2")
    }

    @Test("Simultaneous transitions have stable ID ordering without losing edges")
    func transitionOrdering() throws {
        var json = try recordJSON(losslessTearFixture())
        var edges = try #require(json["faderTransitions"] as? [[String: Any]])
        edges[1]["time"] = edges[0]["time"]
        json["faderTransitions"] = edges
        let record = try decodeRecord(json)
        #expect(record.validationIssues().isEmpty)
        #expect(try decodeRecord(recordJSON(record)).faderTransitions.map(\.id) == ["edge-close", "edge-open"])
        json["faderTransitions"] = Array(edges.reversed())
        #expect(try !decodeRecord(json).validationIssues().isEmpty)
    }

    @Test("Malformed confidence survives decode for validation instead of being clamped")
    func malformedConfidencePreserved() throws {
        var json = try recordJSON(losslessTearFixture())
        var evidence = try #require(json["evidence"] as? [String: Any])
        var observation = try #require(evidence["observation"] as? [String: Any])
        observation["confidence"] = 7.5
        evidence["observation"] = observation
        json["evidence"] = evidence
        let record = try decodeRecord(json)
        #expect(record.evidence.observation.confidence == 7.5)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.tearLabel == nil)
        #expect(try decodeRecord(recordJSON(record)) == record)
    }

    @Test("Unknown curve data stays absent rather than inventing endpoint positions")
    func missingOptionalCurveFields() throws {
        var json = try recordJSON(losslessTearFixture())
        var subdivisions = try #require(json["subdivisions"] as? [[String: Any]])
        for index in subdivisions.indices {
            subdivisions[index].removeValue(forKey: "measuredCurve")
            subdivisions[index].removeValue(forKey: "targetCurve")
            subdivisions[index].removeValue(forKey: "authoredDurationWeight")
        }
        json["subdivisions"] = subdivisions
        let record = try decodeRecord(json)
        #expect(record.validationIssues().isEmpty)
        #expect(record.subdivisions.allSatisfy { $0.measuredCurve == nil && $0.targetCurve == nil })
        #expect(record.authoredSubdivisionRatio == nil)
        #expect(record.measuredSubdivisionRatio == [1.0 / 6, 1.0 / 3, 0.5])
    }

    @Test("Inferred, corrected and unknown timing is retained without claiming a measured ratio",
          arguments: [ScratchNotationProvenance.inferred, .manuallyCorrected, .unknown])
    func unmeasuredTiming(_ provenance: ScratchNotationProvenance) throws {
        var json = try recordJSON(losslessTearFixture())
        var subdivisions = try #require(json["subdivisions"] as? [[String: Any]])
        var evidence = try #require(subdivisions[0]["evidence"] as? [String: Any])
        evidence["provenance"] = provenance.rawValue
        subdivisions[0]["evidence"] = evidence
        json["subdivisions"] = subdivisions
        let record = try decodeRecord(json)
        #expect(record.measuredSubdivisionRatio == nil)
        #expect(try decodeRecord(recordJSON(record)) == record)
        if provenance == .unknown {
            #expect(record.tearLabel == nil)
            #expect(record.classifiedIntervals.allSatisfy { $0.audibility == .unknown })
        } else {
            #expect(record.validationIssues().isEmpty)
            #expect(record.tearLabel == "tear2")
        }
    }

    @Test("An authored source cannot masquerade as measured timing")
    func authoredIsNotMeasured() throws {
        var json = try recordJSON(losslessTearFixture())
        var evidence = try #require(json["evidence"] as? [String: Any])
        var observation = try #require(evidence["observation"] as? [String: Any])
        observation["source"] = "authored"
        evidence["observation"] = observation
        json["evidence"] = evidence
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.measuredSubdivisionRatio == nil)
    }

    @Test("Malformed fader spans stay unknown even when their numeric bounds cover motion")
    func malformedFaderSpan() throws {
        var json = try recordJSON(losslessTearFixture())
        var intervals = try #require(json["faderIntervals"] as? [[String: Any]])
        intervals[0]["span"] = ["startTime": -1, "endTime": 0.625]
        json["faderIntervals"] = intervals
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(record.classifiedIntervals.first?.audibility == .unknown)
        #expect(record.tearLabel == "tear2")
    }

    @Test("Unordered curve samples are retained exactly and reported rather than sorted")
    func malformedCurvePreserved() throws {
        var json = try recordJSON(losslessTearFixture())
        var subdivisions = try #require(json["subdivisions"] as? [[String: Any]])
        var curve = try #require(subdivisions[0]["measuredCurve"] as? [String: Any])
        var points = try #require(curve["points"] as? [[String: Any]])
        points.swapAt(1, 2)
        curve["points"] = points
        subdivisions[0]["measuredCurve"] = curve
        json["subdivisions"] = subdivisions
        let record = try decodeRecord(json)
        #expect(!record.validationIssues().isEmpty)
        #expect(try decodeRecord(recordJSON(record)) == record)
        #expect(record.subdivisions[0].measuredCurve?.points.count == 4)
    }

    @Test("Editing timing never regenerates identities or changes unrelated observations")
    func stableIDsAfterTimingEdit() throws {
        let original = losslessTearFixture()
        var json = try recordJSON(original)
        var edges = try #require(json["faderTransitions"] as? [[String: Any]])
        edges[0]["time"] = 0.7
        json["faderTransitions"] = edges
        let record = try decodeRecord(json)
        #expect(record.id == original.id)
        #expect(record.faderTransitions.map(\.id) == original.faderTransitions.map(\.id))
        #expect(record.subdivisions == original.subdivisions)
        #expect(record.internalHolds == original.internalHolds)
        #expect(record.faderIntervals == original.faderIntervals)
    }
}

// Synthetic physical evidence only. Fixture speeds are calibrated revolutions/s;
// sample positions can be tested using an explicit, equivalent unit conversion.
private typealias MotionSegmenter = PlatterMotionSegmenter

private func motionCalibration(sign: Double = 1, origin: Double = 0, scale: Double = 1,
                               basis: MotionSegmenter.Calibration.Basis = .physicalPlatterDisplacement)
    -> MotionSegmenter.Calibration {
    .init(basis: basis, reference: "synthetic-calibration", inputOrigin: origin,
          unitsPerInputUnit: scale, forwardSign: sign)
}

private func motionFixture(_ legs: [(Double, Double)], rate: Double = 200) -> [MotionSegmenter.Sample] {
    let duration = legs.reduce(0) { $0 + $1.0 }
    var times = (0...Int((duration * rate).rounded(.down))).map { Double($0) / rate }
    if duration - times.last! > 1e-9 { times.append(duration) }
    return times.map { time in
        var remaining = time
        var position = 0.0
        for (duration, speed) in legs {
            let elapsed = min(max(remaining, 0), duration)
            position += elapsed * speed
            remaining -= elapsed
        }
        return .init(time: time, position: position)
    }
}

private func segmentMotion(_ legs: [(Double, Double)], rate: Double = 200,
                           configuration: MotionSegmenter.Configuration = .init()) -> MotionSegmenter.Result {
    MotionSegmenter.segment(motionFixture(legs, rate: rate), calibration: motionCalibration(),
                            configuration: configuration)
}

@Suite("Calibrated platter motion synthetic fixtures")
struct PlatterMotionSegmenterTests {
    @Test("Baby turnarounds never become same-direction tears", arguments: [100.0, 200, 400], [0.0, 0.06])
    func babyTurnaround(rate: Double, stop: Double) throws {
        let result = segmentMotion([(0.3, 0.8), (stop, 0), (0.3, -0.8)], rate: rate)
        #expect(result.gestures.map(\.direction) == [.forward, .backward])
        #expect(result.gestures.allSatisfy { !$0.isTearCandidate })
        let reversal = try #require(result.reversals.first)
        #expect(result.reversals.count == 1)
        #expect(abs(reversal.span.startTime - 0.3) < 1e-9)
        #expect(abs(reversal.span.endTime - (0.3 + stop)) < 1e-9)
    }

    @Test("One, two and three tears across rates, directions, speeds and hold lengths",
          arguments: [100.0, 200, 400], [-1.0, 1])
    func tearMatrix(rate: Double, sign: Double) throws {
        for count in 1...3 {
            for speed in [0.12, 0.8, 1.6] {
                for hold in [0.04, 0.07, 0.12] {
                    var legs: [(Double, Double)] = [(0.2, sign * speed)]
                    for _ in 0..<count { legs += [(hold, 0), (0.2, sign * speed)] }
                    let result = segmentMotion(legs, rate: rate)
                    let gesture = try #require(result.gestures.first)
                    #expect(result.gestures.count == 1)
                    #expect(gesture.direction == (sign > 0 ? .forward : .backward))
                    #expect(gesture.isTearCandidate)
                    #expect(gesture.tearHolds.count == count)
                    #expect(gesture.subdivisions.count == count + 1)
                    #expect(gesture.confidence == .supported)
                    #expect(result.reversals.isEmpty)
                    let ratios = try #require(gesture.measuredSubdivisionRatios)
                    #expect(ratios.allSatisfy { abs($0 - 1 / Double(count + 1)) < 1e-9 })
                    for (index, interval) in gesture.tearHolds.enumerated() {
                        let expected = 0.2 + Double(index) * (0.2 + hold)
                        #expect(abs(interval.span.startTime - expected) < 1e-9)
                        #expect(abs(interval.span.endTime - expected - hold) < 1e-9)
                        #expect(interval.boundaryResolutionSeconds <= 1 / rate + 1e-9)
                    }
                }
            }
        }
    }

    @Test("Unequal subdivisions preserve moving-duration ratios and measured geometry")
    func unequalSubdivisions() throws {
        let result = segmentMotion([(0.12, 0.4), (0.08, 0), (0.24, 0.8), (0.12, 0), (0.36, 0.3)])
        let gesture = try #require(result.gestures.first)
        let ratios = try #require(gesture.measuredSubdivisionRatios)
        #expect(ratios.count == 3)
        for (value, expected) in zip(ratios, [1.0 / 6, 2.0 / 6, 3.0 / 6]) {
            #expect(abs(value - expected) < 1e-9)
        }
        #expect(abs(gesture.span.duration - 0.92) < 1e-9)
        #expect(abs(gesture.subdivisions.last!.points.last!.position - 0.348) < 1e-9)
        #expect(gesture.subdivisions[0].points.count == 25)
    }

    @Test("Off-grid pause boundaries are within one sample interval, without snapping",
          arguments: [100.0, 200, 400], [-1.0, 1])
    func boundaryResolution(rate: Double, sign: Double) throws {
        for start in [0.201, 0.203, 0.207, 0.213] {
            let result = segmentMotion([(start, sign * 0.8), (0.073, 0), (0.217, sign * 0.8)], rate: rate)
            let hold = try #require(result.gestures.first?.tearHolds.first)
            #expect(abs(hold.span.startTime - start) <= 1 / rate + 1e-9)
            #expect(abs(hold.span.endTime - start - 0.073) <= 1 / rate + 1e-9)
            #expect(hold.boundaryResolutionSeconds <= 1 / rate + 1e-9)
        }
    }

    @Test("Slow drag stays moving; prolonged sub-threshold drift stays uncertain")
    func slowDrag() throws {
        let slow = segmentMotion([(0.4, 0.09), (0.4, 0.03), (0.4, 0.09)])
        #expect(slow.gestures.count == 1)
        #expect(slow.gestures[0].tearHolds.isEmpty)
        #expect(slow.confidence == .low)
        #expect(slow.reasons.contains(.hysteresisBand))
        #expect(slow.gestures[0].measuredSubdivisionRatios == nil)
        let drift = segmentMotion([(0.2, 0.4), (0.5, 0.01), (0.2, 0.4)])
        #expect(drift.segments.map(\.state) == [.forward, .unknown, .forward])
        #expect(drift.reasons.contains(.stationaryDrift))
        #expect(drift.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("Intentional long hold survives and leading/trailing stationary spans are not tears")
    func longHold() throws {
        let result = segmentMotion([(0.2, 0), (0.2, 0.6), (2.0, 0), (0.2, 0.6), (0.2, 0)])
        let gesture = try #require(result.gestures.first)
        #expect(result.gestures.count == 1)
        #expect(gesture.tearHolds.count == 1)
        #expect(abs(gesture.tearHolds[0].span.duration - 2) < 1e-9)
        #expect(abs(gesture.span.startTime - 0.2) < 1e-9)
        #expect(abs(gesture.span.endTime - 2.6) < 1e-9)
    }

    @Test("Near-zero jitter and bounded spikes cannot invent travel or extra holds")
    func nearZeroJitter() throws {
        let tiny = (0...200).map { i in
            MotionSegmenter.Sample(time: Double(i) / 200, position: i.isMultiple(of: 2) ? 0 : 0.00004)
        }
        let result = MotionSegmenter.segment(tiny, calibration: motionCalibration(), configuration: .init())
        #expect(result.segments.map(\.state) == [.stationary])
        #expect(result.gestures.isEmpty)
        // One paired high-speed spike inside an otherwise real hold.
        var samples = motionFixture([(0.2, 0.6), (0.12, 0), (0.2, 0.6)])
        samples[50] = .init(time: samples[50].time, position: samples[50].position + 0.00045)
        let spike = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
        // Opposite one-edge bursts are ambiguous, never extra tear subdivisions.
        #expect(spike.gestures.allSatisfy { $0.tearHolds.count <= 1 })
        #expect(spike.confidence != .supported)
    }

    @Test("Quick real reversal stays separate; sub-minimum reversal is unknown")
    func quickReversal() throws {
        let quick = segmentMotion([(0.2, 0.5), (0.04, -0.5), (0.2, 0.5)])
        #expect(quick.gestures.map(\.direction) == [.forward, .backward, .forward])
        #expect(quick.reversals.count == 2)
        #expect(quick.gestures.allSatisfy { !$0.isTearCandidate })
        let tooQuick = segmentMotion([(0.2, 0.5), (0.015, -0.5), (0.2, 0.5)])
        #expect(tooQuick.segments.map(\.state) == [.forward, .unknown, .forward])
        #expect(tooQuick.reasons.contains(.belowMinimumMovingDuration))
        #expect(tooQuick.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("Continuous free-running revolutions never wrap into reversals or tears",
          arguments: [-1.0, 1])
    func freeRunningRevolutions(sign: Double) throws {
        let result = segmentMotion([(12, sign * 5.0 / 9)])
        #expect(result.gestures.count == 1)
        #expect(result.gestures[0].tearHolds.isEmpty)
        #expect(result.reversals.isEmpty)
        #expect(abs(result.segments[0].points.last!.position - sign * 20 / 3) < 1e-9)
        #expect(result.reasons.contains(.handContactUnobserved))
    }
}

@Suite("Platter segmenter quality and parameter boundaries")
struct PlatterMotionSegmenterQualityTests {
    @Test("Exact minimum hold and movement durations are inclusive", arguments: [0.039, 0.04, 0.041])
    func minimumDurations(duration: Double) throws {
        let result = segmentMotion([(0.1, 0.5), (duration, 0), (0.1, 0.5)], rate: 1000)
        #expect(result.gestures.contains(where: \.isTearCandidate) == (duration >= 0.04))
        if duration < 0.04 { #expect(result.reasons.contains(.belowMinimumHoldDuration)) }
        let moving = segmentMotion([(duration, 0.5)], rate: 1000)
        #expect(moving.gestures.isEmpty == (duration < 0.04))
    }

    @Test("Repair duration boundary is inclusive and cannot consume a valid short hold",
          arguments: [0.019, 0.02, 0.021, 0.04])
    func repairDuration(duration: Double) throws {
        let result = segmentMotion([(0.1, 0.5), (duration, 0), (0.1, 0.5)], rate: 1000)
        #expect(result.reasons.contains(.mergedJitter) == (duration <= 0.02))
        #expect(result.gestures.contains(where: \.isTearCandidate) == (duration >= 0.04))
        if duration <= 0.02 {
            #expect(result.gestures.count == 1)
            #expect(result.gestures[0].measuredSubdivisionRatios == nil)
            #expect(result.gestures[0].confidence == .low)
        }
    }

    @Test("Jitter excursion limit prevents erasing a real small reversal",
          arguments: [0.00049, 0.0005, 0.00051])
    func jitterExcursion(excursion: Double) {
        let result = segmentMotion([(0.1, 0.5), (0.005, -excursion / 0.005), (0.1, 0.5)], rate: 1000)
        #expect(result.reasons.contains(.mergedJitter) == (excursion <= 0.0005))
        #expect(result.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("Speed thresholds and hysteresis are explicit", arguments: [0.07999, 0.08, 0.08001])
    func movingThreshold(speed: Double) {
        let initial = segmentMotion([(0.2, speed)])
        #expect(initial.gestures.isEmpty == (speed < 0.08))
        let sustained = segmentMotion([(0.1, 0.5), (0.2, speed)])
        #expect(sustained.gestures.count == 1)
        #expect(sustained.gestures[0].tearHolds.isEmpty)
    }

    @Test("Stationary threshold is inclusive; hysteresis-band holds stay unknown",
          arguments: [0.01999, 0.02, 0.02001])
    func stationaryThreshold(speed: Double) {
        var c = MotionSegmenter.Configuration()
        c.maximumStationaryExcursion = 0.01
        let result = segmentMotion([(0.1, 0.5), (0.05, speed), (0.1, 0.5)], rate: 1000, configuration: c)
        #expect(result.gestures.contains(where: \.isTearCandidate) == (speed <= 0.02))
        let bandAfterStop = segmentMotion([(0.1, 0.5), (0.04, 0), (0.05, 0.03), (0.1, 0.5)],
                                         rate: 1000, configuration: c)
        #expect(bandAfterStop.reasons.contains(.ambiguousMotion))
        #expect(bandAfterStop.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("A bounded dropped event can join sustained travel only with low confidence")
    func shortDropout() throws {
        let samples = motionFixture([(0.4, 0.5)], rate: 100).enumerated()
            .filter { $0.offset != 20 }.map(\.element)
        let result = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
        #expect(result.gestures.count == 1)
        #expect(result.reasons.contains(.bridgedDropout))
        #expect(result.reasons.contains(.insufficientSampleRate))
        #expect(result.confidence == .low)
        #expect(result.gestures[0].measuredSubdivisionRatios == nil)
        #expect(result.gestures[0].tearHolds.isEmpty)
        #expect(result.segments[0].points.count == samples.count)
    }

    @Test("Dropouts within holds and across a reversal stay unknown")
    func unsafeDropouts() {
        for middleSpeed in [0.0, -0.5] {
            let source = motionFixture([(0.2, 0.5), (0.1, middleSpeed), (0.2, 0.5)], rate: 100)
            let samples = source.filter { $0.time < 0.2 || $0.time > 0.3 }
            let result = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
            #expect(result.segments.contains { $0.state == .unknown })
            #expect(result.reasons.contains(.sampleGap))
            #expect(!result.reasons.contains(.bridgedDropout))
            #expect(result.gestures.allSatisfy { !$0.isTearCandidate && $0.confidence == .low })
        }
        let source = motionFixture([(0.2, 0.5), (0.1, 0), (0.2, 0.5)], rate: 100)
        let shortGapInHold = source.enumerated().filter { $0.offset != 25 }.map(\.element)
        let result = MotionSegmenter.segment(shortGapInHold, calibration: motionCalibration(), configuration: .init())
        #expect(!result.reasons.contains(.bridgedDropout))
        #expect(result.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("Sparse samples cannot establish either motion or a hold", arguments: [25.0, 50, 99, 100, 101])
    func sampleRateBoundary(rate: Double) {
        let result = segmentMotion([(0.4, 0.5), (0.2, 0), (0.4, 0.5)], rate: rate)
        if rate < 100 {
            #expect(result.confidence == .unknown)
            #expect(result.gestures.isEmpty)
            #expect(result.reasons.contains(.insufficientSampleRate))
        } else { #expect(result.gestures.contains { $0.isTearCandidate }) }
    }

    @Test("Sample gap and repair limits are pinned independently", arguments: [0.049, 0.05, 0.051])
    func gapBoundary(gap: Double) {
        let result = MotionSegmenter.segment([.init(time: 0, position: 0), .init(time: gap, position: 0)],
                                            calibration: motionCalibration(), configuration: .init())
        #expect(result.confidence == .unknown)
        #expect(result.reasons.contains(.sampleGap) == (gap > 0.05))
        #expect(result.reasons.contains(.insufficientSampleRate) == (gap <= 0.05))
    }

    @Test("Duplicate/backward/nonfinite clocks and evidence are rejected without sorting")
    func malformedEvidence() {
        for times in [[0.0, 0], [0.2, 0.1], [-0.1, 0], [0, .nan], [0, .infinity]] {
            let result = MotionSegmenter.segment(times.map { .init(time: $0, position: 0) },
                                                 calibration: motionCalibration(), configuration: .init())
            #expect(result.confidence == .unknown)
            #expect(result.gestures.isEmpty)
            #expect(result.reasons.contains(.clockDiscontinuity) || result.reasons.contains(.nonfiniteEvidence))
        }
        for position in [Double.nan, .infinity] {
            let result = MotionSegmenter.segment([.init(time: 0, position: 0), .init(time: 0.1, position: position)],
                                                 calibration: motionCalibration(), configuration: .init())
            #expect(result.reasons == [.nonfiniteEvidence])
        }
        for count in [0, 1] {
            let result = MotionSegmenter.segment(Array(repeating: .init(time: 0, position: 0), count: count),
                                                 calibration: motionCalibration(), configuration: .init())
            #expect(result.reasons == [.insufficientSamples])
        }
    }

    @Test("Low input confidence and implausible jumps are not repaired into tears")
    func badMeasurements() {
        var samples = motionFixture([(0.2, 0.5), (0.1, 0), (0.2, 0.5)])
        samples[50].confidence = 0.2
        let low = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
        #expect(low.reasons.contains(.lowInputConfidence))
        #expect(low.gestures.allSatisfy { !$0.isTearCandidate })
        samples[50] = .init(time: samples[50].time, position: 10)
        let jump = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
        #expect(jump.reasons.contains(.implausibleSpeed))
        #expect(jump.gestures.allSatisfy { !$0.isTearCandidate })
    }

    @Test("Calibration is explicit, signed, unclamped and independent of arbitrary input origin")
    func coordinates() throws {
        let samples = motionFixture([(0.2, -0.5), (0.08, 0), (0.2, -0.5)])
        let baseline = MotionSegmenter.segment(samples, calibration: motionCalibration(), configuration: .init())
        let transformed = samples.map { MotionSegmenter.Sample(time: $0.time, position: 1234 - $0.position * 100) }
        let scaled = MotionSegmenter.segment(transformed, calibration: motionCalibration(sign: -1, origin: 1234, scale: 0.01),
                                             configuration: .init())
        #expect(scaled.segments.map(\.state) == baseline.segments.map(\.state))
        #expect(scaled.gestures.map(\.measuredSubdivisionRatios) == baseline.gestures.map(\.measuredSubdivisionRatios))
        for (lhs, rhs) in zip(scaled.segments.flatMap(\.points), baseline.segments.flatMap(\.points)) {
            #expect(lhs.time == rhs.time)
            #expect(abs(lhs.position - rhs.position) < 1e-9)
        }
        let samplePosition = MotionSegmenter.segment(samples, calibration: motionCalibration(basis: .samplePosition),
                                                     configuration: .init())
        #expect(samplePosition.coordinateSpace == .samplePosition)
        #expect(samplePosition.segments.last!.points.last!.position < 0)
        let raw = MotionSegmenter.segment(samples, calibration: motionCalibration(basis: .rawMotorPhase), configuration: .init())
        #expect(raw.reasons == [.unsupportedMotorPhase])
        #expect(raw.coordinateSpace == nil)
        #expect(raw.gestures.isEmpty)
    }

    @Test("Invalid parameters and calibration fail closed")
    func invalidParameters() {
        let source = motionFixture([(0.2, 0.5)])
        for invalid in [0.0, -1, Double.nan, .infinity] {
            var c = MotionSegmenter.Configuration()
            c.movingSpeed = invalid
            #expect(MotionSegmenter.segment(source, calibration: motionCalibration(), configuration: c).reasons == [.invalidConfiguration])
            #expect(MotionSegmenter.segment(source, calibration: motionCalibration(scale: invalid), configuration: .init()).reasons == [.invalidCalibration])
        }
        var c = MotionSegmenter.Configuration()
        c.maximumRepairDuration = c.minimumHoldDuration
        #expect(MotionSegmenter.segment(source, calibration: motionCalibration(), configuration: c).reasons == [.invalidConfiguration])
        #expect(MotionSegmenter.segment(source, calibration: motionCalibration(sign: 0), configuration: .init()).reasons == [.invalidCalibration])
    }

    @Test("Deterministic output retains total ordered coverage and does not alter canonical registry")
    func determinismAndCoverage() throws {
        let before = ScratchNotation.babyScratchGesturePattern
        let source = motionFixture([(0.2, 0.5), (0.06, 0), (0.2, 0.5), (0.1, -0.5)])
        let first = MotionSegmenter.segment(source, calibration: motionCalibration(), configuration: .init())
        #expect(first == MotionSegmenter.segment(source, calibration: motionCalibration(), configuration: .init()))
        #expect(first.segments.first?.span.startTime == source.first?.time)
        #expect(first.segments.last?.span.endTime == source.last?.time)
        for (left, right) in zip(first.segments, first.segments.dropFirst()) {
            #expect(left.span.endTime == right.span.startTime)
            #expect(left.points.last == right.points.first)
        }
        #expect(ScratchNotation.babyScratchGesturePattern == before)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "tear2") == nil)
    }
}

@Suite("Tear record backward compatibility")
struct TearGestureRecordCompatibilityTests {
    @Test("Legacy seconds notation needs no gesture fields and preserves its schema")
    func legacySecondsPayload() throws {
        let json = #"{"version":1,"scratchID":"baby_scratch","demoStart":0,"demoEnd":1,"timingBasis":"legacy_seconds","strokes":[{"startTime":0,"endTime":0.5,"direction":"forward","speedClassification":"medium","faderState":"open"},{"startTime":0.5,"endTime":1,"direction":"backward","speedClassification":"medium","faderState":"open"}]}"#
        let notation = try decodeNotation(fromJSON: json)
        #expect(notation.version == 1)
        #expect(notation.strokes.count == 2)
        #expect(notation.faderEvents.isEmpty)
        let encoded = try JSONEncoder().encode(notation)
        #expect(try JSONDecoder().decode(ScratchNotation.self, from: encoded) == notation)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["gestures"] == nil)
        #expect(object["gestureRecords"] == nil)
    }

    @Test("Prompt 1 payload still decodes without IDs, curves or new provenance")
    func promptOnePayload() throws {
        let json = #"{"version":1,"scratchID":"baby_scratch","timingBasis":"beat_canonical_test","motionSegments":[{"span":{"startBeat":0,"endBeat":0.5},"label":{"derived":"forward"},"evidence":{"source":"authored","confidence":1,"reason":"stroke"}},{"span":{"startBeat":0.5,"endBeat":1},"label":{"derived":"backward"},"evidence":{"source":"authored","confidence":1,"reason":"stroke"}}],"faderIntervals":[{"span":{"startBeat":0,"endBeat":1},"state":"open","evidence":{"source":"authored","confidence":1,"reason":"open"}}],"faderClicks":[]}"#
        let pattern = try JSONDecoder().decode(ScratchNotation.GesturePattern.self, from: Data(json.utf8))
        #expect(pattern.validationIssues().isEmpty)
        #expect(pattern.gestures.count == 2)
        #expect(pattern.tears.isEmpty)
        #expect(pattern.reversalBeats == [0.5])
        #expect(pattern.correlatedState(atBeat: 0.75) == .sounding)
        #expect(try JSONDecoder().decode(ScratchNotation.GesturePattern.self, from: JSONEncoder().encode(pattern)) == pattern)
    }

    @Test("Creating a rich record never changes Baby Scratch or technique registry eligibility")
    func babyRemainsUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(ScratchNotation.babyScratchCycle)
        _ = losslessTearFixture().classifiedIntervals
        #expect(try encoder.encode(ScratchNotation.babyScratchCycle) == before)
        #expect(ScratchNotation.babyScratchGesturePattern?.gestures.map(\.tearHoldCount) == [0, 0])
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "tear2") == nil)
    }
}

// MARK: - Prompt 6: conservative derived structure classification

fileprivate typealias DerivedStructure = ScratchNotationDerivedStructure
fileprivate typealias StructureClassifier = ScratchNotationStructureClassifier
fileprivate typealias StructureReason = ScratchNotationStructureReason
fileprivate typealias StructureReference = ScratchNotationEvidenceReference

/// `N` internal holds → `2N + 1` segments of same-direction travel separated
/// by bounded stationary intervals, one beat each, starting at beat 0.
private func tearShapePattern(holds: Int,
                              direction: ScratchNotationMotionState = .forward,
                              faderOverride: [ScratchNotation.FaderInterval]? = nil,
                              clicks: [ScratchNotation.FaderClick] = [])
-> ScratchNotation.GesturePattern {
    var segments: [ScratchNotation.PlatterMotionSegment] = []
    for index in 0...(2 * holds) {
        let start = Double(index)
        segments.append(motion(start, start + 1, index.isMultiple(of: 2) ? direction : .stationary))
    }
    let end = Double(2 * holds + 1)
    return gesturePattern(motionSegments: segments,
                          faderIntervals: faderOverride ?? [fader(0, end, .open)],
                          faderClicks: clicks)
}

private func soleCandidate(_ proposal: ScratchNotationStructureProposal) throws
-> ScratchNotationStructureProposal.Candidate {
    try #require(proposal.soleCandidate)
}

@Suite("Derived structure vocabulary boundaries")
struct DerivedStructureVocabularyTests {

    @Test("The proposable vocabulary is closed and excludes Chirp and Transformer")
    func vocabularyIsClosed() {
        #expect(Set(DerivedStructure.allCases.map(\.rawValue)) == [
            "baby", "tear1_candidate", "tear2_candidate", "tear3_candidate",
            "hold", "ghost", "ghost_hold"
        ])
        #expect(DerivedStructure.allCases.count == 7)
        for structure in DerivedStructure.allCases {
            #expect(structure.rawValue.contains("chirp") == false)
            #expect(structure.rawValue.contains("transform") == false)
        }
    }

    @Test("Tear candidates exist only for the supported 1...3 hold vocabulary")
    func tearCandidateRange() {
        #expect(DerivedStructure.tearCandidate(holdCount: 1) == .tear1Candidate)
        #expect(DerivedStructure.tearCandidate(holdCount: 2) == .tear2Candidate)
        #expect(DerivedStructure.tearCandidate(holdCount: 3) == .tear3Candidate)
        for unsupported in [-1, 0, 4, 9] {
            #expect(DerivedStructure.tearCandidate(holdCount: unsupported) == nil)
        }
        #expect(DerivedStructure.tear2Candidate.assertedTearHoldCount == 2)
        #expect(DerivedStructure.baby.assertedTearHoldCount == nil)
        #expect(DerivedStructure.hold.assertedTearHoldCount == nil)
        #expect(DerivedStructure.ghost.isTearCandidate == false)
        #expect(DerivedStructure.ghostHold.isTearCandidate == false)
    }

    @Test("Evidence references cite a stream and index without copying evidence")
    func referencesAreCitations() {
        #expect(StructureReference.motionSegment(index: 3).detail == "motionSegment[3]")
        #expect(StructureReference.faderInterval(index: 0).detail == "faderInterval[0]")
        #expect(StructureReference.faderClick(index: 7).detail == "faderClick[7]")
        #expect(StructureReference.motionSegment(index: 1) != StructureReference.faderInterval(index: 1))
    }

    @Test("Every reason carries a human-readable explanation")
    func reasonsAreReadable() {
        for reason in StructureReason.allCases {
            #expect(reason.detail.isEmpty == false)
            #expect(reason.detail != reason.rawValue)
        }
    }
}

@Suite("Derived structure classification — supported structures")
struct DerivedStructureClassificationTests {

    @Test("The canonical Baby cycle derives exactly one Baby and no tear")
    func canonicalBaby() throws {
        let pattern = try #require(ScratchNotation.babyScratchGesturePattern)
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.count == 1)
        let proposal = try #require(classification.proposals.first)
        #expect(proposal.scope == .reversal(fromGestureIndex: 0, toGestureIndex: 1))
        #expect(proposal.span == ScratchNotation.BeatSpan(startBeat: 0, endBeat: 1))
        let candidate = try soleCandidate(proposal)
        #expect(candidate.structure == .baby)
        #expect(approximatelyEqual(candidate.confidence, 1))
        #expect(proposal.reasons.contains(.directReversal))
        #expect(proposal.reasons.contains(.faderOpenThroughout))
        #expect(proposal.isAmbiguous == false)
        #expect(proposal.isUnknown == false)
        #expect(classification.tearCandidateProposals.isEmpty)
        #expect(classification.acceptedStructures == [.baby])
        #expect(classification.counts.tearHoldCountsByGesture == [0, 0])
        #expect(classification.counts.soundingRegionCount == 1)
        #expect(classification.counts.faderClickCount == 0)
    }

    @Test("One, two and three bounded holds derive the matching tear candidate",
          arguments: [(1, ScratchNotationDerivedStructure.tear1Candidate),
                      (2, .tear2Candidate), (3, .tear3Candidate)])
    func supportedTearCandidates(holds: Int, expected: ScratchNotationDerivedStructure) throws {
        let pattern = tearShapePattern(holds: holds)
        let classification = StructureClassifier.classify(pattern)
        let gestureProposal = try #require(classification.proposals.first { $0.scope == .gesture(index: 0) })
        let candidate = try soleCandidate(gestureProposal)
        #expect(candidate.structure == expected)
        #expect(candidate.structure.assertedTearHoldCount == holds)
        #expect(approximatelyEqual(candidate.confidence, 0.9))
        #expect(gestureProposal.reasons.contains(.sameDirectionPauseResume))
        #expect(gestureProposal.reasons.contains(.tearCountIsPlatterOnly))
        // N holds → N+1 sounding subdivisions, and the holds themselves are
        // separately proposed at segment scope.
        #expect(classification.counts.tearHoldCountsByGesture == [holds])
        #expect(classification.counts.soundingRegionCount == holds + 1)
        #expect(classification.proposals.filter { $0.soleCandidate?.structure == .hold }.count == holds)
    }

    @Test("A backward tear derives the same candidate as a forward one")
    func backwardTear() throws {
        let classification = StructureClassifier.classify(tearShapePattern(holds: 2, direction: .backward))
        #expect(classification.acceptedStructures.contains(.tear2Candidate))
        #expect(classification.counts.tearHoldCountsByGesture == [2])
    }

    @Test("Stationary with the fader open derives a Hold, never a tear on its own")
    func standaloneHold() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)],
                                     faderIntervals: [fader(0, 2, .open)])
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.count == 1)
        let proposal = try #require(classification.proposals.first)
        #expect(proposal.scope == .motionSegment(index: 0))
        let candidate = try soleCandidate(proposal)
        #expect(candidate.structure == .hold)
        #expect(approximatelyEqual(candidate.confidence, 0.9))
        #expect(proposal.reasons.contains(.boundedStationaryInterval))
        #expect(proposal.reasons.contains(.faderOpenThroughout))
        #expect(proposal.evidenceReferences == [.motionSegment(index: 0), .faderInterval(index: 0)])
        #expect(classification.counts.tearHoldCountsByGesture == [0])
    }

    @Test("A closed fader derives Ghost over travel and Ghost-Hold over stationary")
    func ghostAndGhostHold() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(1, 2, .stationary)],
                                     faderIntervals: [fader(0, 2, .closed)])
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.acceptedStructures == [.ghost, .ghostHold])
        for proposal in classification.proposals {
            #expect(proposal.reasons.contains(.faderClosedThroughout))
            let candidate = try soleCandidate(proposal)
            #expect(approximatelyEqual(candidate.confidence, 0.9))
        }
        #expect(classification.counts.soundingRegionCount == 0)
    }

    @Test("A sounding stroke alone names no structure")
    func soundingStrokeAssertsNothing() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward)],
                                     faderIntervals: [fader(0, 1, .open)])
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.isEmpty)
        #expect(classification.counts.soundingRegionCount == 1)
        #expect(classification.counts.tearHoldCountsByGesture == [0])
    }
}

@Suite("Derived structure classification — ambiguity stays ambiguous")
struct DerivedStructureAmbiguityTests {

    @Test("A fader that opens and closes inside one hold offers both readings")
    func mixedFaderOverHold() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)],
            faderIntervals: [fader(0, 0.5, .open), fader(0.5, 1, .closed)]
        )
        let classification = StructureClassifier.classify(pattern)
        let proposal = try #require(classification.proposals.first { $0.scope == .motionSegment(index: 0) })
        #expect(proposal.isAmbiguous)
        #expect(proposal.soleCandidate == nil)
        #expect(proposal.candidates.map(\.structure) == [.hold, .ghostHold])
        for candidate in proposal.candidates {
            #expect(approximatelyEqual(candidate.confidence, 0.9 * StructureClassifier.ambiguousCandidatePenalty))
        }
        #expect(proposal.reasons.contains(.faderStateVariesWithinRegion))
        #expect(proposal.reasons.contains(.ambiguousCandidates))
        #expect(classification.reasons.contains(.ambiguousCandidates))
        // An ambiguous proposal contributes no accepted reading.
        #expect(classification.acceptedStructures.contains(.hold) == false)
        #expect(classification.acceptedStructures.contains(.ghostHold) == false)
    }

    @Test("A fader that varies over travel names nothing rather than guessing Ghost")
    func mixedFaderOverTravel() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .forward), motion(1, 2, .stationary)],
            faderIntervals: [fader(0, 0.5, .closed), fader(0.5, 1, .open)]
        )
        let classification = StructureClassifier.classify(pattern)
        let proposal = try #require(classification.proposals.first { $0.scope == .motionSegment(index: 0) })
        #expect(proposal.isUnknown)
        #expect(proposal.candidates.isEmpty)
        #expect(proposal.reasons.contains(.faderStateVariesWithinRegion))
        #expect(classification.acceptedStructures.contains(.ghost) == false)
    }

    @Test("An unobserved fader is unknown and is never read as open")
    func unobservedFader() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)])
        let classification = StructureClassifier.classify(pattern)
        let everyProposalUnknown = classification.proposals.allSatisfy { $0.isUnknown }
        #expect(everyProposalUnknown)
        #expect(classification.proposals.isEmpty == false)
        #expect(classification.acceptedStructures.isEmpty)
        for proposal in classification.proposals {
            #expect(proposal.reasons.contains(.faderUnobserved))
            #expect(proposal.reasons.contains(.faderOpenThroughout) == false)
        }
        #expect(classification.counts.soundingRegionCount == 0)
    }

    @Test("Partial fader coverage keeps one reading but lowers its confidence")
    func partialFaderCoverage() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)],
                                     faderIntervals: [fader(0, 0.5, .closed)])
        let classification = StructureClassifier.classify(pattern)
        let proposal = try #require(classification.proposals.first { $0.scope == .motionSegment(index: 0) })
        let candidate = try soleCandidate(proposal)
        #expect(candidate.structure == .ghostHold)
        #expect(approximatelyEqual(candidate.confidence, 0.9 * StructureClassifier.partialFaderCoveragePenalty))
        #expect(proposal.reasons.contains(.partialFaderCoverage))
        #expect(proposal.reasons.contains(.faderClosedThroughout))
    }

    @Test("Confidence never exceeds the weakest canonical observation it rests on")
    func confidenceIsBoundedByEvidence() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .stationary, evidence: platterEvidence(confidence: 0.4)),
                             motion(1, 2, .forward)],
            faderIntervals: [fader(0, 2, .open, evidence: faderEvidence(confidence: 0.95))]
        )
        let classification = StructureClassifier.classify(pattern)
        let proposal = try #require(classification.proposals.first)
        let candidate = try soleCandidate(proposal)
        #expect(candidate.structure == .hold)
        #expect(approximatelyEqual(candidate.confidence, 0.4))
    }

    @Test("A hold count outside 1...3 is unknown, never rounded to a supported tear")
    func unsupportedHoldCount() throws {
        let classification = StructureClassifier.classify(tearShapePattern(holds: 4))
        let proposal = try #require(classification.proposals.first { $0.scope == .gesture(index: 0) })
        #expect(proposal.isUnknown)
        #expect(proposal.reasons.contains(.holdCountOutsideSupportedRange))
        #expect(classification.tearCandidateProposals.isEmpty)
        #expect(classification.acceptedStructures.contains(.tear3Candidate) == false)
        // The platter count itself is still reported truthfully.
        #expect(classification.counts.tearHoldCountsByGesture == [4])
    }

    @Test("A silent turnaround is two Ghosts, never a Baby")
    func closedFaderReversal() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(1, 2, .backward)],
                                     faderIntervals: [fader(0, 2, .closed)])
        let classification = StructureClassifier.classify(pattern)
        let reversal = try #require(classification.proposals.first {
            $0.scope == .reversal(fromGestureIndex: 0, toGestureIndex: 1)
        })
        #expect(reversal.isUnknown)
        #expect(reversal.reasons.contains(.faderClosedThroughout))
        #expect(classification.acceptedStructures == [.ghost, .ghost])
    }

    @Test("A reversal with unobserved fader proposes no Baby")
    func unobservedFaderReversal() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(1, 2, .backward)])
        let classification = StructureClassifier.classify(pattern)
        let reversal = try #require(classification.proposals.first {
            $0.scope == .reversal(fromGestureIndex: 0, toGestureIndex: 1)
        })
        #expect(reversal.isUnknown)
        #expect(reversal.reasons.contains(.faderUnobserved))
        #expect(classification.acceptedStructures.contains(.baby) == false)
    }

    @Test("A stationary interval between opposite directions is not a Baby turnaround")
    func pausedTurnaroundIsNotBaby() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .forward), motion(1, 2, .stationary), motion(2, 3, .backward)],
            faderIntervals: [fader(0, 3, .open)]
        )
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.contains { if case .reversal = $0.scope { return true } else { return false } } == false)
        #expect(classification.acceptedStructures == [.hold])
        #expect(classification.counts.tearHoldCountsByGesture == [0, 0])
    }

    @Test("Alternating gestures pair into whole cycles without sharing a gesture")
    func alternatingRunPairsGreedily() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .forward), motion(1, 2, .backward),
                             motion(2, 3, .forward), motion(3, 4, .backward)],
            faderIntervals: [fader(0, 4, .open)]
        )
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.acceptedStructures == [.baby, .baby])
        #expect(classification.proposals.map(\.scope) == [.reversal(fromGestureIndex: 0, toGestureIndex: 1),
                                                          .reversal(fromGestureIndex: 2, toGestureIndex: 3)])
    }
}

@Suite("Derived structure classification — adversarial evidence")
struct DerivedStructureAdversarialTests {

    private func clicks(at beats: [Double],
                        kind: ScratchNotationFaderClickKind = .cut) -> [ScratchNotation.FaderClick] {
        beats.map { .init(beat: $0, kind: kind, evidence: faderEvidence()) }
    }

    @Test("Fader clicks during a tear are cited but never counted as tear holds")
    func clicksDuringTear() throws {
        let clean = StructureClassifier.classify(tearShapePattern(holds: 2))
        let clicked = StructureClassifier.classify(
            tearShapePattern(holds: 2, clicks: clicks(at: [0.5, 1.5, 2.5, 3.5, 4.5]))
        )
        let cleanTear = try soleCandidate(try #require(clean.proposals.first { $0.scope == .gesture(index: 0) }))
        let clickedProposal = try #require(clicked.proposals.first { $0.scope == .gesture(index: 0) })
        let clickedTear = try soleCandidate(clickedProposal)

        // Five clicks did not become a fifth hold, a third tear, or any
        // change in confidence: the tear label is platter-only.
        #expect(clickedTear.structure == .tear2Candidate)
        #expect(clickedTear.structure == cleanTear.structure)
        #expect(approximatelyEqual(clickedTear.confidence, cleanTear.confidence))
        #expect(clicked.counts.tearHoldCountsByGesture == clean.counts.tearHoldCountsByGesture)
        #expect(clickedProposal.reasons.contains(.faderClicksPresentNotCounted))
        #expect(clickedProposal.reasons.contains(.tearCountIsPlatterOnly))
        #expect(clickedProposal.evidenceReferences.filter {
            if case .faderClick = $0 { return true } else { return false }
        }.count == 5)
    }

    @Test("Click count, sound count and tear count stay three independent numbers")
    func threeCountsNeverCollapse() throws {
        let counts = StructureClassifier.classify(
            tearShapePattern(holds: 2, clicks: clicks(at: [0.5, 1.5, 2.5, 3.5, 4.5]))
        ).counts
        #expect(counts.faderClickCount == 5)
        #expect(counts.soundingRegionCount == 3)
        #expect(counts.tearHoldCountsByGesture == [2])
        #expect(counts.totalTearHoldCount == 2)
        #expect(Set([counts.faderClickCount, counts.soundingRegionCount, counts.totalTearHoldCount]).count == 3)

        // The same independence on a Baby: many clicks, one sounding region,
        // no tear holds at all.
        let baby = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(1, 2, .backward)],
                                  faderIntervals: [fader(0, 2, .open)],
                                  faderClicks: clicks(at: [0.25, 0.75, 1.25], kind: .transformPulse))
        let babyCounts = StructureClassifier.classify(baby).counts
        #expect(babyCounts.faderClickCount == 3)
        #expect(babyCounts.soundingRegionCount == 1)
        #expect(babyCounts.tearHoldCountsByGesture == [0, 0])
    }

    @Test("Clicks alone can never mint a structure")
    func clicksAloneAssertNothing() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 4, .forward)],
                                     faderIntervals: [fader(0, 4, .open)],
                                     faderClicks: clicks(at: [0.5, 1, 1.5, 2, 2.5, 3, 3.5]))
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.isEmpty)
        #expect(classification.acceptedStructures.isEmpty)
        #expect(classification.counts.faderClickCount == 7)
        #expect(classification.counts.tearHoldCountsByGesture == [0])
        #expect(classification.counts.soundingRegionCount == 1)
    }

    @Test("Transform-style clicks never propose Chirp or Transformer")
    func transformClicksProposeNothingNew() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(1, 2, .backward)],
                                     faderIntervals: [fader(0, 2, .open)],
                                     faderClicks: clicks(at: [0.2, 0.4, 0.6, 0.8, 1.2, 1.4],
                                                         kind: .transformPulse))
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.acceptedStructures == [.baby])
        // Chirp/Transformer keep their untouched capture-side identity and
        // still have no canonical target notation of their own.
        #expect(CaptureSessionScratchType.chirp.title == "Chirp")
        #expect(CaptureSessionScratchType.transform.title == "Transform")
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "chirp") == nil)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "transform") == nil)
        #expect(ScratchNotation.canonicalBeatPatterns.map(\.scratchID) == ["baby_scratch"])
    }

    @Test("Free playback between same-direction travel is not a tear hold")
    func releasedBreaksTheGesture() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .forward), motion(1, 2, .released), motion(2, 3, .forward)],
            faderIntervals: [fader(0, 3, .open)]
        )
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.tearCandidateProposals.isEmpty)
        #expect(classification.proposals.isEmpty)
        #expect(classification.reasons.contains(.releasedMotionPresent))
        #expect(classification.counts.tearHoldCountsByGesture == [0, 0])
        #expect(classification.counts.soundingRegionCount == 2)
    }

    @Test("Unobserved motion between same-direction travel is not a tear hold")
    func unknownBreaksTheGesture() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .forward), motion(1, 2, .unknown), motion(2, 3, .forward)],
            faderIntervals: [fader(0, 3, .open)]
        )
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.tearCandidateProposals.isEmpty)
        #expect(classification.reasons.contains(.unknownMotionPresent))
        #expect(classification.counts.tearHoldCountsByGesture == [0, 0])
        #expect(classification.counts.soundingRegionCount == 2)
    }

    @Test("A pattern that fails its own validation is not classified at all")
    func invalidPatternIsNotClassified() throws {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), motion(2, 3, .backward)],
                                     faderIntervals: [fader(0, 3, .open)],
                                     faderClicks: clicks(at: [0.5, 1.5]))
        #expect(pattern.validationIssues().isEmpty == false)
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.isEmpty)
        #expect(classification.reasons == [.invalidPattern])
        #expect(classification.counts.soundingRegionCount == 0)
        #expect(classification.counts.tearHoldCountsByGesture.isEmpty)
        // The raw click count is still reported honestly rather than zeroed.
        #expect(classification.counts.faderClickCount == 2)
    }

    @Test("A manual motion correction changes the reading and keeps the derivation")
    func correctedMotionLabelDrivesTheReading() throws {
        let corrected = ScratchNotation.PlatterMotionSegment(
            span: .init(startBeat: 1, endBeat: 2),
            label: .init(derived: .forward, correction: .stationary),
            evidence: platterEvidence()
        )
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .forward), corrected, motion(2, 3, .forward)],
                                     faderIntervals: [fader(0, 3, .open)])
        let classification = StructureClassifier.classify(pattern)
        let gestureProposal = try #require(classification.proposals.first { $0.scope == .gesture(index: 0) })
        let tearCandidate = try soleCandidate(gestureProposal)
        #expect(tearCandidate.structure == .tear1Candidate)
        #expect(gestureProposal.reasons.contains(.correctedMotionLabel))
        #expect(classification.reasons.contains(.correctedMotionLabel))
        // The machine derivation survives the correction verbatim.
        #expect(pattern.motionSegments[1].label.derived == .forward)
        #expect(pattern.motionSegments[1].label.effective == .stationary)
        #expect(pattern.motionSegments[1].label.isCorrected)
    }
}

@Suite("Derived structure classification — invariants")
struct DerivedStructureInvariantTests {

    @Test("Classifying never mutates the canonical pattern or Baby Scratch")
    func classificationIsPure() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let pattern = tearShapePattern(holds: 2,
                                       clicks: [.init(beat: 1.5, kind: .cut, evidence: faderEvidence())])
        let patternBefore = try encoder.encode(pattern)
        let cycleBefore = try encoder.encode(ScratchNotation.babyScratchCycle)
        let babyPattern = try #require(ScratchNotation.babyScratchGesturePattern)
        let babyPatternBefore = try encoder.encode(babyPattern)
        _ = StructureClassifier.classify(pattern)
        _ = StructureClassifier.classify(babyPattern)
        let patternAfter = try encoder.encode(pattern)
        let cycleAfter = try encoder.encode(ScratchNotation.babyScratchCycle)
        let babyPatternAfter = try encoder.encode(try #require(ScratchNotation.babyScratchGesturePattern))
        #expect(patternAfter == patternBefore)
        #expect(cycleAfter == cycleBefore)
        #expect(babyPatternAfter == babyPatternBefore)
    }

    @Test("Classifying is deterministic and repeatable")
    func classificationIsDeterministic() throws {
        let pattern = tearShapePattern(holds: 3, clicks: [.init(beat: 2.5, kind: .flareClick,
                                                                evidence: faderEvidence())])
        #expect(StructureClassifier.classify(pattern) == StructureClassifier.classify(pattern))
    }

    @Test("Every evidence reference resolves to the untouched canonical observation")
    func referencesResolve() throws {
        let pattern = tearShapePattern(holds: 2,
                                       clicks: [.init(beat: 1.5, kind: .cut, evidence: faderEvidence())])
        let classification = StructureClassifier.classify(pattern)
        #expect(classification.proposals.isEmpty == false)
        for proposal in classification.proposals {
            #expect(proposal.evidenceReferences.isEmpty == false)
            for reference in proposal.evidenceReferences {
                switch reference {
                case .motionSegment(let index):
                    #expect(pattern.motionSegments.indices.contains(index))
                    #expect(pattern.motionSegments[index].evidence == platterEvidence())
                case .faderInterval(let index):
                    #expect(pattern.faderIntervals.indices.contains(index))
                    #expect(pattern.faderIntervals[index].evidence == faderEvidence())
                case .faderClick(let index):
                    #expect(pattern.faderClicks.indices.contains(index))
                    #expect(pattern.faderClicks[index].evidence == faderEvidence())
                }
            }
        }
    }

    @Test("Proposals are ordered by beat then by scope, and every one reads back")
    func proposalsAreOrderedAndReadable() throws {
        let classification = StructureClassifier.classify(tearShapePattern(holds: 2))
        let starts = classification.proposals.map(\.span.startBeat)
        #expect(starts == starts.sorted())
        for proposal in classification.proposals {
            #expect(proposal.narrative.isEmpty == false)
            #expect(proposal.reasons.isEmpty == false)
            for candidate in proposal.candidates {
                #expect(candidate.narrative.contains(candidate.structure.rawValue))
                #expect((0...1).contains(candidate.confidence))
            }
        }
        #expect(classification.narrative.count == classification.proposals.count)
    }

    @Test("A classification round-trips through Codable unchanged")
    func classificationRoundTrips() throws {
        let classification = StructureClassifier.classify(
            tearShapePattern(holds: 2, clicks: [.init(beat: 1.5, kind: .cut, evidence: faderEvidence())])
        )
        let data = try JSONEncoder().encode(classification)
        let decoded = try JSONDecoder().decode(StructureClassifier.Classification.self, from: data)
        #expect(decoded == classification)
    }
}

@Suite("Manual structure annotation authority")
struct DerivedStructureAnnotationTests {

    private func holdProposal() throws -> ScratchNotationStructureProposal {
        let pattern = gesturePattern(motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)],
                                     faderIntervals: [fader(0, 2, .open)])
        return try #require(StructureClassifier.classify(pattern).proposals.first)
    }

    private func manualEvidence(
        source: ScratchNotationEvidenceSource = .manualCorrection,
        provenance: ScratchNotationProvenance = .manuallyCorrected,
        reason: String = "reviewer_marked_ghost_hold"
    ) -> ScratchNotation.GestureRecord.Evidence {
        .init(provenance: provenance,
              observation: ScratchNotationEvidence(source: source, confidence: 1, reason: reason))
    }

    @Test("With no manual label the sole candidate is the effective reading")
    func unannotatedProposal() throws {
        let annotation = ScratchNotationStructureAnnotation(proposal: try holdProposal())
        #expect(annotation.effective == .hold)
        #expect(annotation.isManuallyLabelled == false)
        #expect(annotation.manualLabelDisagreesWithProposal == false)
        #expect(annotation.validationIssues().isEmpty)
    }

    @Test("An ambiguous proposal supplies no effective reading on its own")
    func ambiguousProposalHasNoEffectiveReading() throws {
        let pattern = gesturePattern(
            motionSegments: [motion(0, 1, .stationary), motion(1, 2, .forward)],
            faderIntervals: [fader(0, 0.5, .open), fader(0.5, 1, .closed)]
        )
        let proposal = try #require(StructureClassifier.classify(pattern).proposals.first)
        #expect(ScratchNotationStructureAnnotation(proposal: proposal).effective == nil)
        let annotated = ScratchNotationStructureAnnotation(proposal: proposal,
                                                          manualLabel: .ghostHold,
                                                          manualEvidence: manualEvidence())
        #expect(annotated.effective == .ghostHold)
        // The machine did offer ghostHold, so this is a choice, not a dispute.
        #expect(annotated.manualLabelDisagreesWithProposal == false)
        #expect(annotated.validationIssues().isEmpty)
    }

    @Test("A manual label wins while the machine proposal is retained verbatim")
    func manualLabelIsAuthoritative() throws {
        let proposal = try holdProposal()
        let annotation = ScratchNotationStructureAnnotation(proposal: proposal,
                                                            manualLabel: .ghost,
                                                            manualEvidence: manualEvidence())
        #expect(annotation.effective == .ghost)
        #expect(annotation.isManuallyLabelled)
        #expect(annotation.manualLabelDisagreesWithProposal)
        // Provenance on both sides survives the disagreement.
        #expect(annotation.proposal == proposal)
        #expect(annotation.proposal.soleCandidate?.structure == .hold)
        #expect(annotation.manualEvidence?.provenance == .manuallyCorrected)
        #expect(annotation.validationIssues().isEmpty)
        let decoded = try JSONDecoder().decode(ScratchNotationStructureAnnotation.self,
                                               from: JSONEncoder().encode(annotation))
        #expect(decoded == annotation)
    }

    @Test("A manual label without usable provenance is a validation issue")
    func manualLabelRequiresProvenance() throws {
        let proposal = try holdProposal()
        #expect(ScratchNotationStructureAnnotation(proposal: proposal, manualLabel: .ghost)
            .validationIssues().isEmpty == false)
        #expect(ScratchNotationStructureAnnotation(proposal: proposal, manualEvidence: manualEvidence())
            .validationIssues().isEmpty == false)
        #expect(ScratchNotationStructureAnnotation(
            proposal: proposal, manualLabel: .ghost,
            manualEvidence: manualEvidence(provenance: .inferred)
        ).validationIssues().isEmpty == false)
        #expect(ScratchNotationStructureAnnotation(
            proposal: proposal, manualLabel: .ghost,
            manualEvidence: manualEvidence(source: .audioOnset)
        ).validationIssues().isEmpty == false)
        #expect(ScratchNotationStructureAnnotation(
            proposal: proposal, manualLabel: .ghost,
            manualEvidence: manualEvidence(reason: "")
        ).validationIssues().isEmpty == false)
    }
}
