// Tests for ScratchPerformanceComparison — the performed-notation normalizer
// (capture evidence → beat coordinates) and the deterministic target-vs-
// performed alignment primitives.
//
// All fixtures are synthetic and deterministic. The canonical target side is
// either `ScratchNotation.babyScratchCycle` (production registry value) or a
// hand-built valid `BeatPattern` when a canonical fader channel is needed
// (babyScratchCycle deliberately authors none).

import Foundation
import Testing
@testable import ScratchLab

// MARK: - Shared fixtures

private let fixtureBPM = 100.0 // 1 beat = 600 ms, 0.1 beat = 60 ms

private func fixtureClock(beatZeroTime: Double = 0) -> PerformanceBeatClock {
    PerformanceBeatClock(bpm: fixtureBPM, beatZeroTime: beatZeroTime)!
}

private func fixtureWindows(
    strokeWindow: Double = 0.2,
    strokeTolerance: Double = 0.05,
    faderWindow: Double = 0.2,
    faderTolerance: Double = 0.05
) -> ScratchComparisonWindows {
    ScratchComparisonWindows(strokeMatchWindowBeats: strokeWindow,
                             strokeCorrectToleranceBeats: strokeTolerance,
                             faderMatchWindowBeats: faderWindow,
                             faderCorrectToleranceBeats: faderTolerance)!
}

private func performedStroke(
    start: Double,
    end: Double,
    direction: ScratchNotationDirection?,
    confidence: Double = 0.9,
    source: String = "timecode_live"
) -> PerformedScratchTimeline.Stroke {
    .init(startBeat: start, endBeat: end, direction: direction,
          confidence: confidence, source: source)
}

private func performedTimeline(
    strokes: [PerformedScratchTimeline.Stroke],
    faderEdges: [PerformedScratchTimeline.FaderEdge] = [],
    hasFaderCapture: Bool = false
) -> PerformedScratchTimeline {
    .init(strokes: strokes, faderEdges: faderEdges, hasFaderCapture: hasFaderCapture)
}

/// Performed strokes exactly matching `phrase`, optionally shifted globally.
private func perfectPerformance(
    of phrase: TargetScratchPhrase,
    shiftBeats: Double = 0
) -> [PerformedScratchTimeline.Stroke] {
    phrase.strokes.map { stroke in
        performedStroke(start: stroke.startBeat + shiftBeats,
                        end: stroke.endBeat + shiftBeats,
                        direction: stroke.direction)
    }
}

private func babyPhrase(cycles: Int = 1) -> TargetScratchPhrase {
    TargetScratchPhrase.phrase(repeating: ScratchNotation.babyScratchCycle,
                               cycles: cycles)!
}

/// A valid canonical-shaped pattern WITH an authored fader channel (first
/// edge at beat 0, strictly increasing, alternating states).
private let faderedPattern = ScratchNotation.BeatPattern(
    version: 1,
    scratchID: "test_fadered_pattern",
    timingBasis: "beat_canonical_cycle_v1",
    beatsPerBar: nil,
    strokes: [
        .init(startBeat: 0.0, endBeat: 0.5,
              direction: .forward, speedClassification: .medium, faderState: .open),
        .init(startBeat: 0.5, endBeat: 1.0,
              direction: .backward, speedClassification: .medium, faderState: .closed)
    ],
    faderEvents: [
        .init(beat: 0.0, state: .open),
        .init(beat: 0.5, state: .closed)
    ]
)

private func movementEvent(
    start: Double,
    end: Double,
    direction: String,
    kind: ScratchMovementKind = .normalPush,
    confidence: Double = 0.9,
    source: String = "timecode_live"
) -> CaptureCore.DetectedNotationRecordMovementEvent {
    .init(startTime: start, endTime: end, startPosition: 0, endPosition: 1,
          direction: direction, movementKind: kind, speed: 1,
          confidence: confidence, source: source)
}

private func midiSample(
    time: Double,
    value: Double,
    mappedControl: String? = "crossfader"
) -> CaptureCore.RawMixerMIDIEvent {
    .init(timestamp: time, takeRelativeTime: time, deviceName: "TestMixer",
          channel: 7, controller: 31, value: Int(value * 127),
          normalizedValue: value, mappedControl: mappedControl)
}

private let fixtureFaderThresholds = PerformedFaderEdgeThresholds(
    openAtOrAbove: 0.6, closedAtOrBelow: 0.4)!

// MARK: - Beat clock

@Suite("PerformanceBeatClock")
struct PerformanceBeatClockTests {

