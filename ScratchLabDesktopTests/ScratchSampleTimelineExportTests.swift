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

    // MARK: - Slice A: diagnostic pitch-bend fields (CC6 + pitch-bend fusion investigation)

    func testEventCarriesPitchBendDiagnosticsRoundTrip() throws {
        let event = ScratchSampleTimelineEvent(
            timeSeconds: 2.5, position: 0.6, velocity: 0.3,
            crossfader: 0.7, muted: false, cc6Step: 1,
            rawPitchBend: 9001, pitchBendDelta: -123, pitchBendAgeSeconds: 0.004
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ScratchSampleTimelineEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.rawPitchBend, 9001)
        XCTAssertEqual(decoded.pitchBendDelta, -123)
        XCTAssertEqual(decoded.pitchBendAgeSeconds, 0.004)
    }

    /// Old exports predate the diagnostic fields. JSON lacking those keys must still decode,
    /// with the new fields nil — so existing captures keep loading.
    func testOldEventJSONWithoutPitchBendFieldsDecodesWithNilDiagnostics() throws {
        let oldJSON = """
        { "timeSeconds": 1.0, "position": 0.5, "velocity": 0.2, "muted": false }
        """
        let decoded = try JSONDecoder().decode(
            ScratchSampleTimelineEvent.self, from: Data(oldJSON.utf8)
        )
        XCTAssertEqual(decoded.timeSeconds, 1.0)
        XCTAssertEqual(decoded.position, 0.5)
        XCTAssertEqual(decoded.velocity, 0.2)
        XCTAssertNil(decoded.crossfader)
        XCTAssertNil(decoded.cc6Step)
        XCTAssertNil(decoded.rawPitchBend)
        XCTAssertNil(decoded.pitchBendDelta)
        XCTAssertNil(decoded.pitchBendAgeSeconds)
    }

    /// A nil-diagnostic event must not emit the new keys, so normal exports stay clean and
    /// byte-stable for diffing (and so the schema only grows when data is actually present).
    func testNilPitchBendDiagnosticsAreOmittedFromJSON() throws {
        let bare = ScratchSampleTimelineEvent(
            timeSeconds: 0, position: 0.1, velocity: 0.1,
            crossfader: nil, muted: false, cc6Step: 5
        )
        let json = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        XCTAssertFalse(json.contains("rawPitchBend"))
        XCTAssertFalse(json.contains("pitchBendDelta"))
        XCTAssertFalse(json.contains("pitchBendAgeSeconds"))
    }

    /// The capture contract Slice A relies on: a CC6 append carries the latest pitch-bend
    /// sample (mirrors the model holding the last pitch bend, then attaching it to the next
    /// CC6 event), while a CC6-only append leaves the diagnostics nil.
    func testAppendCarriesPitchBendDiagnosticsOntoCC6Event() throws {
        var timeline = ScratchSampleTimeline()
        // CC6-only event (no pitch bend seen yet) → nil diagnostics.
        let cc6Only = try XCTUnwrap(timeline.append(
            timeSeconds: 0.0, position: 0.0, velocity: 0.0, cc6Step: 1
        ))
        XCTAssertNil(cc6Only.rawPitchBend)
        XCTAssertNil(cc6Only.pitchBendDelta)
        XCTAssertNil(cc6Only.pitchBendAgeSeconds)

        // A pitch bend arrived at t=0.010; the next CC6 event at t=0.012 carries it (age 2 ms).
        let withPB = try XCTUnwrap(timeline.append(
            timeSeconds: 0.012, position: 0.01, velocity: 0.5, cc6Step: 1,
            rawPitchBend: 12345, pitchBendDelta: 678, pitchBendAgeSeconds: 0.012 - 0.010
        ))
        XCTAssertEqual(withPB.rawPitchBend, 12345)
        XCTAssertEqual(withPB.pitchBendDelta, 678)
        XCTAssertEqual(try XCTUnwrap(withPB.pitchBendAgeSeconds), 0.002, accuracy: 1e-9)
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

/// Sandbox-safe export wiring: suggested default names are deterministic, and the model
/// export methods write to an INJECTED destination URL (no direct ~/Downloads writes), with
/// empty-export guards intact. No schema changes are exercised here.
final class PlaybackLabExportTests: XCTestCase {

    // MARK: - Suggested default filenames (preserved, pure)

    func testSuggestedNamesPreserveExistingPatterns() {
        XCTAssertEqual(PlaybackLabExport.timelineFilename(epoch: 123), "ScratchTimeline-123.json")
        XCTAssertEqual(PlaybackLabExport.diagnosticFilename(epoch: 123), "RaneDiagnostic-123.json")
        XCTAssertEqual(PlaybackLabExport.notationPNGFilename(epoch: 123), "ScratchNotation-123.png")
        XCTAssertEqual(PlaybackLabExport.testerBundleFolderName(epoch: 123), "ScratchLab-Diagnostics-123")
        XCTAssertEqual(PlaybackLabExport.raneProfileTemplateFilename, "rane-one-mkii.controller_profile_v1.json")
    }

    // MARK: - Model writes to an injected destination (happy paths that need no capture)

    @MainActor
    func testExportRaneProfileTemplateWritesToInjectedURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PLExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent(PlaybackLabExport.raneProfileTemplateFilename)
        let model = ScratchPlaybackLabModel()
        model.exportRaneProfileTemplate(to: url)

        XCTAssertNil(model.lastProfileExportError)
        XCTAssertEqual(model.lastProfileExportPath, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Round-trips back to the built-in RANE profile.
        XCTAssertEqual(try ControllerProfileStore.decodeDocument(Data(contentsOf: url)), .raneOneMKII)
    }

    @MainActor
    func testExportTesterDiagnosticsWritesFolderToInjectedURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PLExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let folderURL = dir.appendingPathComponent("ScratchLab-Diagnostics-1")
        let model = ScratchPlaybackLabModel()
        model.exportTesterDiagnostics(toFolder: folderURL)

        XCTAssertNil(model.lastDiagnosticsBundleError)
        XCTAssertEqual(model.lastDiagnosticsBundlePath, folderURL.path)
        let written = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
        // No capture → timeline / RANE diagnostic omitted; the always-present pieces remain.
        XCTAssertTrue(written.contains("ControllerProfile.json"))
        XCTAssertTrue(written.contains("README.txt"))
        XCTAssertFalse(written.contains("ScratchTimeline.json"))
    }

    // MARK: - Empty-export guards still hold (and never write)

    @MainActor
    func testEmptyTimelineExportGuardDoesNotWrite() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("should-not-exist-\(UUID().uuidString).json")
        let model = ScratchPlaybackLabModel()
        model.exportTimeline(to: url)
        XCTAssertNotNil(model.lastTimelineExportError)
        XCTAssertNil(model.lastTimelineExportPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testEmptyDiagnosticExportGuardDoesNotWrite() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("should-not-exist-\(UUID().uuidString).json")
        let model = ScratchPlaybackLabModel()
        model.exportDiagnostics(to: url)
        XCTAssertNotNil(model.lastDiagnosticExportError)
        XCTAssertNil(model.lastDiagnosticExportPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testNilPNGExportGuardDoesNotWrite() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("should-not-exist-\(UUID().uuidString).png")
        let model = ScratchPlaybackLabModel()
        model.exportCapturedNotationPNG(nil, to: url) // empty timeline + nil data
        XCTAssertNotNil(model.lastNotationPNGExportError)
        XCTAssertNil(model.lastNotationPNGExportPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
