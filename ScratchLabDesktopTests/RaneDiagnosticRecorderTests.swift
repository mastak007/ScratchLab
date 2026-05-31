import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — RANE diagnostic recorder + session summary.
///
/// Pure value-type coverage: no Core MIDI, no AVFoundation, no file I/O, and nothing
/// from notation / replay / beat engine / capture / scoring / export. Events are
/// hand-built so every summary figure is deterministic.
final class RaneDiagnosticRecorderTests: XCTestCase {

    private func event(
        timestamp: TimeInterval = 0,
        raw: Int,
        previousRaw: Int?,
        delta: Int,
        position: TimeInterval = 0,
        crossfader: Double? = nil,
        cc6: Int? = nil,
        deck: Int = 0,
        source: String = "RANE ONE",
        hostTime: TimeInterval? = nil
    ) -> RaneDiagnosticEvent {
        RaneDiagnosticEvent(
            timestamp: timestamp,
            rawPitchBend: raw,
            previousRawPitchBend: previousRaw,
            wrappedDelta: delta,
            samplePositionSeconds: position,
            crossfader: crossfader,
            cc6: cc6,
            deck: deck,
            sourceName: source,
            hostTime: hostTime
        )
    }

    // MARK: - Recorder start/stop gating

    func testRecordIgnoredWhenNotRecording() {
        var recorder = RaneDiagnosticRecorder()
        recorder.record(event(raw: 100, previousRaw: 0, delta: 100))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testStartEnablesRecordingAndCapturesEvents() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start()
        XCTAssertTrue(recorder.isRecording)
        recorder.record(event(raw: 100, previousRaw: 0, delta: 100))
        recorder.record(event(raw: 250, previousRaw: 100, delta: 150))
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testStartClearsPreviousEventsAndSetsCalibrationFlag() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start()
        recorder.record(event(raw: 100, previousRaw: 0, delta: 100))
        recorder.stop()
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertFalse(recorder.isCalibration)

        recorder.start(calibration: true)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.isCalibration)
        XCTAssertTrue(recorder.events.isEmpty, "start() must discard the prior session")
    }

    func testStopHaltsCaptureButKeepsEvents() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start()
        recorder.record(event(raw: 100, previousRaw: 0, delta: 100))
        recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        recorder.record(event(raw: 200, previousRaw: 100, delta: 100))
        XCTAssertEqual(recorder.events.count, 1, "events after stop() are ignored")
    }

    func testResetDiscardsEventsAndCalibration() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start(calibration: true)
        recorder.record(event(raw: 100, previousRaw: 0, delta: 100))
        recorder.reset()
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertFalse(recorder.isCalibration)
    }

    func testStartClearsCapacityFlag() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start()
        for _ in 0..<RaneDiagnosticRecorder.maxEvents {
            recorder.record(event(raw: 1, previousRaw: 0, delta: 1))
        }
        XCTAssertTrue(recorder.didReachCapacity)
        recorder.start()
        XCTAssertFalse(recorder.didReachCapacity, "start() clears the capacity flag")
    }

    // MARK: - Bounded storage (capacity cap)

    func testRecordingAutoStopsAtMaxEvents() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start()
        for _ in 0..<(RaneDiagnosticRecorder.maxEvents + 50) {
            recorder.record(event(raw: 1, previousRaw: 0, delta: 1))
        }
        XCTAssertEqual(recorder.events.count, RaneDiagnosticRecorder.maxEvents, "events are capped")
        XCTAssertFalse(recorder.isRecording, "recording auto-stops at the cap")
        XCTAssertTrue(recorder.didReachCapacity)
    }

    // MARK: - Summary: empty session

    func testEmptySummaryIsZeroAndNil() {
        let summary = RaneDiagnosticSummary(events: [], isCalibration: true)
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertEqual(summary.maxAbsoluteDelta, 0)
        XCTAssertEqual(summary.wrapCount, 0)
        XCTAssertNil(summary.minRawPitchBend)
        XCTAssertNil(summary.maxRawPitchBend)
        XCTAssertEqual(summary.totalAbsoluteTicks, 0)
        XCTAssertNil(summary.estimatedTicksPerRevolution, "no motion -> no estimate even in calibration")
        XCTAssertEqual(summary.aliasWarningCount, 0)
        XCTAssertEqual(summary.aliasFailCount, 0)
    }

    // MARK: - Summary: counts, extents, distance

    func testSummaryCountsExtentsAndAbsoluteTicks() {
        let events = [
            event(raw: 100, previousRaw: 50, delta: 50),
            event(raw: 400, previousRaw: 100, delta: 300),
            event(raw: 250, previousRaw: 400, delta: -150),
        ]
        let summary = RaneDiagnosticSummary(events: events, isCalibration: false)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.maxAbsoluteDelta, 300)
        XCTAssertEqual(summary.minRawPitchBend, 100)
        XCTAssertEqual(summary.maxRawPitchBend, 400)
        XCTAssertEqual(summary.totalAbsoluteTicks, 50 + 300 + 150)
        XCTAssertEqual(summary.wrapCount, 0, "no boundary crossings here")
    }

    // MARK: - Summary: wrap detection

    func testWrapCountDetectsRingBoundaryCrossings() {
        // 16380 -> 10 crosses the 16384 ring boundary (|10 - 16380| = 16370 > 8192).
        // 10 -> 16370 crosses back. 16370 -> 16375 does not.
        let events = [
            event(raw: 16380, previousRaw: 16300, delta: 80),
            event(raw: 10, previousRaw: 16380, delta: 14),   // forward wrap
            event(raw: 16370, previousRaw: 10, delta: -24),  // reverse wrap
            event(raw: 16375, previousRaw: 16370, delta: 5),
        ]
        let summary = RaneDiagnosticSummary(events: events, isCalibration: false)
        XCTAssertEqual(summary.wrapCount, 2)
    }

    func testWrapCountIgnoresSeedingEventWithNilPrevious() {
        let events = [
            event(raw: 8000, previousRaw: nil, delta: 0), // seeding event, no wrap possible
            event(raw: 8100, previousRaw: 8000, delta: 100),
        ]
        let summary = RaneDiagnosticSummary(events: events, isCalibration: false)
        XCTAssertEqual(summary.wrapCount, 0)
    }

    // MARK: - Summary: alias thresholds

    func testAliasWarningAndFailCounts() {
        // warn threshold = 4096, fail threshold = 8192.
        let events = [
            event(raw: 0, previousRaw: 0, delta: 100),    // below warn
            event(raw: 0, previousRaw: 0, delta: 5000),   // warn only
            event(raw: 0, previousRaw: 0, delta: -9000),  // warn + fail
        ]
        let summary = RaneDiagnosticSummary(events: events, isCalibration: false)
        XCTAssertEqual(summary.aliasWarningCount, 2, "warn counts both the 5000 and 9000 events")
        XCTAssertEqual(summary.aliasFailCount, 1, "only the 9000 event exceeds the fail threshold")
    }

    // MARK: - Summary: ticks-per-revolution estimate

    func testCalibrationEstimatesTicksPerRevolutionFromAbsoluteTicks() {
        let events = [
            event(raw: 100, previousRaw: 0, delta: 1200),
            event(raw: 100, previousRaw: 0, delta: 1300),
            event(raw: 100, previousRaw: 0, delta: -500),
        ]
        let calibration = RaneDiagnosticSummary(events: events, isCalibration: true)
        XCTAssertEqual(calibration.estimatedTicksPerRevolution, 1200 + 1300 + 500)

        let plain = RaneDiagnosticSummary(events: events, isCalibration: false)
        XCTAssertNil(plain.estimatedTicksPerRevolution, "no estimate outside calibration mode")
    }

    func testRecorderSummaryMatchesDirectSummary() {
        var recorder = RaneDiagnosticRecorder()
        recorder.start(calibration: true)
        let events = [
            event(raw: 200, previousRaw: 100, delta: 100),
            event(raw: 600, previousRaw: 200, delta: 400),
        ]
        events.forEach { recorder.record($0) }
        XCTAssertEqual(recorder.summary, RaneDiagnosticSummary(events: events, isCalibration: true))
    }

    // MARK: - Export envelope / JSON round-trip

    func testExportEnvelopeCarriesSchemaSummaryAndEvents() {
        let events = [event(timestamp: 0.5, raw: 300, previousRaw: 100, delta: 200, position: 1.25, crossfader: 0.5)]
        let export = RaneDiagnosticSessionExport(events: events, isCalibration: true, exportedAtEpochSeconds: 1000)
        XCTAssertEqual(export.schemaVersion, RaneDiagnosticSessionExport.currentSchemaVersion)
        XCTAssertEqual(export.exportedAtEpochSeconds, 1000)
        XCTAssertTrue(export.isCalibration)
        XCTAssertEqual(export.summary, RaneDiagnosticSummary(events: events, isCalibration: true))
        XCTAssertEqual(export.events, events)
    }

    func testExportJSONRoundTrips() throws {
        let events = [
            event(timestamp: 0.0, raw: 100, previousRaw: nil, delta: 0, position: 0, crossfader: nil, deck: 1, source: "RANE ONE MKII"),
            event(timestamp: 0.016, raw: 16380, previousRaw: 100, delta: -104, position: 0.01, crossfader: 0.75, deck: 1),
        ]
        let export = RaneDiagnosticSessionExport(events: events, isCalibration: false, exportedAtEpochSeconds: 12345)
        let data = try export.jsonData()
        let decoded = try JSONDecoder().decode(RaneDiagnosticSessionExport.self, from: data)
        XCTAssertEqual(decoded, export)
    }

    func testExportSchemaIsV3AndCC6AndHostTimeRoundTrip() throws {
        XCTAssertEqual(RaneDiagnosticSessionExport.currentSchemaVersion, 3)
        let events = [
            event(raw: 8700, previousRaw: 8000, delta: 700, cc6: 54, hostTime: 100.0),
            event(raw: 13725, previousRaw: 8700, delta: 5025, cc6: 53, hostTime: 100.004), // +4ms, CC6 -1
            event(raw: 2500, previousRaw: 13725, delta: 1159, cc6: nil, hostTime: nil),     // both optional → nil
        ]
        let export = RaneDiagnosticSessionExport(events: events, isCalibration: false, exportedAtEpochSeconds: 1)
        let decoded = try JSONDecoder().decode(RaneDiagnosticSessionExport.self, from: try export.jsonData())
        XCTAssertEqual(decoded.events.map(\.cc6), [54, 53, nil])
        XCTAssertEqual(decoded.events.map(\.hostTime), [100.0, 100.004, nil])
        XCTAssertEqual(decoded, export)
    }

    func testExportJSONIsDeterministic() throws {
        let events = [event(raw: 100, previousRaw: 0, delta: 100, crossfader: 0.25)]
        let export = RaneDiagnosticSessionExport(events: events, isCalibration: false, exportedAtEpochSeconds: 7)
        let first = try export.jsonData()
        let second = try export.jsonData()
        XCTAssertEqual(first, second, "sorted-keys pretty JSON must be byte-stable")
    }
}

