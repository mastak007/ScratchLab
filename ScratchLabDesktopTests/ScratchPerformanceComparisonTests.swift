// Tests for ScratchPerformanceComparison — the performed-notation normalizer
// (capture evidence → beat coordinates) and the deterministic target-vs-
// performed alignment primitives.
//
// All fixtures are synthetic and deterministic. The canonical target side is
// either `ScratchNotation.babyScratchCycle` (production registry value) or a
// hand-built valid `BeatPattern` when a canonical fader channel is needed
// (babyScratchCycle deliberately authors none).

import Foundation
import CoreGraphics
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

// MARK: - Semantic error derivation

@Suite("SemanticError derivation")
struct SemanticErrorDerivationTests {

    @Test("Matched strokes early/late by the tolerance produce timing errors")
    func timingEarlyLate() throws {
        let target = babyPhrase(cycles: 1)
        let windows = fixtureWindows(strokeWindow: 0.2, strokeTolerance: 0.05)

        let early = performedTimeline(strokes: perfectPerformance(of: target, shiftBeats: -0.1))
        let earlyResult = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: early, windows: windows, bpm: fixtureBPM))
        let earlyErrors = SemanticError.derive(
            from: earlyResult, target: target, performed: early, clock: fixtureClock())
        #expect(earlyErrors.filter { $0.kind == .early }.count == 2)
        // beatPosition anchors to the target stroke's start beat.
        #expect(earlyErrors.filter { $0.kind == .early }.allSatisfy { $0.beatPosition != nil })

        let late = performedTimeline(strokes: perfectPerformance(of: target, shiftBeats: 0.1))
        let lateResult = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: late, windows: windows, bpm: fixtureBPM))
        let lateErrors = SemanticError.derive(
            from: lateResult, target: target, performed: late, clock: fixtureClock())
        #expect(lateErrors.filter { $0.kind == .late }.count == 2)
    }

    @Test("A matched stroke played the wrong way is a platter direction error")
    func wrongDirection() throws {
        let target = babyPhrase(cycles: 1)
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: .backward), // target[0] forward
            performedStroke(start: 0.5, end: 1.0, direction: .forward)   // target[1] backward
        ])
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        let errors = SemanticError.derive(
            from: result, target: target, performed: performed, clock: fixtureClock())
        #expect(errors.filter { $0.kind == .wrongDirection }.count == 2)
    }

    @Test("Unplayed target strokes are missed-movement errors at their target beat")
    func missedMovement() throws {
        let target = babyPhrase(cycles: 1)
        let performed = performedTimeline(strokes: [])
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        let errors = SemanticError.derive(
            from: result, target: target, performed: performed, clock: fixtureClock())
        #expect(errors.filter { $0.kind == .missedMovement }.count == 2)
        // Each missed error sits at its own target stroke's start beat.
        #expect(errors.filter { $0.kind == .missedMovement }
            .map(\.beatPosition).compactMap { $0 }.sorted() == [0.0, 0.5])
    }

    @Test("Performed strokes beyond the pattern are movement-too-long errors")
    func movementTooLong() throws {
        let target = babyPhrase(cycles: 1)
        let performed = performedTimeline(strokes: perfectPerformance(of: target) + [
            performedStroke(start: 2.0, end: 2.5, direction: .forward)
        ])
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        let errors = SemanticError.derive(
            from: result, target: target, performed: performed, clock: fixtureClock())
        #expect(errors.filter { $0.kind == .movementTooLong }.count == 1)
    }

    @Test("No fader errors are invented for a target with no canonical fader channel")
    func noFaderErrorsWithoutChannel() throws {
        let target = babyPhrase(cycles: 1) // babyScratchCycle authors no faderEvents
        let performed = performedTimeline(
            strokes: perfectPerformance(of: target), hasFaderCapture: true)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        let errors = SemanticError.derive(
            from: result, target: target, performed: performed, clock: fixtureClock())
        #expect(errors.allSatisfy { $0.family != .fader })
    }

    @Test("Early/late/missed/extra fader cuts map to the fader error kinds")
    func faderCutErrors() throws {
        let target = try #require(TargetScratchPhrase.phrase(repeating: faderedPattern, cycles: 1))
        // target fader edges: open@0.0, closed@0.5.

        // Late closed cut (0.6 vs 0.5 → +0.1 beats, outside ±0.05 tolerance).
        let lateCut = performedTimeline(
            strokes: perfectPerformance(of: target),
            faderEdges: [
                .init(beat: 0.0, state: .open, source: "midi"),
                .init(beat: 0.6, state: .closed, source: "midi")
            ],
            hasFaderCapture: true)
        let lateResult = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: lateCut, windows: fixtureWindows(), bpm: fixtureBPM))
        let lateErrors = SemanticError.derive(
            from: lateResult, target: target, performed: lateCut, clock: fixtureClock())
        #expect(lateErrors.contains { $0.kind == .lateCut })
        // beatPosition anchors to the target fader edge's beat (0.5).
        #expect(lateErrors.first { $0.kind == .lateCut }?.beatPosition == 0.5)

        // Missing closed cut → missedCut.
        let missedCut = performedTimeline(
            strokes: perfectPerformance(of: target),
            faderEdges: [.init(beat: 0.0, state: .open, source: "midi")],
            hasFaderCapture: true)
        let missedResult = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: missedCut, windows: fixtureWindows(), bpm: fixtureBPM))
        let missedErrors = SemanticError.derive(
            from: missedResult, target: target, performed: missedCut, clock: fixtureClock())
        #expect(missedErrors.contains { $0.kind == .missedCut })

        // Extra cut beyond the target → extraCut.
        let extraCut = performedTimeline(
            strokes: perfectPerformance(of: target),
            faderEdges: [
                .init(beat: 0.0, state: .open, source: "midi"),
                .init(beat: 0.5, state: .closed, source: "midi"),
                .init(beat: 1.0, state: .open, source: "midi")
            ],
            hasFaderCapture: true)
        let extraResult = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: extraCut, windows: fixtureWindows(), bpm: fixtureBPM))
        let extraErrors = SemanticError.derive(
            from: extraResult, target: target, performed: extraCut, clock: fixtureClock())
        #expect(extraErrors.contains { $0.kind == .extraCut })
    }

    @Test("Errors are priority-ordered timing → platter → fader")
    func priorityOrdering() throws {
        let target = babyPhrase(cycles: 1)
        // One early stroke (timing), one extra stroke (platter). Baby phrase
        // has no fader channel, so no fader errors.
        let performed = performedTimeline(strokes: [
            performedStroke(start: -0.1, end: 0.4, direction: .forward), // early match to target[0]
            performedStroke(start: 0.5, end: 1.0, direction: .backward),  // correct match to target[1]
            performedStroke(start: 2.0, end: 2.5, direction: .forward)   // extra
        ])
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        let errors = SemanticError.derive(
            from: result, target: target, performed: performed, clock: fixtureClock())
        let families = errors.map(\.family)
        // Stable: every timing error precedes every platter error.
        #expect(families == families.sorted { (lhs, rhs) in
            let rank: [SemanticError.Family: Int] = [.timing: 0, .platter: 1, .fader: 2]
            return rank[lhs]! < rank[rhs]!
        })
        #expect(!families.isEmpty)
    }

    @Test("Concise family and kind labels are stable and complete")
    func labels() {
        func err(_ family: SemanticError.Family, _ kind: SemanticError.Kind) -> SemanticError {
            SemanticError(family: family, kind: kind, beatPosition: nil,
                          magnitudeMilliseconds: nil, expected: "", performed: "")
        }
        #expect(err(.timing, .early).familyLabel == "TIMING")
        #expect(err(.platter, .missedMovement).familyLabel == "PLATTER")
        #expect(err(.fader, .extraCut).familyLabel == "FADER")
        #expect(err(.timing, .early).kindLabel == "Early")
        #expect(err(.timing, .late).kindLabel == "Late")
        #expect(err(.platter, .wrongDirection).kindLabel == "Wrong direction")
        #expect(err(.platter, .missedMovement).kindLabel == "Missed movement")
        #expect(err(.fader, .earlyCut).kindLabel == "Cut early")
        #expect(err(.fader, .missedCut).kindLabel == "Missed cut")
    }
}

