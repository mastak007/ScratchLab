import XCTest
import SwiftUI
@testable import ScratchLab

/// Scratch Playback Lab — render-config foundation (roadmap slice R0).
///
/// Two contracts under test:
///  1. The **default** config reproduces today's captured-notation preview
///     exactly — its derived `motionStyle` equals `ScratchMotionRenderer.Style.user`,
///     its muted alpha matches the current band, and at `horizontalZoom == 1`
///     the viewport time density is unchanged. (No visible change at defaults.)
///  2. The config is **display-only**: mutating any render field never mutates a
///     captured `ScratchSampleTimeline` or its exported JSON position bytes.
///
/// Pure value-type coverage: no UI, no Canvas, no file I/O, no PNG.
final class PlaybackLabRenderConfigTests: XCTestCase {

    /// Builds a timeline from a position ramp (velocity = signed travel between
    /// samples), one sample per 10 ms — same shape the sibling timeline tests use.
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

    // MARK: - Default config reproduces the current render

    func testDefaultMotionStyleEqualsUserStyle() {
        // The captured-notation preview drew with `.user`; the foundation must
        // reproduce it byte-for-byte so the out-of-box render is unchanged.
        XCTAssertEqual(PlaybackLabRenderConfig().motionStyle, ScratchMotionRenderer.Style.user)
    }

    func testDefaultDisplayFieldsMatchCurrentLiterals() {
        let config = PlaybackLabRenderConfig()
        XCTAssertEqual(config.lineWidth, 3)            // .user line width
        XCTAssertTrue(config.glow)                     // .user opt-in glow
        XCTAssertTrue(config.showsNodes)               // articulation dots on
        XCTAssertEqual(config.mutedAlpha, 0.06, accuracy: 1e-12) // current muted band
        XCTAssertEqual(config.horizontalZoom, 1)       // identity time density
        XCTAssertEqual(config.nodeRadius, 2.5)         // mirrors renderer's constant
        XCTAssertFalse(config.controlsEnabled)         // no controls surfaced yet
    }

    func testDefaultSecondsAheadIsTheRawDuration() {
        // The preview fits the whole capture by setting secondsAhead = duration.
        // At horizontalZoom == 1 that must be byte-identical to the raw duration.
        let config = PlaybackLabRenderConfig()
        for duration in [0.001, 0.5, 2.0, 17.3333] {
            XCTAssertEqual(config.secondsAhead(forDuration: duration), duration)
        }
    }

    // MARK: - The knobs are live (foundation actually feeds the render inputs)

    func testChangingDisplayFieldsChangesDerivedRenderInputs() {
        var config = PlaybackLabRenderConfig()
        config.lineWidth = 5
        config.glow = false
        config.showsNodes = false
        XCTAssertNotEqual(config.motionStyle, ScratchMotionRenderer.Style.user)
        XCTAssertEqual(config.motionStyle.lineWidth, 5)
        XCTAssertFalse(config.motionStyle.glow)
        XCTAssertFalse(config.motionStyle.showsNodes)

        config.horizontalZoom = 2
        XCTAssertEqual(config.secondsAhead(forDuration: 4.0), 2.0, accuracy: 1e-12)
    }

    // MARK: - Truth guard: display config never mutates captured data / export

    func testRenderConfigChangesDoNotMutateTimelineOrExportedPositions() throws {
        let timeline = makeTimeline(positions: [0.4, 0.5, 0.6, 0.5, 0.4],
                                    crossfader: [0.7, 0.0, 0.0, 0.7, 0.7])
        let baselineEvents = timeline.events
        let baselineExport = try ScratchSampleTimelineExport(
            timeline: timeline, exportedAtEpochSeconds: 1_700_000_000).jsonData()

        // A spread of wildly different display configs. None of them takes the
        // timeline as input — the config has no path back to captured data — so
        // exercising each must leave the timeline and its export untouched.
        var configs: [PlaybackLabRenderConfig] = [PlaybackLabRenderConfig()]
        var loud = PlaybackLabRenderConfig()
        loud.lineWidth = 9
        loud.glow = false
        loud.showsNodes = false
        loud.mutedAlpha = 0.9
        loud.horizontalZoom = 3
        loud.nodeRadius = 8
        loud.controlsEnabled = true
        configs.append(loud)

        for config in configs {
            // Touch every derived render input the previews read.
            _ = config.motionStyle
            _ = config.secondsAhead(forDuration: 2.0)
            _ = config.mutedAlpha

            // The captured data is byte-identical regardless of display config.
            XCTAssertEqual(timeline.events, baselineEvents)
            let export = try ScratchSampleTimelineExport(
                timeline: timeline, exportedAtEpochSeconds: 1_700_000_000).jsonData()
            XCTAssertEqual(export, baselineExport, "display config must not change exported positions")
        }
    }
}