    @Test("Seconds↔beats round-trips against the anchor")
    func roundTrip() {
        let clock = fixtureClock(beatZeroTime: 1.2) // count-in of 2 beats at 100 BPM
        #expect(abs(clock.beats(fromSeconds: 1.2)) < 1e-12)
        #expect(abs(clock.beats(fromSeconds: 1.8) - 1.0) < 1e-12)
        #expect(abs(clock.seconds(fromBeats: 1.0) - 1.8) < 1e-12)
        #expect(abs(clock.milliseconds(fromBeats: 0.1) - 60.0) < 1e-9)
    }

    @Test("Unusable tempo or non-finite anchor refuses construction")
    func invalidConstruction() {
        #expect(PerformanceBeatClock(bpm: 0, beatZeroTime: 0) == nil)
        #expect(PerformanceBeatClock(bpm: -90, beatZeroTime: 0) == nil)
        #expect(PerformanceBeatClock(bpm: .nan, beatZeroTime: 0) == nil)
        #expect(PerformanceBeatClock(bpm: 100, beatZeroTime: .infinity) == nil)
    }
}

// MARK: - Windows validation

@Suite("ScratchComparisonWindows")
struct ScratchComparisonWindowsTests {

    @Test("Tolerance may not exceed its matching window")
    func toleranceBounds() {
        #expect(ScratchComparisonWindows(strokeMatchWindowBeats: 0.1,
                                         strokeCorrectToleranceBeats: 0.2,
                                         faderMatchWindowBeats: 0.1,
                                         faderCorrectToleranceBeats: 0.05) == nil)
        #expect(ScratchComparisonWindows(strokeMatchWindowBeats: 0.1,
                                         strokeCorrectToleranceBeats: 0.1,
                                         faderMatchWindowBeats: 0.1,
                                         faderCorrectToleranceBeats: 0.1) != nil)
        #expect(ScratchComparisonWindows(strokeMatchWindowBeats: -0.1,
                                         strokeCorrectToleranceBeats: -0.2,
                                         faderMatchWindowBeats: 0.1,
                                         faderCorrectToleranceBeats: 0.05) == nil)
    }
}

// MARK: - Adapter

@Suite("PerformedScratchTimelineAdapter")
struct PerformedScratchTimelineAdapterTests {

    @Test("Movement events normalize into beat coordinates through the anchor")
    func beatNormalization() {
        // 2-beat count-in at 100 BPM → beat 0 at 1.2 s take-relative.
        let clock = fixtureClock(beatZeroTime: 1.2)
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [
                movementEvent(start: 1.2, end: 1.5, direction: "forward"),
                movementEvent(start: 1.5, end: 1.8, direction: "backward", kind: .normalPull)
            ],
            mixerMidiEvents: [],
            clock: clock,
            faderThresholds: fixtureFaderThresholds
        )
        #expect(timeline.strokes.count == 2)
        #expect(abs(timeline.strokes[0].startBeat - 0.0) < 1e-9)
        #expect(abs(timeline.strokes[0].endBeat - 0.5) < 1e-9)
        #expect(timeline.strokes[0].direction == .forward)
        #expect(abs(timeline.strokes[1].startBeat - 0.5) < 1e-9)
        #expect(timeline.strokes[1].direction == .backward)
        #expect(timeline.hasFaderCapture == false)
    }

    @Test("Noisy event ordering yields the identical timeline")
    func noisyOrdering() {
        let clock = fixtureClock()
        let ordered = [
            movementEvent(start: 0.0, end: 0.3, direction: "forward"),
            movementEvent(start: 0.3, end: 0.6, direction: "backward", kind: .normalPull),
            movementEvent(start: 0.6, end: 0.9, direction: "forward")
        ]
        let shuffled = [ordered[2], ordered[0], ordered[1]]
        let midiOrdered = [
            midiSample(time: 0.0, value: 1.0),
            midiSample(time: 0.2, value: 0.0),
            midiSample(time: 0.4, value: 1.0)
        ]
        let midiShuffled = [midiOrdered[1], midiOrdered[2], midiOrdered[0]]
        let a = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: ordered, mixerMidiEvents: midiOrdered,
            clock: clock, faderThresholds: fixtureFaderThresholds)
        let b = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: shuffled, mixerMidiEvents: midiShuffled,
            clock: clock, faderThresholds: fixtureFaderThresholds)
        #expect(a == b)
    }

    @Test("Hold/release kinds and zero-duration events are not strokes")
    func nonStrokeEvents() {
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [
                movementEvent(start: 0.0, end: 0.3, direction: "forward"),
                movementEvent(start: 0.3, end: 0.6, direction: "forward", kind: .hold),
                movementEvent(start: 0.6, end: 0.9, direction: "forward",
                              kind: .releaseNormalPlayback),
                movementEvent(start: 0.9, end: 0.9, direction: "forward")
            ],
            mixerMidiEvents: [],
            clock: fixtureClock(),
            faderThresholds: fixtureFaderThresholds
        )
        #expect(timeline.strokes.count == 1)
    }

    @Test("Unknown direction strings are preserved as nil, never guessed")
    func unknownDirection() {
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [movementEvent(start: 0, end: 0.3, direction: "sideways")],
            mixerMidiEvents: [],
            clock: fixtureClock(),
            faderThresholds: fixtureFaderThresholds
        )
        #expect(timeline.strokes.count == 1)
        #expect(timeline.strokes[0].direction == nil)
    }

    @Test("Fader edges come from Schmitt threshold crossings of raw MIDI")
    func faderEdgeDerivation() {
        // open → jitter inside band (no edge) → closed → open
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [],
            mixerMidiEvents: [
                midiSample(time: 0.0, value: 0.9),  // establishes open, no edge
                midiSample(time: 0.1, value: 0.5),  // hysteresis band, held
                midiSample(time: 0.2, value: 0.55), // hysteresis band, held
                midiSample(time: 0.3, value: 0.1),  // → closed edge
                midiSample(time: 0.6, value: 0.9)   // → open edge
            ],
            clock: fixtureClock(),
            faderThresholds: fixtureFaderThresholds
        )
        #expect(timeline.hasFaderCapture)
        #expect(timeline.faderEdges.count == 2)
        #expect(timeline.faderEdges[0].state == .closed)
        #expect(abs(timeline.faderEdges[0].beat - 0.5) < 1e-9) // 0.3 s at 100 BPM
        #expect(timeline.faderEdges[1].state == .open)
        #expect(abs(timeline.faderEdges[1].beat - 1.0) < 1e-9)
    }

    @Test("Non-crossfader MIDI does not create fader evidence")
    func nonCrossfaderMIDI() {
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [],
            mixerMidiEvents: [
                midiSample(time: 0.0, value: 1.0, mappedControl: "line_fader"),
                midiSample(time: 0.2, value: 0.0, mappedControl: nil)
            ],
            clock: fixtureClock(),
            faderThresholds: fixtureFaderThresholds
        )
        #expect(timeline.hasFaderCapture == false)
        #expect(timeline.faderEdges.isEmpty)
    }

    @Test("Malformed hysteresis thresholds refuse construction")
    func thresholdValidation() {
        #expect(PerformedFaderEdgeThresholds(openAtOrAbove: 0.3, closedAtOrBelow: 0.7) == nil)
        #expect(PerformedFaderEdgeThresholds(openAtOrAbove: 1.2, closedAtOrBelow: 0.4) == nil)
        #expect(PerformedFaderEdgeThresholds(openAtOrAbove: 0.5, closedAtOrBelow: 0.5) != nil)
    }
}

