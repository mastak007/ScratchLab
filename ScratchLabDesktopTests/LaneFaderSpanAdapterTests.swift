import XCTest
@testable import ScratchLab

/// Locks the adapter from canonical `ScratchNotation.FaderEvent` edges into
/// the renderer-neutral `LaneFaderSpan` stream `LaneContent.faderEvents`
/// consumes, plus the matching `CrossfaderStateTimeline(from: [LaneFaderSpan],
/// coverage:)` overload. See feature/notation-canonical-model-20260811.
final class LaneFaderSpanAdapterTests: XCTestCase {

    // MARK: - LaneFaderSpan.spans(from:documentEnd:)

    /// Empty canonical events yield no spans — no default state invented.
    func testEmptyCanonicalEventsYieldNoSpans() {
        let spans = LaneFaderSpan.spans(from: [], documentEnd: 10.0)
        XCTAssertTrue(spans.isEmpty)
    }

    /// Three edges become three contiguous spans; the last reaches
    /// `documentEnd` even though it extends past the final edge's own time.
    func testContiguousEdgesBecomeContiguousSpans() {
        let events: [ScratchNotation.FaderEvent] = [
            .init(time: 0.0, state: .open),
            .init(time: 0.5, state: .closed),
            .init(time: 0.7, state: .open),
        ]
        let spans = LaneFaderSpan.spans(from: events, documentEnd: 1.2)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].startTime, 0.0)
        XCTAssertEqual(spans[0].endTime, 0.5)
        XCTAssertEqual(spans[0].state, .open)
        XCTAssertEqual(spans[1].startTime, 0.5)
        XCTAssertEqual(spans[1].endTime, 0.7)
        XCTAssertEqual(spans[1].state, .closed)
        XCTAssertEqual(spans[2].startTime, 0.7)
        XCTAssertEqual(spans[2].endTime, 1.2)
        XCTAssertEqual(spans[2].state, .open)
    }

    /// A single edge at time 0 becomes one span covering the full duration.
    func testSingleEdgeCoversFullDuration() {
        let events: [ScratchNotation.FaderEvent] = [.init(time: 0.0, state: .closed)]
        let spans = LaneFaderSpan.spans(from: events, documentEnd: 4.0)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].startTime, 0.0)
        XCTAssertEqual(spans[0].endTime, 4.0)
        XCTAssertEqual(spans[0].state, .closed)
    }

    // MARK: - LaneContent(notation:) integration

    /// A notation with canonical faderEvents produces a matching
    /// `LaneContent.faderEvents` adapted stream.
    func testLaneContentAdaptsCanonicalFaderEvents() {
        let stroke = ScratchNotation.Stroke(
            startTime: 0.0, endTime: 1.0,
            direction: .forward, speedClassification: .medium,
            faderState: .open)
        let notation = ScratchNotation(
            version: 1, scratchID: "test.fader.adapter",
            demoStart: 0.0, demoEnd: 1.0,
            phraseStart: nil, phraseEnd: nil,
            timingBasis: "seconds_v1",
            strokes: [stroke],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.6, state: .closed),
            ])
        let content = LaneContent(notation: notation)
        XCTAssertEqual(content.faderEvents.count, 2)
        XCTAssertEqual(content.faderEvents[0].startTime, 0.0)
        XCTAssertEqual(content.faderEvents[0].endTime, 0.6)
        XCTAssertEqual(content.faderEvents[0].state, .open)
        XCTAssertEqual(content.faderEvents[1].startTime, 0.6)
        XCTAssertEqual(content.faderEvents[1].endTime, content.duration)
        XCTAssertEqual(content.faderEvents[1].state, .closed)
    }

    /// A notation with empty canonical faderEvents preserves existing
    /// behaviour exactly: `LaneContent.faderEvents` stays empty.
    func testLaneContentEmptyCanonicalFaderEventsStaysEmpty() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle())
        let content = LaneContent(notation: notation)
        XCTAssertTrue(content.faderEvents.isEmpty)
    }

    // MARK: - CrossfaderStateTimeline(from: [LaneFaderSpan], coverage:)

    func testCrossfaderTimelineFromLaneFaderSpansMapsStatesDirectly() {
        let spans: [LaneFaderSpan] = [
            LaneFaderSpan(startTime: 0.0, endTime: 5.0, state: .open),
            LaneFaderSpan(startTime: 5.0, endTime: 10.0, state: .closed),
        ]
        let timeline = CrossfaderStateTimeline(spans: spans, coverage: 0.0...10.0)
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.segments[0].state, .open)
        XCTAssertEqual(timeline.segments[1].state, .closed)
        XCTAssertEqual(timeline.state(at: 2.5), .open)
        XCTAssertEqual(timeline.state(at: 7.5), .closed)
        XCTAssertEqual(timeline.state(at: 10.0), .closed)
    }

    /// Empty spans behave identically to the empty `DetectedNotationFaderEvent`
    /// overload: zero segments, `state(at:)` always `.closed`.
    func testCrossfaderTimelineFromEmptyLaneFaderSpansYieldsClosed() {
        let timeline = CrossfaderStateTimeline(spans: [LaneFaderSpan](), coverage: 0.0...10.0)
        XCTAssertTrue(timeline.segments.isEmpty)
        XCTAssertEqual(timeline.state(at: 5.0), .closed)
    }

    // MARK: - ScratchNotation.faderAuthoritySpans(documentEnd:) / faderState(at:documentEnd:)
    //
    // The single authority resolver `ScratchNotationCanvasView`,
    // `ScratchPhraseChartView`, and `GuidedCutCueLayer` all read through:
    // non-empty canonical `faderEvents` wins outright; an empty canonical
    // stream falls back to one span per stroke, using that stroke's own
    // `faderState`.

    /// Empty canonical `faderEvents` falls back to one span per stroke,
    /// carrying that stroke's own `faderState` unchanged.
    func testFaderAuthoritySpansEmptyCanonicalFallsBackToPerStrokeFaderState() {
        let strokes = [
            ScratchNotation.Stroke(startTime: 0.0, endTime: 0.3,
                                    direction: .forward, speedClassification: .medium,
                                    faderState: .open),
            ScratchNotation.Stroke(startTime: 0.3, endTime: 0.6,
                                    direction: .backward, speedClassification: .medium,
                                    faderState: .closed),
        ]
        let notation = ScratchNotation(
            version: 1, scratchID: "test.fader.authority.fallback",
            demoStart: 0.0, demoEnd: 0.6, phraseStart: nil, phraseEnd: nil,
            timingBasis: "seconds_v1", strokes: strokes, faderEvents: [])

        let spans = notation.faderAuthoritySpans(documentEnd: 0.6)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].startTime, 0.0)
        XCTAssertEqual(spans[0].endTime, 0.3)
        XCTAssertEqual(spans[0].state, .open)
        XCTAssertEqual(spans[1].startTime, 0.3)
        XCTAssertEqual(spans[1].endTime, 0.6)
        XCTAssertEqual(spans[1].state, .closed)
    }

    /// A non-empty canonical stream wins outright, even against a stroke
    /// whose own `faderState` deliberately conflicts with it — the stroke
    /// snapshot cannot override authored `faderEvents`.
    func testNonEmptyCanonicalOverridesConflictingStrokeFaderState() {
        let stroke = ScratchNotation.Stroke(
            startTime: 0.0, endTime: 1.0,
            direction: .forward, speedClassification: .medium,
            faderState: .closed) // deliberately conflicts with the canonical .open below
        let notation = ScratchNotation(
            version: 1, scratchID: "test.fader.authority.conflict",
            demoStart: 0.0, demoEnd: 1.0, phraseStart: nil, phraseEnd: nil,
            timingBasis: "seconds_v1", strokes: [stroke],
            faderEvents: [.init(time: 0.0, state: .open)])

        XCTAssertEqual(notation.faderAuthoritySpans(documentEnd: 1.0).map(\.state), [.open])
        XCTAssertEqual(notation.faderState(at: 0.5, documentEnd: 1.0), .open)
    }

    /// `faderState(at:)` boundary table: open@0, closed@0.5, open@0.7 — an
    /// exact edge time resolves to the NEW state, not the state it's leaving.
    func testFaderStateAtBoundaryTable() {
        let notation = ScratchNotation(
            version: 1, scratchID: "test.fader.authority.boundary",
            demoStart: 0.0, demoEnd: 1.0, phraseStart: nil, phraseEnd: nil,
            timingBasis: "seconds_v1", strokes: [],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.5, state: .closed),
                .init(time: 0.7, state: .open),
            ])
        let documentEnd = 1.0

        XCTAssertEqual(notation.faderState(at: 0.3, documentEnd: documentEnd), .open)
        XCTAssertEqual(notation.faderState(at: 0.5, documentEnd: documentEnd), .closed)
        XCTAssertEqual(notation.faderState(at: 0.6, documentEnd: documentEnd), .closed)
        XCTAssertEqual(notation.faderState(at: 0.7, documentEnd: documentEnd), .open)
        XCTAssertEqual(notation.faderState(at: 0.9, documentEnd: documentEnd), .open)
    }

    /// A canonical edge coinciding exactly with a stroke boundary resolves
    /// to the canonical NEW state, even though both surrounding strokes'
    /// own `faderState` snapshots claim `.open`.
    func testCanonicalEventAtStrokeBoundaryResolvesToCanonicalNewState() {
        let strokeA = ScratchNotation.Stroke(
            startTime: 0.0, endTime: 0.5,
            direction: .forward, speedClassification: .medium, faderState: .open)
        let strokeB = ScratchNotation.Stroke(
            startTime: 0.5, endTime: 1.0,
            direction: .backward, speedClassification: .medium, faderState: .open)
        let notation = ScratchNotation(
            version: 1, scratchID: "test.fader.authority.boundary.stroke",
            demoStart: 0.0, demoEnd: 1.0, phraseStart: nil, phraseEnd: nil,
            timingBasis: "seconds_v1", strokes: [strokeA, strokeB],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.5, state: .closed),
            ])

        XCTAssertEqual(notation.faderState(at: 0.5, documentEnd: 1.0), .closed)
    }

    /// Baby Scratch (empty canonical `faderEvents`) retains its exact
    /// existing per-stroke fader behaviour through the authority resolver.
    func testBabyScratchLegacyNotationRetainsExistingFaderBehaviorViaAuthority() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle())
        XCTAssertTrue(notation.faderEvents.isEmpty)

        let spans = notation.faderAuthoritySpans(documentEnd: notation.timelineDuration)
        XCTAssertEqual(spans.count, notation.strokes.count)
        for (span, stroke) in zip(spans, notation.strokes) {
            XCTAssertEqual(span.startTime, stroke.startTime)
            XCTAssertEqual(span.endTime, stroke.endTime)
            XCTAssertEqual(span.state, stroke.faderState)
        }
    }
}
