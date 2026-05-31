import XCTest
import CoreGraphics
@testable import ScratchLab

/// Scratch Playback Lab — sample-position timeline → notation geometry adapter.
///
/// Pure value-type coverage: no Core MIDI, no AVFoundation, no file I/O, no UI,
/// no PNG. The contract under test is the ABSOLUTE-TRAVEL one: a captured
/// `ScratchSampleTimeline` maps straight onto notation height with NO min/max
/// renormalisation, so partial travel stays partial, a reversal turns around at
/// its real sample position, monotonic time stays monotonic, muted spans keep
/// their timing, and empty / single-event captures are safe.
final class ScratchSampleTimelineNotationTests: XCTestCase {

    /// Builds a timeline from a position ramp (velocity = signed travel between
    /// samples), one sample per 10 ms.
    private func makeTimeline(positions: [Double],
                              step: TimeInterval = 0.01,
                              crossfader: [Double?]? = nil) -> ScratchSampleTimeline {
        var timeline = ScratchSampleTimeline()
        for (index, position) in positions.enumerated() {
            let previous = index > 0 ? positions[index - 1] : position
            timeline.append(timeSeconds: Double(index) * step,
                            position: position,
                            velocity: position - previous,
                            crossfader: crossfader?[index] ?? nil)
        }
        return timeline
    }

    /// Every position appearing in the path (segment endpoints).
    private func allPositions(_ notation: ScratchSampleTimelineNotation) -> [CGFloat] {
        notation.path.segments.flatMap { [$0.startPosition, $0.endPosition] }
    }

    // MARK: - Partial travel is not expanded to the full lane

    func testPartialTravelStaysMidLaneAndIsNotRenormalized() {
        // A nudge that only lives in 0.4...0.6 — must NOT stretch to 0...1.
        let timeline = makeTimeline(positions: [0.4, 0.5, 0.6, 0.5, 0.4])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)

        let positions = allPositions(notation)
        XCTAssertEqual(positions.min() ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(positions.max() ?? -1, 0.6, accuracy: 1e-9)
        // The defining check: the travel was NOT renormalised to fill the lane.
        XCTAssertGreaterThan(positions.min() ?? -1, 0.0)
        XCTAssertLessThan(positions.max() ?? 2, 1.0)
        // And the interpolated curve agrees at the peak time.
        XCTAssertEqual(notation.path.position(at: 0.02), 0.6, accuracy: 1e-9)
    }

    func testFullTravelMapsToFullHeight() {
        let timeline = makeTimeline(positions: [0.0, 0.25, 0.5, 0.75, 1.0])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)
        let positions = allPositions(notation)
        XCTAssertEqual(positions.min() ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(positions.max() ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: - Reversal turns around at the real sample position

    func testReversalKeepsItsExactSamplePosition() {
        // Push in to 0.55, then pull back out: the turn point is mid-sample.
        let timeline = makeTimeline(positions: [0.45, 0.55, 0.45])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)

        let segments = notation.path.segments
        XCTAssertEqual(segments.count, 2)
        // Incoming rises to 0.55, outgoing falls from 0.55 — the vertex sits at
        // the real turn position, not at the rail.
        XCTAssertEqual(segments[0].endPosition, 0.55, accuracy: 1e-9)
        XCTAssertEqual(segments[1].startPosition, 0.55, accuracy: 1e-9)
        XCTAssertLessThan(segments[0].endPosition, 1.0)
        // Direction flips forward → backward across the turn.
        XCTAssertEqual(segments[0].kind, .stroke(.forward))
        XCTAssertEqual(segments[1].kind, .stroke(.backward))
        // The curve reads 0.55 at the reversal time — absolute, not stretched.
        XCTAssertEqual(notation.path.position(at: 0.01), 0.55, accuracy: 1e-9)
    }

    func testHoldBetweenStrokesIsFlatNotAReversal() {
        // Forward, no-travel hold, forward again — the hold is a flat segment.
        let timeline = makeTimeline(positions: [0.2, 0.4, 0.4, 0.6])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)
        let kinds = notation.path.segments.map(\.kind)
        XCTAssertEqual(kinds, [.stroke(.forward), .hold, .stroke(.forward)])
    }

    // MARK: - Muted (crossfader-closed) spans keep their timing

    func testMutedSpanPreservesTimingWithoutDeletingTravel() {
        // Crossfader shut for the middle two samples; travel still captured.
        let crossfader: [Double?] = [0.70, 0.00, 0.00, 0.70]
        let timeline = makeTimeline(positions: [0.10, 0.20, 0.30, 0.40], crossfader: crossfader)
        let notation = ScratchSampleTimelineNotation(timeline: timeline)

        // One muted span covering the closed interval, timing intact.
        XCTAssertEqual(notation.mutedSpans.count, 1)
        XCTAssertEqual(notation.mutedSpans.first?.lowerBound ?? -1, 0.01, accuracy: 1e-9)
        XCTAssertEqual(notation.mutedSpans.first?.upperBound ?? -1, 0.02, accuracy: 1e-9)
        // Travel across the muted span is NOT deleted — the geometry is whole.
        XCTAssertEqual(notation.path.segments.count, 3)
        let positions = allPositions(notation)
        XCTAssertEqual(positions.min() ?? -1, 0.10, accuracy: 1e-9)
        XCTAssertEqual(positions.max() ?? -1, 0.40, accuracy: 1e-9)
    }

