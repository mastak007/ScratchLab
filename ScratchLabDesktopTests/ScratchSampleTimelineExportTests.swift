import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — sample-position timeline JSON export.
///
/// Pure value-type coverage: no Core MIDI, no AVFoundation, no file I/O, and nothing
/// from notation / replay / beat engine / capture / scoring. The `exportTimeline()`
/// disk-write wrapper on the @MainActor model is a thin clone of `exportDiagnostics()`
/// (guarded the same way) and is deliberately NOT instantiated here, so these tests stay
/// hardware-free — they exercise the Codable envelope, the derived summary, and the
/// deterministic encoding the wrapper relies on.
final class ScratchSampleTimelineExportTests: XCTestCase {

    /// Builds a timeline from a position ramp (velocity = signed travel between samples).
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

    // MARK: - Codable round-trips

    func testEventCodableRoundTrip() throws {
        let event = ScratchSampleTimelineEvent(
            timeSeconds: 1.25, position: 0.4, velocity: -0.2,
            crossfader: 0.0, muted: true, cc6Step: -1
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ScratchSampleTimelineEvent.self, from: data)
        XCTAssertEqual(decoded, event)

        // And an event with the optional fields absent.
        let bare = ScratchSampleTimelineEvent(
            timeSeconds: 0, position: 0.1, velocity: 0.1,
            crossfader: nil, muted: false, cc6Step: nil
        )
        let bareData = try JSONEncoder().encode(bare)
        XCTAssertEqual(try JSONDecoder().decode(ScratchSampleTimelineEvent.self, from: bareData), bare)
    }

    func testTimelineCodableRoundTrip() throws {
        let timeline = makeTimeline(positions: [0.0, 0.2, 0.4, 0.2, 0.0])
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(ScratchSampleTimeline.self, from: data)
        XCTAssertEqual(decoded, timeline)
    }

    func testExportCodableRoundTripThroughJSONData() throws {
        let timeline = makeTimeline(positions: [0.0, 0.25, 0.5, 0.25, 0.0])
        let export = ScratchSampleTimelineExport(timeline: timeline, exportedAtEpochSeconds: 1_700_000_000)
        let data = try export.jsonData()
        let decoded = try JSONDecoder().decode(ScratchSampleTimelineExport.self, from: data)
        XCTAssertEqual(decoded, export)
        XCTAssertEqual(decoded.events, timeline.events)
    }

    // MARK: - Deterministic encoding

    func testJSONDataIsDeterministic() throws {
        let timeline = makeTimeline(positions: [0.0, 0.2, 0.4, 0.3, 0.1])
        let export = ScratchSampleTimelineExport(timeline: timeline, exportedAtEpochSeconds: 42)
        XCTAssertEqual(try export.jsonData(), try export.jsonData(), "same input → identical bytes")
    }

    func testJSONDataUsesSortedKeys() throws {
        let timeline = makeTimeline(positions: [0.0, 0.5])
        let export = ScratchSampleTimelineExport(timeline: timeline, exportedAtEpochSeconds: 1)
        let json = String(decoding: try export.jsonData(), as: UTF8.self)
        // Top-level keys must appear in alphabetical order (sortedKeys).
        let eventsIdx = try XCTUnwrap(json.range(of: "\"events\""))
        let exportedIdx = try XCTUnwrap(json.range(of: "\"exportedAtEpochSeconds\""))
        let schemaIdx = try XCTUnwrap(json.range(of: "\"schemaVersion\""))
        let summaryIdx = try XCTUnwrap(json.range(of: "\"summary\""))
        XCTAssertTrue(eventsIdx.lowerBound < exportedIdx.lowerBound)
        XCTAssertTrue(exportedIdx.lowerBound < schemaIdx.lowerBound)
        XCTAssertTrue(schemaIdx.lowerBound < summaryIdx.lowerBound)
    }

    func testSchemaVersionIsOne() {
        let export = ScratchSampleTimelineExport(timeline: ScratchSampleTimeline())
        XCTAssertEqual(export.schemaVersion, 1)
        XCTAssertEqual(ScratchSampleTimelineExport.currentSchemaVersion, 1)
    }

    // MARK: - Summary correctness

    func testSummaryReflectsPartialTravelAndReversal() {
        // Push the "ahhh" sample 50% in and back out: partial travel, one mid reversal.
        let timeline = makeTimeline(positions: [0.0, 0.2, 0.4, 0.5, 0.4, 0.2, 0.0])
        let summary = ScratchSampleTimelineSummary(timeline: timeline)

        XCTAssertEqual(summary.eventCount, 7)
        XCTAssertEqual(summary.minPosition ?? -1, 0.0, accuracy: 1e-12)
        XCTAssertEqual(summary.maxPosition ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(summary.positionSpan, 0.5, accuracy: 1e-12)   // NOT a full 1.0 stroke
        XCTAssertEqual(summary.reversalCount, 1)
        XCTAssertEqual(summary.mutedEventCount, 0)
        XCTAssertEqual(summary.durationSeconds, 0.06, accuracy: 1e-9) // 6 gaps × 10 ms
    }

    func testSummaryCountsMutedSegments() {
        // Crossfader shut for the middle two samples.
        let crossfader: [Double?] = [0.70, 0.00, 0.00, 0.70]
        let timeline = makeTimeline(positions: [0.10, 0.20, 0.30, 0.40], crossfader: crossfader)
        let summary = ScratchSampleTimelineSummary(timeline: timeline)
        XCTAssertEqual(summary.mutedEventCount, 2)
        XCTAssertEqual(summary.eventCount, 4) // timing preserved across the muted span
        XCTAssertEqual(summary.positionSpan, 0.30, accuracy: 1e-12)
    }

    // MARK: - Empty-export guard (envelope level)

    func testEmptyTimelineExportIsWellFormed() throws {
        let export = ScratchSampleTimelineExport(timeline: ScratchSampleTimeline())
        XCTAssertEqual(export.summary.eventCount, 0)
        XCTAssertTrue(export.events.isEmpty)
        XCTAssertEqual(export.summary.positionSpan, 0)
        XCTAssertNil(export.summary.minPosition)
        XCTAssertEqual(export.summary.reversalCount, 0)
        XCTAssertEqual(export.summary.durationSeconds, 0)
        // Still encodes deterministically (the model guards the disk write separately).
        XCTAssertEqual(try export.jsonData(), try export.jsonData())
    }
}