// MARK: - Target phrase tiling

@Suite("TargetScratchPhrase")
struct TargetScratchPhraseTests {

    @Test("Tiling the canonical baby cycle produces contiguous repetitions")
    func babyTiling() {
        let phrase = babyPhrase(cycles: 4)
        #expect(phrase.strokes.count == 8)
        #expect(abs(phrase.strokes[2].startBeat - 1.0) < 1e-12)
        #expect(abs(phrase.strokes[7].endBeat - 4.0) < 1e-12)
        #expect(phrase.strokes[2].direction == .forward)
        #expect(phrase.strokes[3].direction == .backward)
        #expect(phrase.hasCanonicalFaderChannel == false)
        #expect(phrase.faderEdges.isEmpty)
    }

    @Test("Fader tiling drops the state-restating edge at cycle boundaries")
    func faderTiling() {
        let phrase = TargetScratchPhrase.phrase(repeating: faderedPattern, cycles: 2)!
        #expect(phrase.hasCanonicalFaderChannel)
        // Cycle 1: open@0, closed@0.5; cycle 2 restates open@1.0 → kept
        // (alternates), closed@1.5 kept. All four alternate, none dropped
        // here; verify alternation invariant held.
        #expect(phrase.faderEdges.count == 4)
        for i in 1..<phrase.faderEdges.count {
            #expect(phrase.faderEdges[i].state != phrase.faderEdges[i - 1].state)
            #expect(phrase.faderEdges[i].beat > phrase.faderEdges[i - 1].beat)
        }
    }

    @Test("Invalid patterns and cycle counts refuse tiling")
    func invalidTiling() {
        #expect(TargetScratchPhrase.phrase(repeating: ScratchNotation.babyScratchCycle,
                                           cycles: 0) == nil)
        let invalid = ScratchNotation.BeatPattern(
            version: 1, scratchID: "x", timingBasis: "seconds_v1",
            beatsPerBar: nil, strokes: [])
        #expect(TargetScratchPhrase.phrase(repeating: invalid, cycles: 1) == nil)
    }
}

// MARK: - Alignment: strokes