// MARK: - Performed platter geometry (unified target/performed grammar)

@Suite("Performed platter geometry")
struct PerformedPlatterGeometryTests {

    private func performedEvent(
        start: Double, end: Double, direction: String,
        kind: ScratchMovementKind = .normalPush,
        startPos: Double = 0.0, endPos: Double = 1.0
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        .init(startTime: start, endTime: end, startPosition: startPos, endPosition: endPos,
              direction: direction, movementKind: kind, speed: 1,
              confidence: 0.9, source: "test")
    }

    private func path(_ events: [CaptureCore.DetectedNotationRecordMovementEvent],
                      duration: TimeInterval = 1.0,
                      normalizingTo frame: ClosedRange<CGFloat>? = nil) -> MotionPath {
        let strokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
        let content = LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil,
                                  duration: duration, loops: false)
        if let frame {
            return ScratchStrokeGeometry.motionPath(for: content, normalizingTo: frame)
        }
        return ScratchStrokeGeometry.motionPath(for: content)
    }

    private func strokeSegments(_ path: MotionPath) -> [MotionSegment] {
        path.segments.filter { if case .stroke = $0.kind { return true }; return false }
    }

    @Test("One forward stroke is one continuous increasing segment — no midpoint return")
    func forwardIsOneIncreasingSegment() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.1, endPos: 0.6)
        ])
        let segs = strokeSegments(p)
        #expect(segs.count == 1)                                  // no out/return halves
        #expect(segs[0].endPosition > segs[0].startPosition)      // continuously rising
        #expect(segs[0].startTime == 0.0)
        #expect(segs[0].endTime == 0.5)
    }

    @Test("One backward stroke is one continuous decreasing segment")
    func backwardIsOneDecreasingSegment() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "backward", kind: .normalPull,
                           startPos: 0.6, endPos: 0.1)
        ])
        let segs = strokeSegments(p)
        #expect(segs.count == 1)
        #expect(segs[0].endPosition < segs[0].startPosition)
    }

    @Test("An equal forward/backward pair returns to its starting position")
    func balancedPairReturnsToStart() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.0, endPos: 0.78),
            performedEvent(start: 0.5, end: 1.0, direction: "backward", kind: .normalPull,
                           startPos: 0.78, endPos: 0.0)
        ])
        #expect(abs(p.position(at: 1.0) - p.position(at: 0.0)) < 1e-9)
        #expect(p.position(at: 0.0) < p.position(at: 0.5))  // peak above the start
    }

    @Test("The reversal occurs exactly at the authored forward/backward boundary")
    func reversalAtAuthoredBoundary() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.0, endPos: 0.78),
            performedEvent(start: 0.5, end: 1.0, direction: "backward", kind: .normalPull,
                           startPos: 0.78, endPos: 0.0)
        ])
        // The peak (turnaround) is at the boundary, and only there.
        #expect(abs(p.position(at: 0.5) - 1.0) < 1e-9)
        #expect(p.position(at: 0.25) < p.position(at: 0.5))
        #expect(p.position(at: 0.75) < p.position(at: 0.5))
    }

    @Test("A gap holds the previous position rather than resetting to start")
    func gapHoldsPreviousPosition() {
        let p = path([
            performedEvent(start: 0.0, end: 0.3, direction: "forward",
                           startPos: 0.0, endPos: 0.5),
            performedEvent(start: 0.7, end: 1.0, direction: "backward", kind: .normalPull,
                           startPos: 0.5, endPos: 0.1)
        ])
        // Flat across the gap — the position is held, not dropped back to 0.
        #expect(abs(p.position(at: 0.5) - p.position(at: 0.3)) < 1e-9)
        #expect(abs(p.position(at: 0.7) - p.position(at: 0.3)) < 1e-9)
        #expect(p.position(at: 0.5) > 0.5)  // held high, not reset
    }

    @Test("An incomplete forward-only phrase stays at its measured endpoint")
    func incompleteForwardStaysAtEndpoint() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.1, endPos: 0.6)
        ], duration: 2.0)
        let end = p.position(at: 0.5)
        #expect(abs(p.position(at: 1.5) - end) < 1e-9)   // flat after the stroke
        #expect(abs(p.position(at: 2.0) - end) < 1e-9)
    }

    @Test("Performed rendering preserves captured start/end-position relationships")
    func preservesCapturedStartEndRelationships() {
        // Forward moves 0.0 → 0.6, backward returns only to 0.2 (short). The
        // backward stroke must begin where the forward ended and NOT be
        // re-authored back to zero — its measured 0.4 travel stays proportional.
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.0, endPos: 0.6),
            performedEvent(start: 0.5, end: 1.0, direction: "backward", kind: .normalPull,
                           startPos: 0.6, endPos: 0.2)
        ])
        let fwd = strokeSegments(p).first { if case .stroke(.forward) = $0.kind { return true }; return false }
        let back = strokeSegments(p).first { if case .stroke(.backward) = $0.kind { return true }; return false }
        #expect(fwd != nil && back != nil)

        // Continuity: the backward stroke begins where the forward ended.
        #expect(abs(back!.startPosition - fwd!.endPosition) < 1e-9)
        // Proportional travel: forward 0.6, backward 0.4 → 1.0 vs 0.666… of range.
        let fwdTravel = fwd!.endPosition - fwd!.startPosition
        let backTravel = fwd!.endPosition - back!.endPosition
        #expect(abs(fwdTravel - 1.0) < 1e-9)
        #expect(abs(backTravel - (0.4 / 0.6)) < 1e-6)
        // The short backward stroke did NOT fabricate a return to the start.
        #expect(back!.endPosition > 1e-6)
    }

    @Test("Target-frame normalization gives TARGET and MY PERFORMANCE the same mapping")
    func targetFrameNormalizationShared() throws {
        let target = try #require(ScratchNotation.babyScratchCycle.materialized(bpm: 79))
        let targetContent = LaneContent(notation: target)
        let targetFrame = ScratchStrokeGeometry.rawRange(for: targetContent)
        let targetPath = ScratchStrokeGeometry.motionPath(for: targetContent)
        let secondsPerBeat = 60.0 / 79.0

        // Performed mirrors the target's travel exactly (0 → 0.78 → 0).
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.0, endPos: 0.78),
            performedEvent(start: 0.5, end: 1.0, direction: "backward", kind: .normalPull,
                           startPos: 0.78, endPos: 0.0)
        ], normalizingTo: targetFrame)

        // Same raw frame → the start, turnaround and return land on the same Y.
        #expect(abs(p.position(at: 0.0) - targetPath.position(at: 0.0)) < 1e-6)
        #expect(abs(p.position(at: 0.5)
                    - targetPath.position(at: 0.5 * secondsPerBeat)) < 1e-6)
        #expect(abs(p.position(at: 1.0)
                    - targetPath.position(at: 1.0 * secondsPerBeat)) < 1e-6)
        #expect(abs(p.position(at: 0.5) - 1.0) < 1e-6)          // shared peak
        #expect(abs(p.position(at: 0.0) - 0.0) < 1e-6)          // shared start
    }

    @Test("An incomplete performed take stays incomplete — no fabricated stroke")
    func incompleteTakeStaysIncomplete() {
        let p = path([
            performedEvent(start: 0.0, end: 0.5, direction: "forward",
                           startPos: 0.0, endPos: 0.78)
        ], duration: 2.0)
        #expect(strokeSegments(p).count == 1)  // one stroke, no invented backward pair
    }

    @Test("Non-stroke and indeterminate-direction events are dropped, not fabricated")
    func nonStrokeAndIndeterminateDropped() {
        let hold = performedEvent(start: 0.0, end: 0.5, direction: "forward", kind: .hold)
        let indeterminate = performedEvent(start: 0.5, end: 1.0, direction: "sideways",
                                           kind: .normalPush)
        #expect(PerformedStrokeAdapter.laneStroke(from: hold) == nil)
        #expect(PerformedStrokeAdapter.laneStroke(from: indeterminate) == nil)
    }

    @Test("Performed content carries no invented fader spans")
    func performedContentHasNoInventedFader() {
        let events = [performedEvent(start: 0.0, end: 0.5, direction: "forward")]
        let strokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
        let content = LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil,
                                  duration: 1.0, loops: false)
        #expect(content.faderEvents.isEmpty)  // no fader trace invented
    }

    @Test("Absent crossfader capture yields no fader channel, never an invented open")
    func absentFaderCaptureIsHonest() {
        let timeline = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: [movementEvent(start: 0.0, end: 0.5, direction: "forward")],
            mixerMidiEvents: [],  // no crossfader evidence
            clock: fixtureClock(),
            faderThresholds: fixtureFaderThresholds)
        #expect(timeline.hasFaderCapture == false)
        #expect(timeline.faderEdges.isEmpty)
    }
}