    func testNoCrossfaderMeansNoMutedSpans() {
        let timeline = makeTimeline(positions: [0.1, 0.3, 0.5])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)
        XCTAssertTrue(notation.mutedSpans.isEmpty)
    }

    // MARK: - Monotonic time in → monotonic path out

    func testMonotonicEventTimesProduceMonotonicSegmentTimes() {
        let timeline = makeTimeline(positions: [0.0, 0.2, 0.5, 0.3, 0.1, 0.4])
        let notation = ScratchSampleTimelineNotation(timeline: timeline)
        let segments = notation.path.segments
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.endTime, segment.startTime)
        }
        for index in 1..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[index].startTime, segments[index - 1].startTime)
            // Adjacent segments meet — the previous end is the next start.
            XCTAssertEqual(segments[index].startTime, segments[index - 1].endTime, accuracy: 1e-12)
        }
    }

    // MARK: - Empty / single-event safety

    func testEmptyTimelineProducesEmptySafeOutput() {
        let notation = ScratchSampleTimelineNotation(timeline: ScratchSampleTimeline())
        XCTAssertTrue(notation.isEmpty)
        XCTAssertTrue(notation.path.segments.isEmpty)
        XCTAssertTrue(notation.mutedSpans.isEmpty)
        // The renderer's position lookup still has a safe default.
        XCTAssertEqual(notation.path.position(at: 0), 0.5, accuracy: 1e-9)
    }

    func testSingleEventProducesSafeFlatHold() {
        var timeline = ScratchSampleTimeline()
        timeline.append(timeSeconds: 1.5, position: 0.3, velocity: 0.0)
        let notation = ScratchSampleTimelineNotation(timeline: timeline)

        XCTAssertFalse(notation.isEmpty)
        XCTAssertEqual(notation.path.segments.count, 1)
        XCTAssertEqual(notation.path.segments.first?.kind, .hold)
        // Held flat at the captured position — no invented travel.
        XCTAssertEqual(notation.path.position(at: 0.0), 0.3, accuracy: 1e-9)
        XCTAssertEqual(notation.path.position(at: 99.0), 0.3, accuracy: 1e-9)
        XCTAssertTrue(notation.mutedSpans.isEmpty)
    }
}

/// Captured notation PNG export (Slice 8). Renders the same notation as the live preview
/// to PNG, guards the empty case, and proves the raw timeline JSON export is untouched.
@MainActor
final class CapturedNotationPNGExportTests: XCTestCase {

    private func travelTimeline() -> ScratchSampleTimeline {
        var timeline = ScratchSampleTimeline()
        // A small forward-then-reverse stroke so the path has real travel to draw.
        let samples: [(TimeInterval, Double, Double)] = [
            (0.0, 0.10, 1.0), (0.1, 0.30, 1.0), (0.2, 0.55, 1.0),
            (0.3, 0.70, 1.0), (0.4, 0.50, -1.0), (0.5, 0.25, -1.0)
        ]
        for (t, position, velocity) in samples {
            timeline.append(timeSeconds: t, position: position, velocity: velocity)
        }
        return timeline
    }

    func testPNGExportProducesNonEmptyImage() {
        let notation = ScratchSampleTimelineNotation(timeline: travelTimeline())
        let data = CapturedNotationImage.pngData(
            notation: notation, renderConfig: PlaybackLabRenderConfig(),
            size: CGSize(width: 600, height: 200)
        )
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
        // PNG signature: 0x89 'P' 'N' 'G'.
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testEmptyTimelineIsGuarded() {
        let empty = ScratchSampleTimelineNotation(timeline: ScratchSampleTimeline())
        XCTAssertNil(CapturedNotationImage.pngData(
            notation: empty, renderConfig: PlaybackLabRenderConfig(),
            size: CGSize(width: 600, height: 200)
        ))
    }

    func testRawTimelineJSONUnaffectedByPNGExport() throws {
        let timeline = travelTimeline()
        let before = try ScratchSampleTimelineExport(timeline: timeline).jsonData()

        // Render a PNG from the same timeline's notation.
        let notation = ScratchSampleTimelineNotation(timeline: timeline)
        _ = CapturedNotationImage.pngData(
            notation: notation, renderConfig: PlaybackLabRenderConfig(),
            size: CGSize(width: 600, height: 200)
        )

        let after = try ScratchSampleTimelineExport(timeline: timeline).jsonData()
        XCTAssertEqual(before, after, "PNG export must not mutate the captured timeline / its JSON")
    }
}
