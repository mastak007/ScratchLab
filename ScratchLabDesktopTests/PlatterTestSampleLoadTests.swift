// PlatterTestSampleLoadTests.swift
// Confirms the Debug hardware-test "Load platter ahhh test" button loads
// the validated one-revolution `dvs_ahhh` asset (VirtualPlatter/ahhh.wav,
// ~1.0474 s) — not the ~4.4667 s hot-cue pad asset `ahhh.wav`, which does
// not fit one physical platter revolution and silently produced no audio
// via direct-MIDI on the first Rane hardware test (2026-08-09).

import XCTest
@testable import ScratchLab

final class PlatterTestSampleLoadTests: XCTestCase {

    private func makeEngine() throws -> MacCaptureEngine {
        let resourceRoot = try XCTUnwrap(
            Bundle(for: MacCaptureEngine.self).resourceURL,
            "The app test host must expose its resource root"
        )
        return MacCaptureEngine(
            autoRefreshDevices: false,
            sampleResourceRoot: resourceRoot
        )
    }

    func testLoadPlatterTestSampleRequestsDVSAhhhNotTheLongPadAsset() throws {
        let engine = try makeEngine()
        engine.loadPlatterTestSample()

        let snapshot = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertEqual(
            snapshot.loadedSampleID,
            "dvs_ahhh",
            "The platter test button must load the validated one-revolution asset, not the long hot-cue pad clip"
        )
        XCTAssertNil(snapshot.lastLoadError)

        // `platterTestLoadStatus` is published via an async main-queue hop
        // (`publishOnMainAsync`, matching every other UI-facing field in
        // this class) — flush the main queue before reading it, rather than
        // asserting immediately against a not-yet-applied value.
        let statusPublished = expectation(description: "platterTestLoadStatus published")
        DispatchQueue.main.async { statusPublished.fulfill() }
        wait(for: [statusPublished], timeout: 2.0)

        XCTAssertEqual(engine.platterTestLoadStatus, "loaded: dvs_ahhh")
    }

    func testAudiblePlatterTestUsesDVSAhhhAndLeavesItArmed() throws {
        let engine = try makeEngine()
        engine.previewPlatterTestSample()

        let snapshot = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.loadedSampleID, "dvs_ahhh")
        XCTAssertNil(snapshot.lastLoadError)
        XCTAssertTrue(snapshot.engineRunning)

        let statusPublished = expectation(description: "audible platter test status published")
        DispatchQueue.main.async { statusPublished.fulfill() }
        wait(for: [statusPublished], timeout: 2.0)

        XCTAssertEqual(engine.platterTestLoadStatus, "audible test: dvs_ahhh")
    }
}