@Suite("ScratchPerformanceAlignment strokes")
struct ScratchPerformanceAlignmentStrokeTests {

    @Test("Perfect performance matches everything as correct")
    func perfect() {
        let phrase = babyPhrase(cycles: 2)
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: perfectPerformance(of: phrase)),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 4)
        #expect(result.missingTargetStrokeIndices.isEmpty)
        #expect(result.extraPerformedStrokeIndices.isEmpty)
        for match in result.matchedStrokes {
            #expect(match.timing == .correct)
            #expect(match.offsetBeats == 0)
            #expect(match.offsetMilliseconds == 0)
            #expect(match.directionCorrect == true)
        }
        #expect(result.faderChannel == .noCanonicalFaderChannel)
    }

    @Test("Globally late performance reports late verdicts with signed offsets")
    func globallyLate() {
        let phrase = babyPhrase()
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: perfectPerformance(of: phrase,
                                                                     shiftBeats: 0.1)),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 2)
        for match in result.matchedStrokes {
            #expect(match.timing == .late)
            #expect(abs(match.offsetBeats - 0.1) < 1e-12)
            #expect(abs(match.offsetMilliseconds - 60.0) < 1e-9) // 0.1 beat at 100 BPM
        }
    }

    @Test("Globally early performance reports early verdicts")
    func globallyEarly() {
        let phrase = babyPhrase()
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: perfectPerformance(of: phrase,
                                                                     shiftBeats: -0.1)),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        for match in result.matchedStrokes {
            #expect(match.timing == .early)
            #expect(abs(match.offsetBeats + 0.1) < 1e-12)
            #expect(abs(match.offsetMilliseconds + 60.0) < 1e-9)
        }
    }

    @Test("One missing stroke is reported by target index, not padded")
    func oneMissing() {
        let phrase = babyPhrase(cycles: 2)
        var strokes = perfectPerformance(of: phrase)
        strokes.remove(at: 2) // drop cycle 2's forward stroke
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 3)
        #expect(result.missingTargetStrokeIndices == [2])
        #expect(result.extraPerformedStrokeIndices.isEmpty)
    }

    @Test("One extra performed stroke is reported by performed index")
    func oneExtra() {
        let phrase = babyPhrase()
        var strokes = perfectPerformance(of: phrase)
        // An extra stroke far from any target start (window 0.2).
        strokes.append(performedStroke(start: 1.75, end: 1.9, direction: .forward))
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 2)
        #expect(result.missingTargetStrokeIndices.isEmpty)
        #expect(result.extraPerformedStrokeIndices == [2])
    }

    @Test("Wrong direction stays matched but flagged, orthogonal to timing")
    func wrongDirection() {
        let phrase = babyPhrase()
        var strokes = perfectPerformance(of: phrase)
        strokes[1] = performedStroke(start: strokes[1].startBeat,
                                     end: strokes[1].endBeat,
                                     direction: .forward) // target is backward
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 2)
        #expect(result.matchedStrokes[0].directionCorrect == true)
        #expect(result.matchedStrokes[1].directionCorrect == false)
        #expect(result.matchedStrokes[1].timing == .correct)
    }

    @Test("Unknown performed direction is unassessed, never wrong")
    func unknownDirectionUnassessed() {
        let phrase = babyPhrase()
        var strokes = perfectPerformance(of: phrase)
        strokes[0] = performedStroke(start: 0, end: 0.5, direction: nil)
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes[0].directionCorrect == nil)
    }

    @Test("Reversal boundary: a stroke lands on its nearest target, one-to-one")
    func reversalBoundary() {
        // Targets at 0.0 (fwd) and 0.5 (bwd). A performed stroke at 0.42 is
        // nearer the 0.5 reversal; window 0.2 also admits no claim by
        // target 0 once target 1 is considered — greedy runs in target
        // order, so target 0 must NOT steal it (distance 0.42 > window).
        let phrase = babyPhrase()
        let strokes = [performedStroke(start: 0.42, end: 0.9, direction: .backward)]
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 1)
        #expect(result.matchedStrokes[0].targetIndex == 1)
        #expect(result.matchedStrokes[0].performedIndex == 0)
        #expect(result.matchedStrokes[0].timing == .early)
        #expect(result.missingTargetStrokeIndices == [0])
    }

    @Test("Equidistant candidates break toward the earlier performed index")
    func deterministicTieBreak() {
        let phrase = babyPhrase()
        let strokes = [
            performedStroke(start: -0.1, end: 0.2, direction: .forward),
            performedStroke(start: 0.1, end: 0.4, direction: .forward)
        ]
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: strokes),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        // Target 0 at beat 0: both candidates are 0.1 away — earlier index wins.
        let first = result.matchedStrokes.first { $0.targetIndex == 0 }
        #expect(first?.performedIndex == 0)
    }

    @Test("Verdicts in beats are BPM-independent; milliseconds rescale")
    func bpmIndependence() {
        let phrase = babyPhrase()
        let performed = performedTimeline(
            strokes: perfectPerformance(of: phrase, shiftBeats: 0.1))
        let slow = ScratchPerformanceAlignment.compare(
            target: phrase, performed: performed,
            windows: fixtureWindows(), bpm: 60)!
        let fast = ScratchPerformanceAlignment.compare(
            target: phrase, performed: performed,
            windows: fixtureWindows(), bpm: 150)!
        #expect(slow.matchedStrokes.map(\.offsetBeats)
                == fast.matchedStrokes.map(\.offsetBeats))
        #expect(slow.matchedStrokes.map(\.timing)
                == fast.matchedStrokes.map(\.timing))
        #expect(abs(slow.matchedStrokes[0].offsetMilliseconds - 100.0) < 1e-9)
        #expect(abs(fast.matchedStrokes[0].offsetMilliseconds - 40.0) < 1e-9)
    }

    @Test("Unusable comparison tempo refuses to produce a result")
    func invalidBPM() {
        let phrase = babyPhrase()
        #expect(ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: []),
            windows: fixtureWindows(),
            bpm: 0) == nil)
    }
}

