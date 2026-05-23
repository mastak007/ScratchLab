import XCTest
import SwiftUI
@testable import ScratchLab

/// Phase 2 — locks the rendering selector and back-compat invariants for the
/// raw integrated trace + crossfader ribbon additions to `LaneContent`,
/// `ScratchMotionRenderer`, and `ScratchMotionLane`.
///
/// **Tests assert structural / predicate behaviour, not pixels.** SwiftUI
/// `GraphicsContext` is opaque to XCTest; a true snapshot test would require
/// an image-comparison library not present in this project. The structural
/// smoke tests for the renderer entry points exercise the call paths and
/// assert non-crash + no-throw — pixel parity for the no-timeline fallback is
/// guaranteed by the implementation routing through the same
/// `ScratchMotionRenderer.draw(...)` call as pre-Phase-2.
@MainActor
final class LaneRawTraceFallbackTests: XCTestCase {

    // MARK: - Back-compat: LaneContent default channels are nil/empty

    /// Test #1 — `LaneContent(notation:)` yields no raw timeline and no
    /// fader events. Locks the classified-stroke fallback for every
    /// existing scored-mode call site.
    func testNotationLaneContentHasNoPhase2Channels() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle())
        let content = LaneContent(notation: notation)
        XCTAssertNil(content.platterTimeline)
        XCTAssertTrue(content.faderEvents.isEmpty)
        XCTAssertFalse(content.shouldRenderRawTrace())
    }

    /// Test #2 — `LaneContent(reel:)` yields no raw timeline and no fader
    /// events. Locks the Demo path's pre-Phase-2 behaviour.
    func testReelLaneContentHasNoPhase2Channels() throws {
        let reel = try XCTUnwrap(PracticeReelTimeline.loadBundled(named: "baby_reel"))
        let content = LaneContent(reel: reel)
        XCTAssertNil(content.platterTimeline)
        XCTAssertTrue(content.faderEvents.isEmpty)
        XCTAssertFalse(content.shouldRenderRawTrace())
    }

    // MARK: - Selector predicate

    /// Test #3 — selector returns `false` when `platterTimeline == nil`,
    /// regardless of other content.
    func testSelectorFalseWhenNoTimeline() {
        let content = LaneContent(
            strokes: [],
            segments: [],
            beatsPerMinute: nil,
            duration: 5.0,
            loops: false
        )
        XCTAssertFalse(content.shouldRenderRawTrace())
    }

    /// Test #4 — selector returns `true` when timeline meets density AND
    /// coverage thresholds (≥ 10 samples/sec over ≥ 80% of duration).
    func testSelectorTrueWhenDenseAndCovers80Percent() {
        let duration: TimeInterval = 1.0
        let timeline = makeTimeline(start: 0.0, end: 1.0, sampleCount: 50)
        let content = LaneContent(
            strokes: [],
            segments: [],
            beatsPerMinute: nil,
            duration: duration,
            loops: false,
            platterTimeline: timeline
        )
        XCTAssertTrue(content.shouldRenderRawTrace())
    }

    /// Test #5 — selector returns `false` when sample density is below the
    /// floor (default 10 samples/sec).
    func testSelectorFalseWhenSparse() {
        let duration: TimeInterval = 1.0
        // 5 samples over 1.0 s = 5 samples/sec — below the 10/sec default.
        let timeline = makeTimeline(start: 0.0, end: 1.0, sampleCount: 5)
        let content = LaneContent(
            strokes: [],
            segments: [],
            beatsPerMinute: nil,
            duration: duration,
            loops: false,
            platterTimeline: timeline
        )
        XCTAssertFalse(content.shouldRenderRawTrace())
    }

    /// Test #6 — selector returns `false` when the timeline covers less
    /// than 80% of the content's duration.
    func testSelectorFalseWhenCoverageBelow80Percent() {
        let duration: TimeInterval = 10.0
        // Dense timeline (50 samples / 1 s = 50/sec) but covers only
        // 1.0 s of a 10.0 s content (10% coverage — below 80%).
        let timeline = makeTimeline(start: 0.0, end: 1.0, sampleCount: 50)
        let content = LaneContent(
            strokes: [],
            segments: [],
            beatsPerMinute: nil,
            duration: duration,
            loops: false,
            platterTimeline: timeline
        )
        XCTAssertFalse(content.shouldRenderRawTrace())
    }

    /// Test #7 — selector tunable via `minimumSampleDensity`. A 5
    /// samples/sec timeline passes the gate when the floor is 5.
    func testSelectorTunableDensityFloor() {
        let duration: TimeInterval = 1.0
        let timeline = makeTimeline(start: 0.0, end: 1.0, sampleCount: 5)
        let content = LaneContent(
            strokes: [],
            segments: [],
            beatsPerMinute: nil,
            duration: duration,
            loops: false,
            platterTimeline: timeline
        )
        XCTAssertFalse(content.shouldRenderRawTrace())
        XCTAssertTrue(content.shouldRenderRawTrace(minimumSampleDensity: 4.0))
    }

    // MARK: - Renderer structural smoke

    /// Test #8 — `drawRawTrace` executes without crashing on a valid
    /// dense timeline. Asserts the call path is wired, not pixel parity.
    func testDrawRawTraceExecutesWithoutCrashing() {
        let timeline = makeTimeline(start: 0.0, end: 1.0, sampleCount: 20)
        let viewport = LaneViewport(
            size: CGSize(width: 400, height: 600),
            now: 0.5,
            axis: .vertical,
            actionLineFraction: 0.85,
            secondsAhead: 5.5
        )
        let renderer = ImageRenderer(content:
            Canvas { context, _ in
                ScratchMotionRenderer.drawRawTrace(
                    timeline, in: context, viewport: viewport,
                    style: .target
                )
            }
            .frame(width: 400, height: 600)
        )
        XCTAssertNotNil(renderer.cgImage)
    }

    /// Test #9 — `drawCrossfaderRibbon` + `drawCrossfaderTicks` execute
    /// without crashing on synthetic events.
    func testDrawCrossfaderLayerExecutesWithoutCrashing() {
        let events: [CaptureCore.DetectedNotationFaderEvent] = [
            makeFaderEvent(kind: .closed, start: 0.0, end: 2.0),
            makeFaderEvent(kind: .open,   start: 2.0, end: 4.0),
            makeFaderEvent(kind: .pulse,  start: 4.0, end: 4.05, toValue: 1.0),
            makeFaderEvent(kind: .cut,    start: 4.1, end: 4.15, toValue: 0.0),
        ]
        let timeline = CrossfaderStateTimeline(from: events, coverage: 0...5)
        let viewport = LaneViewport(
            size: CGSize(width: 600, height: 200),
            now: 2.0,
            axis: .horizontal,
            actionLineFraction: 0.18,
            secondsAhead: 6.5
        )
        let renderer = ImageRenderer(content:
            Canvas { context, _ in
                ScratchMotionRenderer.drawCrossfaderRibbon(
                    timeline, in: context, viewport: viewport,
                    style: .target
                )
                ScratchMotionRenderer.drawCrossfaderTicks(
                    events, in: context, viewport: viewport,
                    style: .target
                )
            }
            .frame(width: 600, height: 200)
        )
        XCTAssertNotNil(renderer.cgImage)
    }

    // MARK: - Helpers

    /// Builds a uniform-spacing `PlatterPositionTimeline` for selector tests.
    /// Positions ramp linearly from 0 to 1 across the span; confidence = 1.
    private func makeTimeline(
        start: TimeInterval,
        end: TimeInterval,
        sampleCount: Int
    ) -> PlatterPositionTimeline {
        precondition(sampleCount >= 2)
        let samples = (0..<sampleCount).map { i -> PlatterPositionSample in
            let frac = Double(i) / Double(sampleCount - 1)
            return PlatterPositionSample(
                time: start + frac * (end - start),
                position: frac,
                confidence: 1.0
            )
        }
        return PlatterPositionTimeline(
            source: .liveCapture,
            startTime: start,
            endTime: end,
            samples: samples
        )!
    }

    private func makeFaderEvent(
        kind: ScratchFaderEventKind,
        start: Double,
        end: Double,
        fromValue: Double = 0.0,
        toValue: Double = 0.0
    ) -> CaptureCore.DetectedNotationFaderEvent {
        CaptureCore.DetectedNotationFaderEvent(
            startTime: start,
            endTime: end,
            eventKind: kind,
            control: "crossfader",
            fromValue: fromValue,
            toValue: toValue,
            source: "midi",
            confidence: 1.0
        )
    }
}