/// Tester diagnostics bundle (Slice 10): the file set a pro-DJ tester sends back.
/// Pure builder + a thin folder write to a temporary directory. No network.
final class TesterDiagnosticsBundleTests: XCTestCase {

    private let profileJSON = Data("{\"format\":\"controller_profile_v1\"}".utf8)
    private let appInfo = "App: ScratchLab\nVersion: 1.0 (build 1)"
    private let sourceInfo = "Selected source: RANE ONE"
    private let readme = "ScratchLab — tester diagnostics bundle"

    func testBundleContainsExpectedFilesWhenAllPresent() {
        let bundle = TesterDiagnosticsBundle(
            timelineJSON: Data("[]".utf8),
            raneDiagnosticJSON: Data("{}".utf8),
            controllerProfileJSON: profileJSON,
            appBuildInfo: appInfo, midiSourceInfo: sourceInfo, readme: readme
        )
        XCTAssertEqual(bundle.fileNames, [
            "ScratchTimeline.json", "RaneDiagnostic.json", "ControllerProfile.json",
            "app-build-info.txt", "midi-source-info.txt", "README.txt"
        ])
    }

    func testOptionalFilesOmittedWhenMissing() {
        let bundle = TesterDiagnosticsBundle(
            timelineJSON: nil, raneDiagnosticJSON: nil,
            controllerProfileJSON: profileJSON,
            appBuildInfo: appInfo, midiSourceInfo: sourceInfo, readme: readme
        )
        XCTAssertEqual(bundle.fileNames, [
            "ControllerProfile.json", "app-build-info.txt", "midi-source-info.txt", "README.txt"
        ])
        XCTAssertFalse(bundle.fileNames.contains("ScratchTimeline.json"))
        XCTAssertFalse(bundle.fileNames.contains("RaneDiagnostic.json"))
    }