// MARK: - Alignment: fader channel

@Suite("ScratchPerformanceAlignment fader")
struct ScratchPerformanceAlignmentFaderTests {

    private func compare(
        performedEdges: [PerformedScratchTimeline.FaderEdge],
        hasFaderCapture: Bool = true,
        cycles: Int = 1
    ) -> ScratchPerformanceComparisonResult {
        let phrase = TargetScratchPhrase.phrase(repeating: faderedPattern,
                                                cycles: cycles)!
        return ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(strokes: perfectPerformance(of: phrase),
                                         faderEdges: performedEdges,
                                         hasFaderCapture: hasFaderCapture),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
    }

    @Test("No canonical fader channel is not comparable — even with performed edges")
    func noCanonicalChannel() {
        let phrase = babyPhrase()
        let result = ScratchPerformanceAlignment.compare(
            target: phrase,
            performed: performedTimeline(
                strokes: perfectPerformance(of: phrase),
                faderEdges: [.init(beat: 0.5, state: .closed, source: "midi")],
                hasFaderCapture: true),
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.faderChannel == .noCanonicalFaderChannel)
    }

    @Test("Canonical fader target without fader capture reports absent evidence")
    func noPerformedCapture() {
        let result = compare(performedEdges: [], hasFaderCapture: false)
        #expect(result.faderChannel == .noPerformedFaderCapture)
    }

    @Test("Exact performed edges all match as correct")
    func perfectFader() {
        let result = compare(performedEdges: [
            .init(beat: 0.0, state: .open, source: "midi"),
            .init(beat: 0.5, state: .closed, source: "midi")
        ])
        guard case .compared(let matched, let missing, let extra) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.count == 2)
        #expect(missing.isEmpty)
        #expect(extra.isEmpty)
        #expect(matched.allSatisfy { $0.timing == .correct })
    }

    @Test("Early and late fader edges carry signed offsets in beats and ms")
    func earlyLateFader() {
        let result = compare(performedEdges: [
            .init(beat: -0.1, state: .open, source: "midi"),
            .init(beat: 0.6, state: .closed, source: "midi")
        ])
        guard case .compared(let matched, _, _) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.count == 2)
        #expect(matched[0].timing == .early)
        #expect(abs(matched[0].offsetBeats + 0.1) < 1e-12)
        #expect(abs(matched[0].offsetMilliseconds + 60.0) < 1e-9)
        #expect(matched[1].timing == .late)
        #expect(abs(matched[1].offsetBeats - 0.1) < 1e-12)
    }

    @Test("A missing fader edge is reported by target index")
    func missingFader() {
        let result = compare(performedEdges: [
            .init(beat: 0.0, state: .open, source: "midi")
        ])
        guard case .compared(let matched, let missing, let extra) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.count == 1)
        #expect(missing == [1])
        #expect(extra.isEmpty)
    }

    @Test("An extra fader edge is reported by performed index")
    func extraFader() {
        let result = compare(performedEdges: [
            .init(beat: 0.0, state: .open, source: "midi"),
            .init(beat: 0.5, state: .closed, source: "midi"),
            .init(beat: 0.75, state: .open, source: "midi")
        ])
        guard case .compared(let matched, let missing, let extra) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.count == 2)
        #expect(missing.isEmpty)
        #expect(extra == [2])
    }

    @Test("Opposite-state edges never match: state mismatch = missing + extra")
    func stateMismatch() {
        let result = compare(performedEdges: [
            .init(beat: 0.0, state: .closed, source: "midi"),
            .init(beat: 0.5, state: .open, source: "midi")
        ])
        guard case .compared(let matched, let missing, let extra) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.isEmpty)
        #expect(missing == [0, 1])
        #expect(extra == [0, 1])
    }

    @Test("Repeated cycles align fader edges across every repetition")
    func repeatedCyclesFader() {
        let result = compare(performedEdges: [
            .init(beat: 0.0, state: .open, source: "midi"),
            .init(beat: 0.5, state: .closed, source: "midi"),
            .init(beat: 1.0, state: .open, source: "midi"),
            .init(beat: 1.54, state: .closed, source: "midi")
        ], cycles: 2)
        guard case .compared(let matched, let missing, let extra) = result.faderChannel else {
            Issue.record("expected .compared")
            return
        }
        #expect(matched.count == 4)
        #expect(missing.isEmpty)
        #expect(extra.isEmpty)
        #expect(matched[3].timing == .correct) // 0.04 within the 0.05 tolerance
        #expect(abs(matched[3].offsetBeats - 0.04) < 1e-9)
    }
}

