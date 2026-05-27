import XCTest
@testable import ScratchLab

final class AudioPhraseGridProjectionTests: XCTestCase {

    private func grid(
        bpm: Double = 120,
        beatsPerBar: Int = 4,
        subdivisionsPerBeat: Int = 4,
        origin: TimeInterval = 0
    ) -> TimingGrid {
        guard let grid = TimingGrid(
            beatsPerMinute: bpm,
            beatsPerBar: beatsPerBar,
            subdivisionsPerBeat: subdivisionsPerBeat,
            origin: origin
        ) else {
            fatalError("invalid grid params for test")
        }
        return grid
    }

    private func span(
        start: Double,
        end: Double,
        firstEventIndex: Int = 0,
        lastEventIndex: Int = 0
    ) -> AudioPhraseSpan {
        AudioPhraseSpan(
            startTime: start,
            endTime: end,
            firstEventIndex: firstEventIndex,
            lastEventIndex: lastEventIndex,
            activeEventCount: 1,
            possibleDragCount: 0,
            scratchBurstCount: 1,
            possibleCutCount: 0,
            highConfidenceDragCount: 0,
            terminalDragDuration: nil
        )
    }

    private func summary(_ spans: [AudioPhraseSpan]) -> AudioPhraseSummary {
        AudioPhraseSummary(
            spans: spans,
            gapThresholdSeconds: AudioPhraseGrouper.defaultGapThresholdSeconds,
            highConfidenceThreshold: AudioPhraseGrouper.defaultHighConfidenceThreshold,
            releaseTailMinSeconds: AudioPhraseGrouper.defaultReleaseTailMinSeconds
        )
    }

    // 1. empty phrase summary projects to empty grid summary
    func test_emptyPhraseSummary_projectsToEmptyGridSummary() {
        let projection = AudioPhraseGridProjector.project(.empty, onto: grid())
        XCTAssertEqual(projection, .empty)
        XCTAssertTrue(projection.projections.isEmpty)
    }

    // 2. phrase starting at origin maps to bar 0 beat 0
    func test_phraseAtOrigin_mapsToBarZeroBeatZero() {
        let g = grid(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0)
        // secondsPerBar = 4.0 at 60 BPM, 4 beats/bar
        let s = span(start: 0.0, end: 1.0) // 1.0 s == 1 beat
        let projection = AudioPhraseGridProjector.project(summary([s]), onto: g)
        let first = projection.projections.first
        XCTAssertEqual(first?.startPosition.bar, 0)
        XCTAssertEqual(first?.startPosition.beat, 0)
        XCTAssertEqual(first?.startPosition.subdivision, 0)
        XCTAssertEqual(first?.startPosition.subdivisionPhase ?? .nan, 0.0, accuracy: 1e-9)
    }

    // 3. phrase ending one bar later maps to bar 1 beat 0
    func test_phraseOneBarLong_endsAtBarOneBeatZero() {
        let g = grid(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0)
        let s = span(start: 0.0, end: g.secondsPerBar)
        let projection = AudioPhraseGridProjector.project(summary([s]), onto: g)
        let first = projection.projections.first
        XCTAssertEqual(first?.endPosition.bar, 1)
        XCTAssertEqual(first?.endPosition.beat, 0)
        XCTAssertEqual(first?.endPosition.subdivision, 0)
        XCTAssertEqual(first?.endPosition.subdivisionPhase ?? .nan, 0.0, accuracy: 1e-9)
        XCTAssertEqual(first?.durationInBars ?? .nan, 1.0, accuracy: 1e-9)
    }

    // 4. non-zero origin shifts positions correctly
    func test_nonZeroOrigin_shiftsPositions() {
        let g = grid(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 10.0)
        // secondsPerBar = 4.0. Phrase at 10..14 should map to bars [0, 1].
        let s = span(start: 10.0, end: 14.0)
        let projection = AudioPhraseGridProjector.project(summary([s]), onto: g)
        let first = projection.projections.first
        XCTAssertEqual(first?.startPosition.bar, 0)
        XCTAssertEqual(first?.startPosition.beat, 0)
        XCTAssertEqual(first?.endPosition.bar, 1)
        XCTAssertEqual(first?.endPosition.beat, 0)
    }