// MARK: - Learner-facing fader summary

@Suite("Learner-facing fader summary")
struct LearnerFaderSummaryTests {

    @Test("Baby Scratch fader summary uses product language, not implementation terminology")
    func faderSummaryIsProductLanguage() {
        let summary = FaderChannelComparison.noCanonicalFaderChannel.learnerFaderSummary
        #expect(summary == "Open throughout · no cuts expected")
        #expect(!summary.contains("fader channel"))
        #expect(FaderChannelComparison.noPerformedFaderCapture.learnerFaderSummary == "Fader not captured")
    }
}

// MARK: - Alignment stage (boundary classification + phase selection)

@Suite("ScratchPerformanceAlignment boundaries")
struct ScratchAlignmentBoundaryTests {

    // MARK: Take 002 real fixture (controller, 90 BPM, 4-beat count-in).

    private let take002BPM = 90.0
    private let take002CountInBeats = 4.0

    private func take002Clock() -> PerformanceBeatClock {
        PerformanceBeatClock(bpm: take002BPM,
                             beatZeroTime: take002CountInBeats * 60.0 / take002BPM)!
    }

    /// (startSeconds, endSeconds, direction) transcribed verbatim from
    /// `take-002_detected_notation.json` `recordMovementEvents`.
    private let take002Events: [(Double, Double, ScratchNotationDirection)] = [
        (1.5146462499978952, 2.4363626666599885, .backward),
        (2.4363626666599885, 2.845634291676106, .forward),
        (2.845634291676106, 3.1519701666547917, .backward),
        (3.1519701666547917, 3.5014462916587945, .forward),
        (3.5014462916587945, 3.8063345833215863, .backward),
        (3.8063345833215863, 4.146148125000764, .forward),
        (4.146148125000764, 4.473817874997621, .backward),
        (4.473817874997621, 4.866465416678693, .forward),
        (4.866465416678693, 5.187679833325092, .backward),
        (5.187679833325092, 5.5746627083281055, .forward),
        (5.5746627083281055, 5.873708458326291, .backward),
        (5.873708458326291, 6.243476416653721, .forward),
        (6.243476416653721, 6.578827874996932, .backward),
        (6.578827874996932, 6.9608047916553915, .forward),
        (6.9608047916553915, 7.296657333325129, .backward),
        (7.296657333325129, 7.654348375013797, .forward),
        (7.654348375013797, 8.033418833336327, .backward),
        (8.033418833336327, 8.400547916680807, .forward),
        (8.400547916680807, 8.74373654165538, .backward),
        (8.74373654165538, 9.129666624998208, .forward),
        (9.129666624998208, 9.500838541658595, .backward),
        (9.500838541658595, 9.879409999994095, .forward),
        (9.879409999994095, 10.193485083320411, .backward),
        (10.193485083320411, 10.597464249993209, .forward),
        (10.597464249993209, 10.934087791654747, .backward),
        (10.934087791654747, 11.303995083348127, .forward),
        (11.303995083348127, 11.603331833321135, .backward),
        (11.603331833321135, 11.979828500014264, .forward),
        (11.979828500014264, 12.328220124996733, .backward),
        (12.328220124996733, 12.709310000005644, .forward),
        (12.709310000005644, 13.047487708332483, .backward),
        (13.047487708332483, 13.479020124999806, .forward),
        (13.479020124999806, 13.788163624994922, .backward),
        (13.788163624994922, 13.940816749993246, .forward),
    ]