// MARK: - End-to-end: capture evidence → comparison

@Suite("Capture evidence to comparison end-to-end")
struct ScratchPerformanceEndToEndTests {

    @Test("Synthetic capture take flows adapter → alignment deterministically")
    func endToEnd() {
        // 100 BPM, 2-beat count-in (beat 0 at 1.2 s). Two baby cycles,
        // second cycle's backward stroke 0.06 s (0.1 beat) late.
        let clock = fixtureClock(beatZeroTime: 1.2)
        let movements = [
            movementEvent(start: 1.20, end: 1.50, direction: "forward"),
            movementEvent(start: 1.50, end: 1.80, direction: "backward", kind: .normalPull),
            movementEvent(start: 1.80, end: 2.10, direction: "forward"),
            movementEvent(start: 2.16, end: 2.40, direction: "backward", kind: .normalPull)
        ]
        let performed = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: movements,
            mixerMidiEvents: [],
            clock: clock,
            faderThresholds: fixtureFaderThresholds
        )
        let result = ScratchPerformanceAlignment.compare(
            target: babyPhrase(cycles: 2),
            performed: performed,
            windows: fixtureWindows(),
            bpm: fixtureBPM
        )!
        #expect(result.matchedStrokes.count == 4)
        #expect(result.missingTargetStrokeIndices.isEmpty)
        #expect(result.extraPerformedStrokeIndices.isEmpty)
        #expect(result.matchedStrokes[0].timing == .correct)
        #expect(result.matchedStrokes[1].timing == .correct)
        #expect(result.matchedStrokes[2].timing == .correct)
        #expect(result.matchedStrokes[3].timing == .late)
        #expect(abs(result.matchedStrokes[3].offsetBeats - 0.1) < 1e-9)
        #expect(abs(result.matchedStrokes[3].offsetMilliseconds - 60.0) < 1e-6)
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
    }
}

// MARK: - Window derivation

@Suite("ScratchComparisonWindows derivation")
struct ScratchComparisonWindowsDerivationTests {

    @Test("Windows derive from the target's own beat spacing (half min gap)")
    func derivedFromBabyPhrase() throws {
        let target = babyPhrase(cycles: 2)
        let windows = try #require(ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: 0.08,
            faderCorrectToleranceBeats: 0.08))
        // Baby strokes start every 0.5 beat → window = 0.25 beats.
        #expect(abs(windows.strokeMatchWindowBeats - 0.25) < 1e-12)
        #expect(abs(windows.strokeCorrectToleranceBeats - 0.08) < 1e-12)
        // No fader-edge geometry (baby authors no channel) → stroke window reused.
        #expect(abs(windows.faderMatchWindowBeats - 0.25) < 1e-12)
    }

    @Test("Tolerance wider than the derived window is clamped, not a failure")
    func toleranceClamped() throws {
        let target = babyPhrase(cycles: 1)
        let windows = try #require(ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: 5.0,
            faderCorrectToleranceBeats: 5.0))
        #expect(windows.strokeCorrectToleranceBeats == windows.strokeMatchWindowBeats)
        #expect(windows.faderCorrectToleranceBeats == windows.faderMatchWindowBeats)
    }

    @Test("Fader-edge geometry tightens the fader window when authored")
    func faderedPatternDerivesFaderWindow() throws {
        let target = try #require(TargetScratchPhrase.phrase(repeating: faderedPattern, cycles: 2))
        let windows = try #require(ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: 0.05,
            faderCorrectToleranceBeats: 0.05))
        // Edges at 0, 0.5, (1.0 dropped as repeat), 1.5 → min gap 0.5 → 0.25.
        #expect(abs(windows.faderMatchWindowBeats - 0.25) < 1e-12)
    }

    @Test("A single-stroke phrase has no derivable spacing")
    func singleStrokeReturnsNil() throws {
        let single = ScratchNotation.BeatPattern(
            version: 1, scratchID: "test_single",
            timingBasis: "beat_canonical_cycle_v1", beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 1,
                            direction: .forward, speedClassification: .medium,
                            faderState: .open)])
        let target = try #require(TargetScratchPhrase.phrase(repeating: single, cycles: 1))
        #expect(ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: 0.05,
            faderCorrectToleranceBeats: 0.05) == nil)
    }
}