    // 5. pre-origin phrase produces negative bar
    func test_preOriginPhrase_producesNegativeBar() {
        let g = grid(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 10.0)
        // secondsPerBar = 4.0; a startTime of 6.0 is one bar before origin.
        let s = span(start: 6.0, end: 11.0)
        let projection = AudioPhraseGridProjector.project(summary([s]), onto: g)
        let first = projection.projections.first
        XCTAssertNotNil(first)
        XCTAssertLessThan(first?.startPosition.bar ?? 0, 0,
                          "pre-origin start time must produce a negative bar index")
        XCTAssertEqual(first?.startPosition.bar, -1)
        XCTAssertEqual(first?.startPosition.beat, 0)
        XCTAssertEqual(first?.endPosition.bar, 0)
    }

    // 6. 95 BPM phrase produces expected durationInBars
    func test_ninetyFiveBPM_producesExpectedDurationInBars() {
        let g = grid(bpm: 95, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0)
        // secondsPerBar = 60 * 4 / 95 = 240/95
        let phraseDuration: Double = 5.0
        let s = span(start: 0.0, end: phraseDuration)
        let projection = AudioPhraseGridProjector.project(summary([s]), onto: g)
        let expected = phraseDuration * 95.0 / 240.0
        XCTAssertEqual(projection.projections.first?.durationInBars ?? .nan,
                       expected,
                       accuracy: 1e-12)
    }

    // 7. projection count matches phrase count
    func test_projectionCount_matchesPhraseCount() {
        let spans = (0..<7).map { i in
            span(start: Double(i) * 5.0, end: Double(i) * 5.0 + 1.0)
        }
        let projection = AudioPhraseGridProjector.project(summary(spans), onto: grid())
        XCTAssertEqual(projection.projections.count, spans.count)
    }

    // 8. phraseIndex is stable 0..<n
    func test_phraseIndex_isStableContiguousFromZero() {
        let spans = (0..<5).map { i in
            span(start: Double(i) * 3.0, end: Double(i) * 3.0 + 0.5)
        }
        let projection = AudioPhraseGridProjector.project(summary(spans), onto: grid())
        XCTAssertEqual(projection.projections.map(\.phraseIndex), Array(0..<5))
    }

    // 9. repeated projection deterministic
    func test_repeatedProjection_isDeterministic() {
        let spans = [
            span(start: 0.0, end: 1.0),
            span(start: 4.5, end: 8.25, firstEventIndex: 3, lastEventIndex: 4),
            span(start: 10.0, end: 12.5, firstEventIndex: 6, lastEventIndex: 9),
        ]
        let s = summary(spans)
        let g = grid(bpm: 117, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0.25)
        let first = AudioPhraseGridProjector.project(s, onto: g)
        let second = AudioPhraseGridProjector.project(s, onto: g)
        let third = AudioPhraseGridProjector.project(s, onto: g)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    // 10. Codable round-trip
    func test_codableRoundTrip_preservesProjection() throws {
        let spans = [
            span(start: 0.0, end: 1.5),
            span(start: 4.5, end: 7.0, firstEventIndex: 2, lastEventIndex: 3),
        ]
        let original = AudioPhraseGridProjector.project(summary(spans), onto: grid())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioPhraseGridSummary.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // 11. no technique/family/coaching/scoring fields exist
    func test_modelShape_hasNoTechniqueFamilyCoachingScoringFields() {
        let projection = AudioPhraseGridProjection(
            phraseIndex: 0,
            startPosition: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
            endPosition: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
            durationInBars: 0
        )
        let summary = AudioPhraseGridSummary(projections: [projection])

        let forbiddenSubstrings = ["technique", "family", "coaching", "score", "confidence"]
        let forbiddenExactNames: Set<String> = ["label", "kind"]

        let projectionLabels = Mirror(reflecting: projection)
            .children.compactMap { $0.label?.lowercased() }
        for label in projectionLabels {
            for token in forbiddenSubstrings {
                XCTAssertFalse(label.contains(token),
                               "AudioPhraseGridProjection field \"\(label)\" includes forbidden token \"\(token)\"")
            }
            XCTAssertFalse(forbiddenExactNames.contains(label),
                           "AudioPhraseGridProjection must not declare \"\(label)\"")
        }

        let summaryLabels = Mirror(reflecting: summary)
            .children.compactMap { $0.label?.lowercased() }
        for label in summaryLabels {
            for token in forbiddenSubstrings {
                XCTAssertFalse(label.contains(token),
                               "AudioPhraseGridSummary field \"\(label)\" includes forbidden token \"\(token)\"")
            }
            XCTAssertFalse(forbiddenExactNames.contains(label),
                           "AudioPhraseGridSummary must not declare \"\(label)\"")
        }
    }
}