    private func take002Timeline() -> PerformedScratchTimeline {
        let clock = take002Clock()
        let strokes = take002Events.map { start, end, direction in
            PerformedScratchTimeline.Stroke(
                startBeat: clock.beats(fromSeconds: start),
                endBeat: clock.beats(fromSeconds: end),
                direction: direction,
                confidence: 0.95,
                source: "controller")
        }
        return performedTimeline(strokes: strokes)
    }

    /// The production Review target for Take 002: 17 cycles (34 strokes),
    /// tiled from the raw evidence end beat.
    private func take002Target() -> TargetScratchPhrase {
        babyPhrase(cycles: 17)
    }

    @Test("Take 002: 34 movements, setup + 16 stable cycles + incomplete final")
    func take002Regression() throws {
        let target = take002Target()
        let performed = take002Timeline()
        let windows = try #require(ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: NotationFeedbackState.lateOffsetThresholdMs
                * take002BPM / 60_000.0,
            faderCorrectToleranceBeats: NotationFeedbackState.lateOffsetThresholdMs
                * take002BPM / 60_000.0))

        // Captured record is unchanged — 34 movements, alternating B/F.
        #expect(performed.strokes.count == 34)
        #expect(performed.strokes[0].direction == .backward)
        #expect(performed.strokes[1].direction == .forward)

        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices == [0])
        #expect(alignment.boundaryIncompletePerformedIndices == [33])
        #expect(alignment.scoredPerformedRange == 1..<33)   // 32 strokes / 16 cycles
        #expect(alignment.unscoredTargetStrokeIndices == [32, 33]) // over-tiled 17th cycle
        #expect(!alignment.explanation.isEmpty)

        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: take002BPM))
        #expect(result.matchedStrokes.count == 32)
        #expect(result.missingTargetStrokeIndices.isEmpty)
        #expect(result.extraPerformedStrokeIndices.isEmpty)
        #expect(result.boundarySetupPerformedStrokeIndices == [0])
        #expect(result.boundaryIncompletePerformedStrokeIndices == [33])
        #expect(result.unscoredTargetStrokeIndices == [32, 33])
        // The stable 32 strokes align as 16 forward/back cycles — no wrong-way.
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
        #expect(result.matchedStrokes.map(\.targetIndex) == Array(0..<32))
        // Direction sequence of the scored window is F/B alternating.
        #expect(result.matchedStrokes.map { target.strokes[$0.targetIndex].direction }
                == Array(repeating: [ScratchNotationDirection.forward,
                                     ScratchNotationDirection.backward], count: 16).flatMap { $0 })
    }

    @Test("Take 002: a one-stroke setup shift no longer inverts every direction")
    func take002NoWrongWayFromSetup() throws {
        let target = take002Target()
        let performed = take002Timeline()
        let windows = try #require(ScratchComparisonWindows.derived(
            from: target, strokeCorrectToleranceBeats: 0.08, faderCorrectToleranceBeats: 0.08))
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: windows, bpm: take002BPM))
        // No matched stroke is flagged wrong-way because of the leading setup.
        #expect(result.matchedStrokes.contains { $0.directionCorrect == false } == false)
        let score = ScratchPerformanceScore.score(result: result, windows: windows)
        #expect(score.wrongDirectionCount == 0)
    }

    // MARK: Edge cases.

    private func babyTarget(cycles: Int) -> TargetScratchPhrase { babyPhrase(cycles: cycles) }

    @Test("Clean phrase beginning forward has no boundary and no wrong-way")
    func cleanPhraseForwardNoSetup() throws {
        let target = babyTarget(cycles: 2)
        let performed = performedTimeline(strokes: perfectPerformance(of: target))
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices.isEmpty)
        #expect(alignment.boundaryIncompletePerformedIndices.isEmpty)
        #expect(alignment.scoredPerformedRange == 0..<4)
        #expect(alignment.unscoredTargetStrokeIndices.isEmpty)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.matchedStrokes.count == 4)
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
    }

    @Test("Valid phrase beginning exactly at recording start aligns to phase zero")
    func phraseAtRecordingStart() throws {
        let target = babyTarget(cycles: 1)
        // Start exactly at beat 0 (no count-in, no leading offset).
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices.isEmpty)
        #expect(alignment.scoredPerformedRange == 0..<2)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
        #expect(result.missingTargetStrokeIndices.isEmpty)
    }

    @Test("Backward setup followed by a clean forward/back phrase is trimmed as setup")
    func backwardSetupThenCleanPhrase() throws {
        let target = babyTarget(cycles: 2)
        // Leading backward setup is a strong duration outlier (2.0 beats vs 0.5).
        let performed = performedTimeline(strokes: [
            performedStroke(start: -2.0, end: 0.0, direction: .backward), // slow setup
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward),
            performedStroke(start: 1.0, end: 1.5, direction: .forward),
            performedStroke(start: 1.5, end: 2.0, direction: .backward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices == [0])
        #expect(alignment.scoredPerformedRange == 1..<5)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.matchedStrokes.count == 4)
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
        #expect(result.boundarySetupPerformedStrokeIndices == [0])
        #expect(result.extraPerformedStrokeIndices.isEmpty)
    }

    @Test("A genuine first-stroke wrong direction is not hidden as setup")
    func genuineFirstStrokeWrongDirection() throws {
        let target = babyTarget(cycles: 2)
        // All strokes equal duration — the leading backward is a real error,
        // not a slow setup, so it stays scored and inverts every stroke.
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: .backward),
            performedStroke(start: 0.5, end: 1.0, direction: .forward),
            performedStroke(start: 1.0, end: 1.5, direction: .backward),
            performedStroke(start: 1.5, end: 2.0, direction: .forward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices.isEmpty)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.matchedStrokes.count == 4)
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == false })
    }

    @Test("A genuine extra movement inside the phrase is reported as extra")
    func genuineExtraInsidePhrase() throws {
        let target = babyTarget(cycles: 1)
        var strokes = perfectPerformance(of: target) // F, B
        strokes.insert(performedStroke(start: 0.25, end: 0.75, direction: .forward), at: 1)
        let performed = performedTimeline(strokes: strokes)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(!result.extraPerformedStrokeIndices.isEmpty)
        #expect(result.boundarySetupPerformedStrokeIndices.isEmpty)
        #expect(result.boundaryIncompletePerformedStrokeIndices.isEmpty)
    }

    @Test("A genuine missed movement inside the phrase is reported as missing")
    func genuineMissedInsidePhrase() throws {
        let target = babyTarget(cycles: 2)
        var strokes = perfectPerformance(of: target) // 4 strokes
        strokes.remove(at: 2)
        let performed = performedTimeline(strokes: strokes)
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.missingTargetStrokeIndices == [2])
        #expect(result.boundarySetupPerformedStrokeIndices.isEmpty)
    }

    @Test("An incomplete first movement is classified as boundary incomplete")
    func incompleteFirstMovement() throws {
        let target = babyTarget(cycles: 2)
        // Leading truncated stroke (0.15 beats vs 0.5 median) then a clean phrase.
        let performed = performedTimeline(strokes: [
            performedStroke(start: -0.15, end: 0.0, direction: .backward),
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward),
            performedStroke(start: 1.0, end: 1.5, direction: .forward),
            performedStroke(start: 1.5, end: 2.0, direction: .backward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundaryIncompletePerformedIndices.contains(0))
        #expect(alignment.boundarySetupPerformedIndices.isEmpty)
    }

    @Test("An incomplete final movement is classified as boundary incomplete")
    func incompleteFinalMovement() throws {
        let target = babyTarget(cycles: 2)
        let performed = performedTimeline(strokes: [
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward),
            performedStroke(start: 1.0, end: 1.5, direction: .forward),
            performedStroke(start: 1.5, end: 2.0, direction: .backward),
            performedStroke(start: 2.0, end: 2.15, direction: .forward) // truncated
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundaryIncompletePerformedIndices == [4])
        #expect(alignment.scoredPerformedRange == 0..<4)
    }

    @Test("Tempo drift without phase shifting keeps directions aligned")
    func tempoDriftWithoutPhaseShift() throws {
        let target = babyTarget(cycles: 4) // 8 strokes, F/B alternating
        // Drift +0.0 … +0.7 beats across 8 strokes; directions still alternate.
        let performed = performedTimeline(strokes: (0..<8).map { i in
            let dir: ScratchNotationDirection = (i % 2 == 0) ? .forward : .backward
            let start = Double(i) * 0.5 + Double(i) * 0.09
            return performedStroke(start: start, end: start + 0.5, direction: dir)
        })
        let result = try #require(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: fixtureBPM))
        #expect(result.matchedStrokes.count == 8)
        #expect(result.matchedStrokes.allSatisfy { $0.directionCorrect == true })
        // Timing shifts early → late but never mis-pairs into wrong-way.
        #expect(result.matchedStrokes.first?.timing == .correct || result.matchedStrokes.first?.timing == .early)
        #expect(result.matchedStrokes.last?.timing == .late)
    }

    @Test("An equal-duration leading stroke is not removed merely because it is first")
    func equalDurationSetupNotRemoved() throws {
        let target = babyTarget(cycles: 2)
        // Leading backward has the SAME duration as the phrase strokes — no
        // duration evidence for setup, so it must remain a scored stroke.
        let performed = performedTimeline(strokes: [
            performedStroke(start: -0.5, end: 0.0, direction: .backward),
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward),
            performedStroke(start: 1.0, end: 1.5, direction: .forward),
            performedStroke(start: 1.5, end: 2.0, direction: .backward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices.isEmpty)
        #expect(alignment.boundaryIncompletePerformedIndices.isEmpty)
        // It is not silently dropped; it participates in scoring.
        #expect(alignment.scoredPerformedRange == 0..<5)
    }

    @Test("Alignment is BPM-independent and needs no beat grid")
    func bpmIndependentAndNoBeatGrid() throws {
        // align() reads only beat-domain durations and directions — it takes
        // no BPM and no clock, so the same beat-domain phrase classifies the
        // same regardless of the tempo that produced it.
        let target = babyTarget(cycles: 2)
        let performed = performedTimeline(strokes: [
            performedStroke(start: -2.0, end: 0.0, direction: .backward), // 2.0-beat setup
            performedStroke(start: 0.0, end: 0.5, direction: .forward),
            performedStroke(start: 0.5, end: 1.0, direction: .backward),
            performedStroke(start: 1.0, end: 1.5, direction: .forward),
            performedStroke(start: 1.5, end: 2.0, direction: .backward)
        ])
        let alignment = ScratchPerformanceAlignment.align(target: target, performed: performed)
        #expect(alignment.boundarySetupPerformedIndices == [0])
        // compare() with an unusable tempo refuses gracefully (the "no BPM" case).
        #expect(ScratchPerformanceAlignment.compare(
            target: target, performed: performed, windows: fixtureWindows(), bpm: 0) == nil)
    }

    @Test("Empty and one-event captures align without boundary classification")
    func emptyAndOneEvent() {
        let target = babyTarget(cycles: 2)
        let empty = ScratchPerformanceAlignment.align(target: target, performed: performedTimeline(strokes: []))
        #expect(empty.scoredPerformedRange.isEmpty)
        #expect(empty.boundarySetupPerformedIndices.isEmpty)

        let single = ScratchPerformanceAlignment.align(
            target: target,
            performed: performedTimeline(strokes: [
                performedStroke(start: 0.0, end: 0.5, direction: .forward)
            ]))
        #expect(single.boundarySetupPerformedIndices.isEmpty)
        #expect(single.boundaryIncompletePerformedIndices.isEmpty)
        #expect(single.scoredPerformedRange == 0..<1)
    }

    @Test("Alignment is source-neutral: camera vs controller produce the same classification")
    func sourceNeutral() {
        let target = babyTarget(cycles: 2)
        func timeline(source: String) -> PerformedScratchTimeline {
            performedTimeline(strokes: [
                PerformedScratchTimeline.Stroke(startBeat: -2.0, endBeat: 0.0, direction: .backward,
                                                confidence: 0.5, source: source),
                PerformedScratchTimeline.Stroke(startBeat: 0.0, endBeat: 0.5, direction: .forward,
                                                confidence: 0.5, source: source),
                PerformedScratchTimeline.Stroke(startBeat: 0.5, endBeat: 1.0, direction: .backward,
                                                confidence: 0.5, source: source),
                PerformedScratchTimeline.Stroke(startBeat: 1.0, endBeat: 1.5, direction: .forward,
                                                confidence: 0.5, source: source),
                PerformedScratchTimeline.Stroke(startBeat: 1.5, endBeat: 2.0, direction: .backward,
                                                confidence: 0.5, source: source)
            ])
        }
        let controller = ScratchPerformanceAlignment.align(target: target, performed: timeline(source: "controller"))
        let camera = ScratchPerformanceAlignment.align(target: target, performed: timeline(source: "video"))
        #expect(controller.boundarySetupPerformedIndices == [0])
        #expect(controller.boundarySetupPerformedIndices == camera.boundarySetupPerformedIndices)
        #expect(controller.scoredPerformedRange == camera.scoredPerformedRange)
    }
}