// MARK: - Target phrase materialization

@Suite("TargetScratchPhrase materialization")
struct TargetScratchPhraseMaterializationTests {

    @Test("A tiled phrase materializes through the canonical boundary")
    func tiledPhraseMaterializes() throws {
        let target = babyPhrase(cycles: 2)
        let notation = try #require(target.materializedNotation(
            bpm: 120,
            scratchID: ScratchNotation.babyScratchCycle.scratchID,
            timingBasis: ScratchNotation.babyScratchCycle.timingBasis,
            beatsPerBar: ScratchNotation.babyScratchCycle.beatsPerBar,
            version: ScratchNotation.babyScratchCycle.version))
        #expect(notation.strokes.count == 4)
        // 120 BPM → 0.5 s per beat; cycle 2's first stroke starts at beat 1.
        #expect(abs(notation.strokes[2].startTime - 0.5) < 1e-9)
        #expect(abs(notation.timelineDuration - 1.0) < 1e-9)
    }

    @Test("Materialization refuses an unusable tempo")
    func refusesBadTempo() {
        let target = babyPhrase(cycles: 1)
        #expect(target.materializedNotation(
            bpm: 0,
            scratchID: "x", timingBasis: "beat_canonical_cycle_v1",
            beatsPerBar: nil, version: 1) == nil)
    }
}

// MARK: - Presentation overlay

@Suite("ScratchComparisonOverlay")
struct ScratchComparisonOverlayTests {

    @Test("Matched, missing, and extra strokes project to seconds with verdicts")
    func overlayMarks() throws {
        let target = babyPhrase(cycles: 1) // fwd 0–0.5, back 0.5–1.0
        let clock = fixtureClock()
        // Performed: fwd matched 0.1 beat late; second slot unplayed; one
        // extra far-off stroke.
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.1, end: 0.6, direction: .forward),
            performedStroke(start: 3.0, end: 3.4, direction: .forward)
        ])
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let overlay = ScratchComparisonOverlay.overlay(
            result: result, target: target, performed: performed, clock: clock)

        #expect(overlay.strokeMarks.count == 3)
        // Sorted by start time: matched (0.1 beat), missing (0.5 beat), extra (3.0).
        let matched = overlay.strokeMarks[0]
        #expect(matched.kind == .matched(timing: .late, directionCorrect: true))
        #expect(abs(matched.startTime - clock.seconds(fromBeats: 0.1)) < 1e-9)
        #expect(abs((matched.offsetMilliseconds ?? 0) - 60.0) < 1e-6)
        #expect(matched.direction == .forward)

        let missing = overlay.strokeMarks[1]
        #expect(missing.kind == .missingTarget)
        #expect(abs(missing.startTime - clock.seconds(fromBeats: 0.5)) < 1e-9)
        #expect(missing.direction == .backward) // target direction, not invented
        #expect(missing.offsetMilliseconds == nil)

        let extra = overlay.strokeMarks[2]
        #expect(extra.kind == .extraPerformed)
        #expect(abs(extra.startTime - clock.seconds(fromBeats: 3.0)) < 1e-9)

        // Baby authors no fader channel — no fader marks are fabricated.
        #expect(overlay.faderMarks.isEmpty)
        #expect(result.faderChannel == .noCanonicalFaderChannel)
    }

    @Test("A compared fader channel yields verdict-carrying fader marks")
    func faderMarks() throws {
        let target = try #require(TargetScratchPhrase.phrase(repeating: faderedPattern, cycles: 1))
        let clock = fixtureClock()
        let performed = performedTimeline(
            strokes: perfectPerformance(of: target),
            faderEdges: [
                .init(beat: 0.0, state: .open, source: "midi"),
                .init(beat: 0.6, state: .closed, source: "midi") // 0.1 beat late
            ],
            hasFaderCapture: true)
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let overlay = ScratchComparisonOverlay.overlay(
            result: result, target: target, performed: performed, clock: clock)

        #expect(overlay.faderMarks.count == 2)
        #expect(overlay.faderMarks[0].kind == .matched(timing: .correct, directionCorrect: nil))
        #expect(overlay.faderMarks[1].kind == .matched(timing: .late, directionCorrect: nil))
        #expect(abs(overlay.faderMarks[1].time - clock.seconds(fromBeats: 0.6)) < 1e-9)
        #expect(overlay.faderMarks[1].state == .closed)
    }

    @Test("An indeterminate performed direction stays unassessed in the mark")
    func indeterminateDirection() throws {
        let target = babyPhrase(cycles: 1)
        let clock = fixtureClock()
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: nil)
        ])
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(),
            bpm: fixtureBPM))
        let overlay = ScratchComparisonOverlay.overlay(
            result: result, target: target, performed: performed, clock: clock)
        #expect(overlay.strokeMarks[0].kind
                == .matched(timing: .correct, directionCorrect: nil))
        #expect(overlay.strokeMarks[0].direction == nil)
    }
}