    func testNoUnrelatedFilesIncluded() {
        // The bundle must include ONLY the known set — nothing private/unrelated leaks in.
        let allowed: Set<String> = [
            "ScratchTimeline.json", "RaneDiagnostic.json", "ControllerProfile.json",
            "app-build-info.txt", "midi-source-info.txt", "README.txt"
        ]
        let bundle = TesterDiagnosticsBundle(
            timelineJSON: Data("[]".utf8), raneDiagnosticJSON: Data("{}".utf8),
            controllerProfileJSON: profileJSON,
            appBuildInfo: appInfo, midiSourceInfo: sourceInfo, readme: readme
        )
        XCTAssertTrue(Set(bundle.fileNames).isSubset(of: allowed))
    }

    func testWriteProducesFolderWithFilesOnDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BundleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundle = TesterDiagnosticsBundle(
            timelineJSON: Data("[]".utf8), raneDiagnosticJSON: nil,
            controllerProfileJSON: profileJSON,
            appBuildInfo: appInfo, midiSourceInfo: sourceInfo, readme: readme
        )
        let folder = try bundle.write(to: tempDir, folderName: "ScratchLab-Diagnostics-1")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(written), Set(bundle.fileNames))
        // The omitted optional must not appear on disk.
        XCTAssertFalse(written.contains("RaneDiagnostic.json"))
    }
}
