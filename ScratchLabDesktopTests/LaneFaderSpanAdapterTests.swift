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
}