// MARK: - Scoring

@Suite("ScratchPerformanceScore")
struct ScratchPerformanceScoreTests {

    @Test("A perfect performance scores 100 on every comparable axis")
    func perfectScore() throws {
        let target = babyPhrase(cycles: 2)
        let performed = performedTimeline(strokes: perfectPerformance(of: target))
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let score = ScratchPerformanceScore.score(result: result, windows: windows)

        #expect(score.matchedStrokeCount == 4)
        #expect(score.missingStrokeCount == 0)
        #expect(score.extraStrokeCount == 0)
        #expect(score.wrongDirectionCount == 0)
        #expect(abs((score.platterTiming ?? 0) - 100) < 1e-9)
        #expect(abs((score.platterCompleteness ?? 0) - 100) < 1e-9)
        // Baby authors no fader channel — those axes are absent, not zero.
        #expect(score.faderTiming == nil)
        #expect(score.faderCompleteness == nil)
        #expect(abs((score.overall ?? 0) - 100) < 1e-9)
    }

    @Test("Timing quality normalizes offsets against the match window")
    func timingNormalization() throws {
        let target = babyPhrase(cycles: 1)
        let windows = fixtureWindows(strokeWindow: 0.2, strokeTolerance: 0.05)
        // Both strokes matched exactly half the window off → per-stroke 50.
        let performed = performedTimeline(
            strokes: perfectPerformance(of: target, shiftBeats: 0.1))
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let score = ScratchPerformanceScore.score(result: result, windows: windows)
        #expect(abs((score.platterTiming ?? 0) - 50) < 1e-9)
    }

    @Test("Missing, extra, and wrong-direction strokes each cost completeness")
    func completenessArithmetic() throws {
        let target = babyPhrase(cycles: 2) // 4 target strokes
        // Slot 0 matched correct-direction; slot 1 matched WRONG direction;
        // slots 2+3 unplayed; one extra stroke far away.
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .forward),
            performedStroke(start: 5.0, end: 5.4, direction: .forward)
        ])
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let score = ScratchPerformanceScore.score(result: result, windows: windows)

        #expect(score.matchedStrokeCount == 2)
        #expect(score.missingStrokeCount == 2)
        #expect(score.extraStrokeCount == 1)
        #expect(score.wrongDirectionCount == 1)
        #expect(score.assessedDirectionCount == 2)
        // (2 matched − 1 wrong-way) / (4 targets + 1 extra) = 20.
        #expect(abs((score.platterCompleteness ?? 0) - 20) < 1e-9)
    }

    @Test("No matched strokes means timing is unassessable, not zero")
    func noMatchesNilTiming() throws {
        let target = babyPhrase(cycles: 1)
        let performed = performedTimeline(strokes: [
            performedStroke(start: 9.0, end: 9.5, direction: .forward)
        ])
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let score = ScratchPerformanceScore.score(result: result, windows: windows)
        #expect(score.platterTiming == nil)
        #expect(abs((score.platterCompleteness ?? -1) - 0) < 1e-9)
        // Overall still reports from the axes that ARE comparable.
        #expect(score.overall != nil)
    }

    @Test("Fader sub-scores appear only when the channel was compared")
    func faderSubScores() throws {
        let target = try #require(TargetScratchPhrase.phrase(repeating: faderedPattern, cycles: 1))
        let performed = performedTimeline(
            strokes: perfectPerformance(of: target),
            faderEdges: [.init(beat: 0.0, state: .open, source: "midi")],
            hasFaderCapture: true)
        let windows = fixtureWindows()
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: fixtureBPM))
        let score = ScratchPerformanceScore.score(result: result, windows: windows)
        #expect(score.matchedFaderEdgeCount == 1)
        #expect(score.missingFaderEdgeCount == 1) // closed edge unplayed
        #expect(abs((score.faderTiming ?? 0) - 100) < 1e-9)
        #expect(abs((score.faderCompleteness ?? 0) - 50) < 1e-9)
    }
}
