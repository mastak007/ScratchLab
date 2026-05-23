import XCTest
@testable import ScratchLab

/// Phase 1 — locks the data contract for `PlatterPositionTimeline` and
/// `CrossfaderStateTimeline` before any producer or renderer consumes them.
/// No UI / snapshot tests in this slice (there is no renderer change to
/// snapshot).
final class PlatterPositionTimelineTests: XCTestCase {

    // MARK: - PlatterPositionTimeline: Codable

    /// Test #1 — Codable round-trip on a populated timeline.
    func testTimelineCodableRoundTrip() throws {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.5, position: 0.25, confidence: 0.9),
            PlatterPositionSample(time: 1.0, position: -0.10, confidence: 0.8),
        ]
        let original = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )
        XCTAssertNotNil(original, "constructor should accept valid input")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PlatterPositionTimeline.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - PlatterPositionTimeline: invariants

    /// Test #2 — initialiser rejects unsorted samples.
    func testTimelineRejectsUnsortedSamples() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.7, position: 0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.3, position: 0.2, confidence: 1.0), // out of order
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )
        XCTAssertNil(timeline)
    }

    /// Test #3 — initialiser rejects samples whose time falls outside
    /// `[startTime, endTime]`.
    func testTimelineRejectsSamplesOutsideRange() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.5, position: 0.25, confidence: 1.0),
            PlatterPositionSample(time: 1.5, position: -0.10, confidence: 1.0), // beyond endTime
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )
        XCTAssertNil(timeline)
    }

    /// Test #4 — initialiser rejects `endTime < startTime`.
    func testTimelineRejectsNegativeDuration() {
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 1.0,
            endTime: 0.0,
            samples: []
        )
        XCTAssertNil(timeline)
    }

    // MARK: - PlatterPositionTimeline: interpolation

    /// Test #5 — `position(at: samples[i].time)` returns
    /// `samples[i].position` exactly.
    func testInterpolationReturnsExactSampleAtSampleTimes() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.5, position: 0.25, confidence: 1.0),
            PlatterPositionSample(time: 1.0, position: -0.10, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        for sample in samples {
            XCTAssertEqual(timeline.position(at: sample.time), sample.position)
        }
    }

    /// Test #6 — midpoint between two samples returns the linear
    /// midpoint within `1e-9`.
    func testInterpolationMidpointIsLinear() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 1.0, confidence: 1.0),
            PlatterPositionSample(time: 1.0, position: 3.0, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        let actual = timeline.position(at: 0.5)
        XCTAssertNotNil(actual)
        XCTAssertEqual(actual!, 2.0, accuracy: 1e-9)
    }

    /// Test #7 — returns `nil` before `startTime` and after `endTime`.
    func testInterpolationOutsideRangeReturnsNil() {
        let samples = [
            PlatterPositionSample(time: 0.1, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.9, position: 1.0, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        XCTAssertNil(timeline.position(at: -0.1))
        XCTAssertNil(timeline.position(at: 1.1))
    }

    /// Test #8 — empty samples returns `nil` for any time.
    func testInterpolationEmptySamplesReturnsNil() {
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: []
        )!
        XCTAssertNil(timeline.position(at: 0.0))
        XCTAssertNil(timeline.position(at: 0.5))
        XCTAssertNil(timeline.position(at: 1.0))
    }

    // MARK: - PlatterPositionTimeline: positionRange

    /// Test #9 — populated returns `min…max` across samples.
    func testPositionRangePopulatedReturnsMinMax() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: -0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.3, position: 1.2, confidence: 1.0),
            PlatterPositionSample(time: 0.6, position: 0.4, confidence: 1.0),
            PlatterPositionSample(time: 1.0, position: -1.1, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        XCTAssertEqual(timeline.positionRange, -1.1...1.2)
    }

    /// Test #10 — empty returns `nil`.
    func testPositionRangeEmptyReturnsNil() {
        let timeline = PlatterPositionTimeline(
            source: .liveCapture,
            startTime: 0.0,
            endTime: 1.0,
            samples: []
        )!
        XCTAssertNil(timeline.positionRange)
    }

    // MARK: - CrossfaderStateTimeline

    /// Test #11 — builds contiguous open/closed segments from a synthetic
    /// fader-event array with no gaps, no overlaps.
    func testCrossfaderTimelineBuildsContiguousSegments() {
        let events: [CaptureCore.DetectedNotationFaderEvent] = [
            makeFaderEvent(kind: .open,   start: 0.0, end: 5.0,  toValue: 1.0),
            makeFaderEvent(kind: .closed, start: 5.0, end: 10.0, toValue: 0.0),
            makeFaderEvent(kind: .open,   start: 10.0, end: 15.0, toValue: 1.0),
        ]
        let timeline = CrossfaderStateTimeline(from: events, coverage: 0.0...15.0)
        XCTAssertEqual(timeline.segments.count, 3)
        XCTAssertEqual(timeline.segments[0].startTime, 0.0)
        XCTAssertEqual(timeline.segments[0].endTime, 5.0)
        XCTAssertEqual(timeline.segments[0].state, .open)
        XCTAssertEqual(timeline.segments[1].startTime, 5.0)
        XCTAssertEqual(timeline.segments[1].endTime, 10.0)
        XCTAssertEqual(timeline.segments[1].state, .closed)
        XCTAssertEqual(timeline.segments[2].startTime, 10.0)
        XCTAssertEqual(timeline.segments[2].endTime, 15.0)
        XCTAssertEqual(timeline.segments[2].state, .open)
    }

    /// Test #12 — returns the segment's state at any interior time.
    func testCrossfaderTimelineStateAtInteriorTime() {
        let events: [CaptureCore.DetectedNotationFaderEvent] = [
            makeFaderEvent(kind: .open,   start: 0.0, end: 5.0,  toValue: 1.0),
            makeFaderEvent(kind: .closed, start: 5.0, end: 10.0, toValue: 0.0),
        ]
        let timeline = CrossfaderStateTimeline(from: events, coverage: 0.0...10.0)
        XCTAssertEqual(timeline.state(at: 2.5), .open)
        XCTAssertEqual(timeline.state(at: 7.5), .closed)
    }

    /// Test #13 — returns `.closed` outside `coverage`.
    func testCrossfaderTimelineStateOutsideCoverageIsClosed() {
        let events: [CaptureCore.DetectedNotationFaderEvent] = [
            makeFaderEvent(kind: .open, start: 1.0, end: 2.0, toValue: 1.0),
        ]
        let timeline = CrossfaderStateTimeline(from: events, coverage: 1.0...2.0)
        XCTAssertEqual(timeline.state(at: 0.5), .closed)
        XCTAssertEqual(timeline.state(at: 2.5), .closed)
    }

    /// Test #14 — given a `.pulse` event with `fromValue = 0`,
    /// `toValue = 1`, returns `.transitioning(progress:)` linearly across
    /// the event span.
    func testCrossfaderTimelineTransitionLerpsLinearly() {
        let events: [CaptureCore.DetectedNotationFaderEvent] = [
            makeFaderEvent(kind: .pulse, start: 0.0, end: 1.0,
                           fromValue: 0.0, toValue: 1.0),
        ]
        let timeline = CrossfaderStateTimeline(from: events, coverage: 0.0...1.0)
        // At startTime, progress = 0 (segment start).
        XCTAssertEqual(timeline.state(at: 0.0), .transitioning(progress: 0.0))
        // At midpoint, progress = 0.5.
        XCTAssertEqual(timeline.state(at: 0.5), .transitioning(progress: 0.5))
        // At endTime, progress = 1.0 (segment end).
        XCTAssertEqual(timeline.state(at: 1.0), .transitioning(progress: 1.0))
    }

    /// Test #15 — empty events yields zero segments; state(at:) always
    /// returns `.closed`.
    func testCrossfaderTimelineEmptyEventsYieldsClosed() {
        let timeline = CrossfaderStateTimeline(from: [], coverage: 0.0...10.0)
        XCTAssertTrue(timeline.segments.isEmpty)
        XCTAssertEqual(timeline.state(at: 0.0), .closed)
        XCTAssertEqual(timeline.state(at: 5.0), .closed)
        XCTAssertEqual(timeline.state(at: 10.0), .closed)
    }

    // MARK: - Helpers

    private func makeFaderEvent(
        kind: ScratchFaderEventKind,
        start: Double,
        end: Double,
        fromValue: Double = 0.0,
        toValue: Double,
        control: String = "crossfader",
        source: String = "midi",
        confidence: Double = 1.0
    ) -> CaptureCore.DetectedNotationFaderEvent {
        CaptureCore.DetectedNotationFaderEvent(
            startTime: start,
            endTime: end,
            eventKind: kind,
            control: control,
            fromValue: fromValue,
            toValue: toValue,
            source: source,
            confidence: confidence
        )
    }
}
