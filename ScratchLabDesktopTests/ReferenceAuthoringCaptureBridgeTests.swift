// ReferenceAuthoringCaptureBridgeTests.swift
// ScratchLabDesktopTests
//
// Hardware-free tests for `ReferenceAuthoringCaptureBridge`: the pure mapping
// functions (crossfader sample extraction, address recovery, advisory
// auto-detection mapping) and the concurrency-misuse guards. No Rane, camera,
// Watch, or real audio hardware is touched — `MacCaptureEngine` is
// constructed with `autoRefreshDevices: false` and isolated `UserDefaults`,
// the same pattern already used by `MIDILearnEngineTests` and friends.
//
// Nothing here treats any recorded take as valid reference data — these
// tests only prove the bridge maps and fails correctly.

import AVFoundation
import CoreMIDI
import XCTest
@testable import ScratchLab

final class ReferenceAuthoringCaptureBridgeTests: XCTestCase {

    func testWatchHashUsesExactAssociatedBytesAndRejectsDifferentCaptureIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let capture = WatchMotionCaptureSession(sessionID: "session-a", takeID: "take-001", commandID: "command",
            requestedAt: date, acknowledgedAt: date, syncState: .acknowledged, sourceDeviceName: "Fixture",
            sampleRateHz: 100, startedAt: date, endedAt: date.addingTimeInterval(1),
            deviceRecordedAtStart: date, deviceRecordedAtEnd: date.addingTimeInterval(1), appVersion: "1",
            timingMetadata: nil, samples: (0..<10).map { index in
                WatchMotionSample(elapsedTime: Double(index) / 100, attitudeRoll: 0, attitudePitch: 0,
                    attitudeYaw: 0, quaternionX: 0, quaternionY: 0, quaternionZ: 0, quaternionW: 1,
                    gravityX: 0, gravityY: 0, gravityZ: -1, userAccelerationX: 0, userAccelerationY: 0,
                    userAccelerationZ: 0, rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0)
            })
        let bytes = try WatchMotionCaptureCodec.encoder.encode(capture)
        try bytes.write(to: root.appendingPathComponent("watch.json"))
        let sidecar = makeSidecar(watchSyncState: .acknowledged, linkedMotionCaptureID: capture.id,
            linkedMotionFileName: "watch.json")
        XCTAssertEqual(ReferenceAuthoringCaptureBridge.verifiedWatchData(sidecar: sidecar, takeDirectory: root), bytes)
        let mismatched = makeSidecar(watchSyncState: .acknowledged, linkedMotionCaptureID: UUID(),
            linkedMotionFileName: "watch.json")
        XCTAssertNil(ReferenceAuthoringCaptureBridge.verifiedWatchData(sidecar: mismatched, takeDirectory: root))
        let wrongTake = makeSidecar(takeID: "take-002", watchSyncState: .acknowledged,
            linkedMotionCaptureID: capture.id, linkedMotionFileName: "watch.json")
        XCTAssertNil(ReferenceAuthoringCaptureBridge.verifiedWatchData(sidecar: wrongTake, takeDirectory: root))
    }

    func testPortableMediaOriginSurvivesForeignHostTimebaseAndLegacyDecode() throws {
        let timing = CaptureTimingMetadata(clickStartHostTime: 1, recordingStartHostTime: 101,
            recordingStartOffsetSeconds: 2.5263333333333335)
        let restored = try JSONDecoder().decode(CaptureTimingMetadata.self, from: JSONEncoder().encode(timing))
        let origin = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: restored))
        XCTAssertEqual(origin.recordingStartOffsetSeconds, timing.recordingStartOffsetSeconds)
        let legacy = try JSONDecoder().decode(CaptureTimingMetadata.self,
            from: Data(#"{"clickStartHostTime":1,"recordingStartHostTime":101}"#.utf8))
        XCTAssertNil(legacy.recordingStartOffsetSeconds)
        for invalid in [-1.0, Double.infinity, Double.nan] {
            var bad = timing
            bad.recordingStartOffsetSeconds = invalid
            XCTAssertThrowsError(try ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: bad))
        }
    }

    func testBoundCapturePlansOnlyRecordedRepetitionsAndTailAndSeparatesNewSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let beat = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, rootURL: root)
        func configuration(id: String) -> ReferenceAuthoringBridgeTakeConfiguration {
            let intent = ReferenceCaptureIntent(id: id, parentTechniqueID: "tear", variantID: "tear.forward",
                recipeID: "tear_1bar", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
                bpm: 95, beatsPerCycle: 4,
                plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1), beatSpec: beat.binding)
            return .init(technique: .tear, bpm: 95, beatEngineMode: .battleLoop,
                captureIntent: intent, preparedBeat: beat)
        }
        let first = configuration(id: "setup-one")
        let firstConfig = first.recordingSessionConfig(existing: nil, now: Date(timeIntervalSince1970: 100))
        let expectedFrames = Int64((60.0 / 95 * 48_000).rounded()) * 20
        XCTAssertEqual(try XCTUnwrap(firstConfig.plannedTakeDurationSeconds), Double(expectedFrames) / 48_000,
            accuracy: 0.00000001)
        XCTAssertNil(firstConfig.takeDurationSeconds, "A plan is not a measured capture duration.")
        let retake = first.recordingSessionConfig(existing: firstConfig, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(retake.sessionID, firstConfig.sessionID)
        XCTAssertEqual(retake.createdAt, firstConfig.createdAt)
        let second = configuration(id: "setup-two").recordingSessionConfig(existing: firstConfig,
            now: Date(timeIntervalSince1970: 300))
        XCTAssertNotEqual(second.sessionID, firstConfig.sessionID)
        XCTAssertEqual(second.referenceCaptureIntent?.id, "setup-two")
        XCTAssertEqual(firstConfig.referenceCaptureIntent?.id, "setup-one")
    }

    func testFinalizedCaptureKeepsVerifiedBeatAfterSourceStoreIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 95, rootURL: store)
        let mediaURL = root.appendingPathComponent("capture/take.mov")
        try ReferenceAuthoringCaptureBridge.preserveBeat(prepared, beside: mediaURL)
        try FileManager.default.removeItem(at: store)
        let savedRoot = mediaURL.deletingLastPathComponent().appendingPathComponent("beat_assets")
        let saved = try ReferenceBeatAssetStore.resolve(binding: prepared.binding, rootURL: savedRoot)
        XCTAssertEqual(saved.binding, prepared.binding)
        try ReferenceAuthoringCaptureBridge.preserveBeat(saved, beside: mediaURL)
        try Data("damaged".utf8).write(to: saved.productionMasterURL)
        XCTAssertThrowsError(try ReferenceAuthoringCaptureBridge.preserveBeat(saved, beside: mediaURL))
        XCTAssertEqual(try Data(contentsOf: saved.productionMasterURL), Data("damaged".utf8),
            "Preservation must report changed evidence, not overwrite it.")
    }

    func testMediaOriginConvertsCaptureHostTicksAndRejectsMissingOrUnorderedPairs() throws {
        let clickStart: UInt64 = 1_000
        let delta = AVAudioTime.hostTime(forSeconds: 4 * 60.0 / 95)
        let origin = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(
            captureTiming: .init(clickStartHostTime: clickStart, recordingStartHostTime: clickStart + delta)))
        XCTAssertEqual(origin.recordingStartOffsetSeconds, AVAudioTime.seconds(forHostTime: delta))
        XCTAssertEqual(origin.clickStartHostTime, clickStart)
        XCTAssertEqual(origin.recordingStartHostTime, clickStart + delta)
        XCTAssertTrue(origin.validationIssues.isEmpty)
        XCTAssertNil(try ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: nil))
        for timing in [
            CaptureTimingMetadata(clickStartHostTime: nil, recordingStartHostTime: 2),
            CaptureTimingMetadata(clickStartHostTime: 0, recordingStartHostTime: 2),
            CaptureTimingMetadata(clickStartHostTime: 2, recordingStartHostTime: 1),
        ] {
            XCTAssertThrowsError(try ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: timing))
        }
    }

    func testWitnessedTimingUsesRecordedSampleRateAndPostCountInMediaDuration() throws {
        let countInFrames = Int64((60.0 / 95 * 48_000).rounded()) * 4
        let beat = ReferenceBeatSpecBinding(id: "synthetic-95", version: 1, family: "fixture", bpm: 95,
            feel: .straight, countInFrameCount: countInFrames, loopStartFrame: countInFrames,
            loopFrameCount: countInFrames * 4, sampleRate: 48_000,
            productionMasterFileName: "master.wav", productionMasterSHA256: String(repeating: "a", count: 64),
            sparseAnalysisMixFileName: "analysis.wav", sparseAnalysisMixSHA256: String(repeating: "b", count: 64),
            availableStemSHA256: [:], rightsState: .procedurallyGeneratedOriginal, provenance: "Synthetic test only")
        let intent = ReferenceCaptureIntent(id: "fixture", parentTechniqueID: "tear", variantID: "tear_fixture",
            recipeID: "fixture", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
            bpm: 95, beatsPerCycle: 8, plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1), beatSpec: beat)
        let clocks = CaptureTimingMetadata(clickStartHostTime: 1_000,
            recordingStartHostTime: 1_000 + AVAudioTime.hostTime(forSeconds: Double(countInFrames) / 48_000))
        let origin = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeMediaTimeOrigin(captureTiming: clocks))
        let planned = Double(4 + 4 * 8 + 4) * 60 / 95 - origin.recordingStartOffsetSeconds
        let frames = Int64((planned * 44_100).rounded())
        let sidecar = makeSidecar(watchSyncState: .notRequested, linkedMotionCaptureID: nil,
            captureTiming: clocks, sessionConfig: CaptureSessionConfig(bpm: 95, referenceCaptureIntent: intent))
        let timing = try XCTUnwrap(ReferenceAuthoringCaptureBridge.makeWitnessedTiming(sidecar: sidecar,
            audio: .init(fileName: "take.wav", exists: true, byteCount: frames * 8,
                frameCount: frames, sampleRate: 44_100), videoURL: nil, mediaTimeOrigin: origin))
        XCTAssertEqual(timing.measuredWAVDurationSeconds, Double(frames) / 44_100)
        XCTAssertEqual(timing.plannedDurationSeconds, planned, accuracy: 0.0000001)
        XCTAssertEqual(ReferenceWitnessedTimingValidator.issues(timing, intent: intent, mediaTimeOrigin: origin), [])
        let mismatch = ReferenceMediaTimeOrigin(clickStartHostTime: origin.clickStartHostTime,
            recordingStartHostTime: origin.recordingStartHostTime + 1,
            recordingStartOffsetSeconds: origin.recordingStartOffsetSeconds + 1)
        let issues = ReferenceWitnessedTimingValidator.issues(timing, intent: intent, mediaTimeOrigin: mismatch)
        XCTAssertTrue(issues.contains { $0.contains("timestamps do not match") })
        XCTAssertTrue(issues.contains { $0.contains("planned media duration") })
    }

    private func makeIsolatedEngine() -> MacCaptureEngine {
        let suiteName = "com.machelpnz.scratchlab.tests.reference-bridge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
    }

    private func makeCrossfaderEvent(
        deviceIdentifier: String = "midi_rane_one_mk2",
        deviceName: String = "Rane ONE MKII",
        channel: Int = 15,
        controller: Int = 8,
        value: Int = 10,
        takeRelativeTime: Double = 1.0,
        calibratedPosition: Double? = 0.75,
        mappedControl: String? = "crossfader"
    ) -> CaptureCore.RawMixerMIDIEvent {
        CaptureCore.RawMixerMIDIEvent(
            timestamp: takeRelativeTime,
            takeRelativeTime: takeRelativeTime,
            deviceIdentifier: deviceIdentifier,
            deviceName: deviceName,
            channel: channel,
            controller: controller,
            value: value,
            normalizedValue: Double(value) / 127.0,
            mappedControl: mappedControl,
            calibratedPosition: calibratedPosition,
            calibrationID: calibratedPosition == nil ? nil : "cal-1"
        )
    }

    private func makeBoundary(
        token: RoutineRecordingRequestToken,
        takeID: String,
        mediaURL: URL,
        didStartRecording: Bool = true,
        stopWasRequested: Bool = true,
        didEnterFinalization: Bool,
        completion: RoutineRecordingFinalizationCompletion? = nil
    ) -> RoutineRecordingBoundarySnapshot {
        RoutineRecordingBoundarySnapshot(
            token: token,
            takeID: takeID,
            mediaURL: mediaURL,
            didStartRecording: didStartRecording,
            stopWasRequested: stopWasRequested,
            didEnterFinalization: didEnterFinalization,
            completion: completion,
            startFailureDescription: nil
        )
    }

    private func makeCompletion(
        token: RoutineRecordingRequestToken,
        takeID: String,
        mediaURL: URL,
        succeeded: Bool = true,
        statusMessage: String = "Finalized"
    ) -> RoutineRecordingFinalizationCompletion {
        RoutineRecordingFinalizationCompletion(
            token: token,
            takeID: takeID,
            mediaURL: mediaURL,
            succeeded: succeeded,
            statusMessage: statusMessage
        )
    }

    // MARK: - crossfaderPositionSamples: calibrated-position authority

    func testUsesCalibratedPositionWhenEveryEventHasOne() {
        let events = [
            makeCrossfaderEvent(value: 0, takeRelativeTime: 0, calibratedPosition: 1.0),
            makeCrossfaderEvent(value: 52, takeRelativeTime: 1, calibratedPosition: 0.0)
        ]
        let samples = ReferenceAuthoringCaptureBridge.crossfaderPositionSamples(from: events)
        XCTAssertEqual(samples.map(\.normalizedPosition), [1.0, 0.0])
        XCTAssertEqual(samples.map(\.rawValue), [0, 52])
    }

    func testFallsBackToNormalizedValueOnlyWhenTheWholeStreamIsUncalibrated() {
        // No calibration in force for ANY sample — genuinely uncalibrated
        // stream, diagnostic fallback applies uniformly.
        let events = [
            makeCrossfaderEvent(value: 0, takeRelativeTime: 0, calibratedPosition: nil),
            makeCrossfaderEvent(value: 127, takeRelativeTime: 1, calibratedPosition: nil)
        ]
        let samples = ReferenceAuthoringCaptureBridge.crossfaderPositionSamples(from: events)
        XCTAssertEqual(samples[0].normalizedPosition, 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[1].normalizedPosition, 1.0, accuracy: 0.0001)
    }

    func testNeverMixesCalibratedAndUncalibratedSamplesInOneStream() {
        // Requirement #6: calibrated is authoritative; normalizedValue is an
        // EXPLICITLY MARKED diagnostic fallback only, never silently mixed
        // sample-by-sample with calibrated positions in the same stream.
        let events = [
            makeCrossfaderEvent(value: 0, takeRelativeTime: 0, calibratedPosition: 1.0),
            // This sample lost its calibration (e.g. mid-take recalibration) —
            // the WHOLE stream must fall back, not just this one sample.
            makeCrossfaderEvent(value: 64, takeRelativeTime: 1, calibratedPosition: nil)
        ]
        let samples = ReferenceAuthoringCaptureBridge.crossfaderPositionSamples(from: events)
        // Both samples must use the SAME coordinate system: since not every
        // sample is calibrated, both fall back to normalizedValue.
        XCTAssertEqual(samples[0].normalizedPosition, 0.0 / 127.0, accuracy: 0.0001)
        XCTAssertEqual(samples[1].normalizedPosition, 64.0 / 127.0, accuracy: 0.0001)
    }

    func testEmptyEventListProducesEmptySamples() {
        XCTAssertTrue(ReferenceAuthoringCaptureBridge.crossfaderPositionSamples(from: []).isEmpty)
    }

    // MARK: - observedCrossfaderAddress

    func testObservedAddressComesFromTheFirstCrossfaderEvent() {
        let events = [
            makeCrossfaderEvent(deviceName: "Rane ONE MKII", channel: 15, controller: 8)
        ]
        let address = ReferenceAuthoringCaptureBridge.observedCrossfaderAddress(from: events)
        XCTAssertEqual(address?.deviceIdentifier, "midi_rane_one_mk2")
        XCTAssertEqual(address?.channel, 15)
        XCTAssertEqual(address?.controller, 8)
    }

    func testNoCrossfaderEventsMeansNoObservedAddress() {
        XCTAssertNil(ReferenceAuthoringCaptureBridge.observedCrossfaderAddress(from: []))
    }

    // MARK: - autoDetectedTechnique: advisory mapping, never authoritative

    func testMapsATitleFormatDetectedLabel() {
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "Baby Scratch"),
            .babyScratch
        )
    }

    func testMappingIsCaseInsensitiveOnTitle() {
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "baby scratch"),
            .babyScratch
        )
    }

    func testMapsARawIDFormatDetectedLabelAsAFallback() {
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "chirp"),
            .chirp
        )
    }

    func testABareFlareLabelNeverMatchesAnyTechnique() {
        // No click count named — must not silently resolve to 1-click.
        XCTAssertNil(ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "Flare"))
        XCTAssertNil(ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "flare"))
    }

    func testAnExactFlareVariantLabelDoesMatch() {
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "2-Click Flare"),
            .flare(.twoClick)
        )
    }

    func testAnUnrecognisedLabelMapsToNil() {
        XCTAssertNil(ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "Some Unknown Move"))
    }

    func testNilAndEmptyLabelsMapToNil() {
        XCTAssertNil(ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: nil))
        XCTAssertNil(ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "   "))
    }

    // MARK: - Generation-correlated finalization

    func testInitialPreFinalizationWindowIsNotTreatedAsCompletion() {
        let token = RoutineRecordingRequestToken(generation: 1)
        let mediaURL = URL(fileURLWithPath: "/tmp/reference-take-001.mov")
        let completion = makeCompletion(
            token: token,
            takeID: "take-001",
            mediaURL: mediaURL
        )
        var poll = 0

        let result = ReferenceAuthoringCaptureBridge.waitForRoutineFinalization(
            token: token,
            timeout: 1,
            pollInterval: 0.01,
            readBoundary: {
                self.makeBoundary(
                    token: token,
                    takeID: "take-001",
                    mediaURL: mediaURL,
                    didEnterFinalization: poll >= 2,
                    completion: poll >= 2 ? completion : nil
                )
            },
            isCancelled: { false },
            now: { Double(poll) * 0.01 },
            wait: { _ in poll += 1 }
        )

        guard case .success(let finalized) = result else {
            return XCTFail("Expected the matching completion, got \(result)")
        }
        XCTAssertGreaterThanOrEqual(poll, 2, "The initial not-finalizing window must not complete the wait.")
        XCTAssertEqual(finalized.mediaURL, mediaURL)
    }

    func testPreviousGenerationAndURLCannotCompleteTheNewStop() {
        let previousToken = RoutineRecordingRequestToken(generation: 1)
        let expectedToken = RoutineRecordingRequestToken(generation: 2)
        let previousURL = URL(fileURLWithPath: "/tmp/reference-take-001.mov")
        let expectedURL = URL(fileURLWithPath: "/tmp/reference-take-002.mov")
        let previousCompletion = makeCompletion(
            token: previousToken,
            takeID: "take-001",
            mediaURL: previousURL
        )
        let expectedCompletion = makeCompletion(
            token: expectedToken,
            takeID: "take-002",
            mediaURL: expectedURL
        )
        var poll = 0

        let result = ReferenceAuthoringCaptureBridge.waitForRoutineFinalization(
            token: expectedToken,
            timeout: 1,
            pollInterval: 0.01,
            readBoundary: {
                if poll == 0 {
                    return self.makeBoundary(
                        token: previousToken,
                        takeID: "take-001",
                        mediaURL: previousURL,
                        didEnterFinalization: true,
                        completion: previousCompletion
                    )
                }
                return self.makeBoundary(
                    token: expectedToken,
                    takeID: "take-002",
                    mediaURL: expectedURL,
                    didEnterFinalization: true,
                    completion: expectedCompletion
                )
            },
            isCancelled: { false },
            now: { Double(poll) * 0.01 },
            wait: { _ in poll += 1 }
        )

        guard case .success(let finalized) = result else {
            return XCTFail("Expected the new generation to finalize, got \(result)")
        }
        XCTAssertEqual(poll, 1, "A previous terminal record must be ignored, not accepted.")
        XCTAssertEqual(finalized.token, expectedToken)
        XCTAssertEqual(finalized.takeID, "take-002")
        XCTAssertEqual(finalized.mediaURL, expectedURL)
        XCTAssertNotEqual(finalized.mediaURL, previousURL)
    }

    func testStopRequestIsCorrelatedWithTheCorrectLedgerGenerationAndTake() {
        let ledger = RoutineRecordingBoundaryLedger()
        let previousURL = URL(fileURLWithPath: "/tmp/reference-take-001.mov")
        let currentURL = URL(fileURLWithPath: "/tmp/reference-take-002.mov")

        let previousToken = ledger.beginRequest()
        ledger.prepare(token: previousToken, takeID: "take-001", mediaURL: previousURL)
        ledger.didStartRecording(mediaURL: previousURL)
        XCTAssertEqual(ledger.requestStop(token: previousToken), .accepted)
        ledger.enterFinalization(mediaURL: previousURL)
        let previousCompletion = ledger.completeFinalization(
            token: previousToken,
            succeeded: true,
            statusMessage: "Finalized take-001"
        )

        let currentToken = ledger.beginRequest()
        ledger.prepare(token: currentToken, takeID: "take-002", mediaURL: currentURL)
        ledger.didStartRecording(mediaURL: currentURL)

        XCTAssertEqual(
            ledger.requestStop(token: previousToken),
            previousCompletion.map(RoutineRecordingStopRequestDisposition.alreadyCompleted)
        )
        XCTAssertEqual(ledger.snapshot(for: currentToken)?.stopWasRequested, false)
        XCTAssertEqual(ledger.requestStop(token: currentToken), .accepted)
        let currentBoundary = ledger.snapshot(for: currentToken)
        XCTAssertEqual(currentBoundary?.takeID, "take-002")
        XCTAssertEqual(currentBoundary?.mediaURL, currentURL)
        XCTAssertEqual(currentBoundary?.stopWasRequested, true)
        XCTAssertNotEqual(previousToken, currentToken)
    }

    func testCompletionIsIgnoredUntilAuthoritativeFinalizationBoundaryExists() {
        let token = RoutineRecordingRequestToken(generation: 7)
        let mediaURL = URL(fileURLWithPath: "/tmp/reference-take-007.mov")
        let completion = makeCompletion(
            token: token,
            takeID: "take-007",
            mediaURL: mediaURL
        )
        var poll = 0

        let result = ReferenceAuthoringCaptureBridge.waitForRoutineFinalization(
            token: token,
            timeout: 1,
            pollInterval: 0.01,
            readBoundary: {
                self.makeBoundary(
                    token: token,
                    takeID: "take-007",
                    mediaURL: mediaURL,
                    didEnterFinalization: poll > 0,
                    completion: completion
                )
            },
            isCancelled: { false },
            now: { Double(poll) * 0.01 },
            wait: { _ in poll += 1 }
        )

        guard case .success = result else {
            return XCTFail("Expected completion after finalization entry, got \(result)")
        }
        XCTAssertEqual(poll, 1)
    }

    func testCancellationWhileWaitingExitsWithoutAcceptingAnArtifact() {
        let token = RoutineRecordingRequestToken(generation: 8)
        let mediaURL = URL(fileURLWithPath: "/tmp/reference-take-008.mov")
        var poll = 0

        let result = ReferenceAuthoringCaptureBridge.waitForRoutineFinalization(
            token: token,
            timeout: 30,
            pollInterval: 0.01,
            readBoundary: {
                self.makeBoundary(
                    token: token,
                    takeID: "take-008",
                    mediaURL: mediaURL,
                    didEnterFinalization: false
                )
            },
            isCancelled: { poll > 0 },
            now: { Double(poll) * 0.01 },
            wait: { _ in poll += 1 }
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation, got \(result)")
        }
        XCTAssertEqual(error.errorDescription, "Recording failed: Finalization wait was cancelled.")
        XCTAssertEqual(poll, 1)
    }

    func testTimeoutWhileFinalizationNeverCompletesReportsTheBoundedFailure() {
        let token = RoutineRecordingRequestToken(generation: 9)
        let mediaURL = URL(fileURLWithPath: "/tmp/reference-take-009.mov")
        var elapsed: TimeInterval = 0

        let result = ReferenceAuthoringCaptureBridge.waitForRoutineFinalization(
            token: token,
            timeout: 0.05,
            pollInterval: 0.01,
            readBoundary: {
                self.makeBoundary(
                    token: token,
                    takeID: "take-009",
                    mediaURL: mediaURL,
                    didEnterFinalization: true
                )
            },
            isCancelled: { false },
            now: { elapsed },
            wait: { elapsed += $0 }
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected timeout, got \(result)")
        }
        XCTAssertEqual(
            error.errorDescription,
            "Recording failed: Finalization did not complete within 0.05s."
        )
    }

    // MARK: - Main-thread misuse guard (start/stop)

    func testStartRecordingOnTheMainThreadFailsLoudlyInsteadOfDeadlocking() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)
        bridge.setPendingConfiguration(
            ReferenceAuthoringBridgeTakeConfiguration(technique: .babyScratch, bpm: 95)
        )
        // This test method runs on the main thread by default, which is
        // exactly the misuse case being verified — a real deadlock here would
        // hang the test runner rather than fail it, so a clean synchronous
        // `.failure` result IS the proof there is no deadlock.
        let result = bridge.hooks.startRecording()
        guard case .failure(let error) = result else {
            return XCTFail("Expected a main-thread-misuse failure, got \(result)")
        }
        XCTAssertTrue(
            error.errorDescription?.contains("must not be called from the main thread") ?? false,
            error.errorDescription ?? ""
        )
    }

    func testStopRecordingOnTheMainThreadFailsLoudlyInsteadOfDeadlocking() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)
        let result = bridge.hooks.stopRecording()
        guard case .failure(let error) = result else {
            return XCTFail("Expected a main-thread-misuse failure, got \(result)")
        }
        XCTAssertTrue(
            error.errorDescription?.contains("must not be called from the main thread") ?? false,
            error.errorDescription ?? ""
        )
    }

    func testCurrentPreflightSnapshotOnTheMainThreadFailsSoftRatherThanDeadlocking() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)
        // Same misuse case as above, but this hook returns a plain value
        // rather than a Result, so the proof of no-deadlock is that this line
        // returns at all, synchronously, with the documented safe fallback.
        let snapshot = bridge.hooks.currentPreflightSnapshot()
        XCTAssertEqual(snapshot, ReferenceAuthoringCaptureBridge.disconnectedSnapshot)
        XCTAssertTrue(ReferenceCapturePreflight.evaluate(
            snapshot: snapshot,
            technique: .babyScratch
        ).blocksRecording, "A disconnected snapshot must never allow recording.")
    }

    func testLatestCalibrationObservationOnTheMainThreadReturnsNilRatherThanDeadlocking() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)
        XCTAssertNil(bridge.hooks.latestCalibrationObservation())
    }

    // MARK: - Missing configuration

    func testStartRecordingWithoutAPendingConfigurationFailsBeforeTouchingTheEngine() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)

        let expectation = expectation(description: "startRecording returns off the main thread")
        var result: Result<Void, ReferenceAuthoringError>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = bridge.hooks.startRecording()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .failure(let error) = result else {
            return XCTFail("Expected a missing-configuration failure, got \(String(describing: result))")
        }
        XCTAssertTrue(
            error.errorDescription?.contains("No take configuration was set") ?? false,
            error.errorDescription ?? ""
        )
        // Never armed a config on the engine, since the check runs first.
        XCTAssertNil(engine.recordingSessionConfig)
    }

    // MARK: - Live preflight, real (isolated) engine, off the main thread

    func testPreflightOnAFreshEngineWithNothingSelectedIsAllBlockedOrAdvisory() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)

        let expectation = expectation(description: "preflight snapshot off the main thread")
        var snapshot: ReferencePreflightSnapshot?
        DispatchQueue.global(qos: .userInitiated).async {
            snapshot = bridge.hooks.currentPreflightSnapshot()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard let snapshot else { return XCTFail("No snapshot produced.") }
        XCTAssertNil(snapshot.controllerName)
        XCTAssertNil(snapshot.controllerIdentifier)
        XCTAssertNil(snapshot.observedCrossfaderAddress)
        XCTAssertNil(snapshot.calibration)
        XCTAssertNil(snapshot.cameraDeviceName)
        XCTAssertFalse(snapshot.cameraIsActive)
        XCTAssertFalse(snapshot.watchIsReachable, "MacCaptureEngine tracks no Watch state; the bridge must not fabricate connectivity.")
        XCTAssertTrue(
            ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .chirp).blocksRecording
        )
    }

    func testLatestCalibrationObservationOnAFreshEngineIsNilOffTheMainThread() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine)

        let expectation = expectation(description: "latest calibration observation off the main thread")
        var capturedValue: CrossfaderCalibrationObservation?
        var didRun = false
        DispatchQueue.global(qos: .userInitiated).async {
            // No crossfader mapping has been learned on a fresh engine, so
            // this must be nil rather than falling back to whatever address
            // last moved — the platter's CC6 stream is not a crossfader.
            capturedValue = bridge.hooks.latestCalibrationObservation()
            didRun = true
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(didRun)
        XCTAssertNil(capturedValue)
    }

    // MARK: - Paired Watch start handshake (2026-09-04 hardware-smoke repair)

    /// Missing optional Watch hardware must not mask a real setup failure.
    func testStartWithoutWatchStillRequiresPreparedBackingSound() {
        let engine = makeIsolatedEngine()
        let bridge = ReferenceAuthoringCaptureBridge(engine: engine, companionReceiver: nil)
        bridge.setPendingConfiguration(
            ReferenceAuthoringBridgeTakeConfiguration(
                technique: .babyScratch,
                bpm: 95,
                handedness: .right,
                notes: ""
            )
        )

        let expectation = expectation(description: "startRecording returns off the main thread")
        var result: Result<Void, ReferenceAuthoringError>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = bridge.hooks.startRecording()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        guard case .failure(let error) = result else {
            return XCTFail("Expected a refusal, got \(String(describing: result))")
        }
        XCTAssertTrue(
            error.errorDescription?.contains("Prepare the backing sound") ?? false,
            error.errorDescription ?? ""
        )
        XCTAssertNil(
            engine.recordingSessionConfig,
            "The refusal must land before any take configuration is armed on the engine."
        )
    }

    func testAbsentRelayReturnsUnavailableDiagnosticReplyWithoutStartingHardware() throws {
        let engine = makeIsolatedEngine()
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let outcome = ReferenceAuthoringCaptureBridge.performWatchStartHandshake(
            engine: engine, receiver: nil, identity: identity, watchWrist: "right",
            timeout: 1, pollInterval: 0.001, isCancelled: { false }
        )
        let reply = try outcome.replyForDiagnosticCapture(identity: identity).get()
        XCTAssertEqual(reply.syncState, .unavailable)
        XCTAssertEqual(reply.sessionID, identity.sessionID)
        XCTAssertEqual(reply.takeID, identity.takeID)
        XCTAssertNil(reply.acknowledgedAt)
        XCTAssertNil(engine.watchOwnedTakeIdentity)
    }

    func testDegradedWatchRepliesKeepExactFailureInPersistedDiagnosticEvidence() throws {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let failed = WatchCaptureControlReply(commandID: "failed-command", sessionID: identity.sessionID,
            takeID: identity.takeID, syncState: .failed, detail: "Relay could not send start.")
        let outcomes: [ReferenceAuthoringCaptureBridge.WatchStartHandshakeOutcome] = [
            .unavailable, .timedOut, .notAcknowledged(failed)
        ]
        let expected: [CaptureWatchSyncState] = [.unavailable, .timedOut, .failed]
        for (outcome, state) in zip(outcomes, expected) {
            let reply = try outcome.replyForDiagnosticCapture(identity: identity).get()
            let sidecar = makeSidecar(watchSyncState: .notRequested, linkedMotionCaptureID: nil)
                .withWatchSync(reply)
            let restored = try JSONDecoder().decode(CaptureCore.LocalRecordingSidecar.self,
                from: JSONEncoder().encode(sidecar))
            XCTAssertEqual(restored.watchSyncState, state)
            XCTAssertEqual(restored.watchCommandID, reply.commandID)
            XCTAssertNil(restored.watchAcknowledgedAt)
            XCTAssertNil(restored.linkedMotionCaptureID)
            guard case .missing(let syncState) = ReferenceAuthoringCaptureBridge.watchEvidence(
                in: restored, expectedIdentity: identity
            ) else { return XCTFail("A degraded start must not claim motion or wait for an acknowledged transfer.") }
            XCTAssertEqual(syncState, state.rawValue)
        }
    }

    func testAcknowledgedWatchReplyAndCommandIdentityArePreserved() throws {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let acknowledged = WatchCaptureControlReply(commandID: "actual-command", sessionID: identity.sessionID,
            takeID: identity.takeID, syncState: .acknowledged, detail: "Started", acknowledgedAt: Date())
        XCTAssertEqual(try ReferenceAuthoringCaptureBridge.WatchStartHandshakeOutcome.acknowledged(acknowledged)
            .replyForDiagnosticCapture(identity: identity).get(), acknowledged)
    }

    func testMismatchedWatchAcknowledgementCannotApproveAnotherTake() throws {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let stale = WatchCaptureControlReply(commandID: "stale-command", sessionID: "older-session",
            takeID: "take-002", syncState: .acknowledged, detail: "Started", acknowledgedAt: Date())
        let reply = try ReferenceAuthoringCaptureBridge.WatchStartHandshakeOutcome.acknowledged(stale)
            .replyForDiagnosticCapture(identity: identity).get()
        XCTAssertEqual(reply.syncState, .failed)
        XCTAssertEqual(reply.sessionID, identity.sessionID)
        XCTAssertEqual(reply.takeID, identity.takeID)
        XCTAssertNil(reply.acknowledgedAt)
    }

    func testExplicitStartCancellationStillRefusesDiagnosticRecording() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        XCTAssertThrowsError(try ReferenceAuthoringCaptureBridge.WatchStartHandshakeOutcome.cancelled
            .replyForDiagnosticCapture(identity: identity).get())
    }

    @MainActor
    func testLateWatchAcknowledgementStopsOnlyOriginalTakeAfterTimeout() {
        assertLateWatchReplyCleanup(cancelled: false)
    }

    @MainActor
    func testLateWatchAcknowledgementStopsOnlyOriginalTakeAfterCancellation() {
        assertLateWatchReplyCleanup(cancelled: true)
    }

    @MainActor
    private func assertLateWatchReplyCleanup(cancelled: Bool) {
        let engine = makeIsolatedEngine()
        let original = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let newer = TakeIdentity(sessionID: "session-b", takeID: "take-002", takeNumber: 2)
        let lateReply = WatchCaptureControlReply(commandID: "original-command", sessionID: original.sessionID,
            takeID: original.takeID, syncState: .acknowledged, detail: "Started", acknowledgedAt: Date())
        let releaseReply = DispatchSemaphore(value: 0)
        defer { releaseReply.signal() }
        let requestStarted = expectation(description: "Watch request entered")
        let settled = expectation(description: "bounded handshake returned")
        let stopped = expectation(description: "original Watch take stopped")
        let requestEntered = DispatchSemaphore(value: 0)
        engine.watchStopRequestHandler = { identity in
            XCTAssertEqual(identity.sessionID, original.sessionID)
            XCTAssertEqual(identity.takeID, original.takeID)
            stopped.fulfill()
            return WatchCaptureControlReply(commandID: "stop-original", sessionID: identity.sessionID,
                takeID: identity.takeID, syncState: .notRequested, detail: "Stopped", stopOutcome: .stopped)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ReferenceAuthoringCaptureBridge.waitForWatchStartReply(
                engine: engine, identity: original, timeout: 0.1, pollInterval: 0.001,
                isCancelled: { cancelled && requestEntered.wait(timeout: .now()) == .success }, requestStart: {
                    requestEntered.signal()
                    requestStarted.fulfill()
                    return await withCheckedContinuation { continuation in
                        DispatchQueue.global().async {
                            releaseReply.wait()
                            continuation.resume(returning: lateReply)
                        }
                    }
                }
            )
            switch outcome {
            case .cancelled: XCTAssertTrue(cancelled)
            case .timedOut: XCTAssertFalse(cancelled)
            default: XCTFail("Expected abandoned start, got \(outcome)")
            }
            settled.fulfill()
        }
        wait(for: [requestStarted, settled], timeout: 2)
        engine.applyPendingWatchReply(WatchCaptureControlReply(commandID: "newer-command",
            sessionID: newer.sessionID, takeID: newer.takeID, syncState: .acknowledged, detail: "Started"))
        releaseReply.signal()
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(engine.watchOwnedTakeIdentity?.sessionID, newer.sessionID)
        XCTAssertEqual(engine.watchOwnedTakeIdentity?.takeID, newer.takeID)
        XCTAssertNil(engine.requestWatchStop(for: original, reason: .interrupted),
            "The late handshake must stop its original identity at most once.")
    }

    // MARK: - watchLinked is read from the finalized take, never assumed

    private func makeSidecar(
        sessionID: String = "session-a",
        takeID: String = "take-001",
        watchSyncState: CaptureWatchSyncState,
        linkedMotionCaptureID: UUID?,
        linkedMotionFileName: String? = nil,
        stopDiagnostics: CaptureWatchStopDiagnostics? = nil,
        captureTiming: CaptureTimingMetadata? = nil,
        sessionConfig: CaptureSessionConfig? = nil
    ) -> CaptureCore.LocalRecordingSidecar {
        CaptureCore.LocalRecordingSidecar(
            sessionID: sessionID,
            sessionConfig: sessionConfig,
            takeID: takeID,
            appLocalTakeNumber: 1,
            recordingRole: "mac_routine_capture",
            platform: "macOS",
            appSurface: "ScratchLab Routine Recorder",
            sourceDeviceName: "DJ",
            captureTiming: captureTiming,
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            recordingStatus: "completed",
            mediaFileName: "\(sessionID)_\(takeID)_routine.mov",
            sidecarFileName: "\(sessionID)_\(takeID)_routine.json",
            watchSyncState: watchSyncState,
            watchStopDiagnostics: stopDiagnostics,
            linkedMotionCaptureID: linkedMotionCaptureID,
            linkedMotionFileName: linkedMotionFileName
        )
    }

    // MARK: - Watch evidence is a STATE, matched to one identity

    private func makeStopDiagnostics(
        sessionID: String = "session-a",
        takeID: String = "take-001",
        transfer: CaptureWatchMotionTransferState
    ) -> CaptureWatchStopDiagnostics {
        CaptureWatchStopDiagnostics(
            outcome: .stopped,
            sessionID: sessionID,
            takeID: takeID,
            detail: "Watch motion capture stopped.",
            motionTransferState: transfer
        )
    }

    /// The 2026-09-05 take-003 state exactly: acknowledged on the reserved
    /// identity, stopped cleanly, motion file still transferring. This must be
    /// PENDING, not missing — reporting it as missing made a working Watch
    /// look failed and left the take permanently un-approvable.
    func testAcknowledgedWithATransferStillInFlightIsPendingNotMissing() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(
                watchSyncState: .acknowledged,
                linkedMotionCaptureID: nil,
                stopDiagnostics: makeStopDiagnostics(transfer: .pending)
            ),
            expectedIdentity: identity
        )
        XCTAssertEqual(evidence, .acknowledgedTransferPending)
        XCTAssertFalse(evidence.isLinked)
        XCTAssertFalse(evidence.isTerminal, "a pending transfer must keep the wait alive")
    }

    func testUnreachableWatchStopExplainsManualRecoveryWithoutLosingMacCapture() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(watchSyncState: .acknowledged, linkedMotionCaptureID: nil,
                stopDiagnostics: CaptureWatchStopDiagnostics(outcome: .unreachable,
                    sessionID: identity.sessionID, takeID: identity.takeID,
                    motionTransferState: .notApplicable)),
            expectedIdentity: identity)
        guard case .transferFailed(let detail) = evidence else { return XCTFail("Stop was not confirmed.") }
        XCTAssertTrue(detail.contains("press Stop"))
        XCTAssertTrue(detail.contains("Mac recording is retained"))
        XCTAssertTrue(evidence.isTerminal)
        XCTAssertFalse(evidence.isLinked)
    }

    func testAMatchingTransferThatLandsBecomesLinked() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(
                watchSyncState: .acknowledged,
                linkedMotionCaptureID: UUID(),
                linkedMotionFileName: "scratch-motion.json",
                stopDiagnostics: makeStopDiagnostics(transfer: .completed)
            ),
            expectedIdentity: identity
        )
        XCTAssertEqual(evidence, .linked(motionFileName: "scratch-motion.json"))
        XCTAssertTrue(evidence.isLinked)
        XCTAssertTrue(evidence.isTerminal)
    }

    func testATransferReportedCompleteWithNothingLinkedIsAFailureNotASuccess() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(
                watchSyncState: .acknowledged,
                linkedMotionCaptureID: nil,
                stopDiagnostics: makeStopDiagnostics(transfer: .completed)
            ),
            expectedIdentity: identity
        )
        guard case .transferFailed = evidence else {
            return XCTFail("expected .transferFailed, got \(evidence)")
        }
        XCTAssertTrue(evidence.isTerminal)
    }

    func testAnUnacknowledgedStartIsMissingRatherThanPending() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(watchSyncState: .timedOut, linkedMotionCaptureID: nil),
            expectedIdentity: identity
        )
        XCTAssertEqual(evidence, .missing(syncState: "timedOut"))
        XCTAssertTrue(evidence.isTerminal, "nothing will arrive for a start that never acknowledged")
    }

    func testTheExact20260904StateIsReportedMissing() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        // takes 001/002 of the preserved failed session: notRequested, no link.
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(watchSyncState: .notRequested, linkedMotionCaptureID: nil),
            expectedIdentity: identity
        )
        XCTAssertEqual(evidence, .missing(syncState: "notRequested"))
    }

    func testEvidenceNamingAnotherTakeIsNeverAttached() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        for sidecar in [
            makeSidecar(takeID: "take-002", watchSyncState: .acknowledged, linkedMotionCaptureID: UUID()),
            makeSidecar(sessionID: "session-b", watchSyncState: .acknowledged, linkedMotionCaptureID: UUID())
        ] {
            let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
                in: sidecar,
                expectedIdentity: identity
            )
            guard case .identityMismatch = evidence else {
                return XCTFail("expected .identityMismatch, got \(evidence)")
            }
            XCTAssertFalse(evidence.isLinked)
        }
    }

    /// A stop handshake that resolved against a DIFFERENT take must not lend
    /// its evidence to this one, even when the sidecar's own identity matches.
    func testAStopHandshakeForAnotherTakeIsAMismatch() {
        let identity = TakeIdentity(sessionID: "session-a", takeID: "take-001", takeNumber: 1)
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(
                watchSyncState: .acknowledged,
                linkedMotionCaptureID: nil,
                stopDiagnostics: makeStopDiagnostics(takeID: "take-009", transfer: .pending)
            ),
            expectedIdentity: identity
        )
        guard case .identityMismatch = evidence else {
            return XCTFail("expected .identityMismatch, got \(evidence)")
        }
    }

    func testWithNoReservedIdentityNothingIsAttached() {
        let evidence = ReferenceAuthoringCaptureBridge.watchEvidence(
            in: makeSidecar(watchSyncState: .acknowledged, linkedMotionCaptureID: UUID()),
            expectedIdentity: nil
        )
        XCTAssertFalse(evidence.isLinked, "with nothing to match against, fail closed")
    }

    /// Commit d3ecf2a6 made `MacCaptureEngine.watchStopRequestHandler` the
    /// SINGLE authority for stopping a paired Watch capture, across every
    /// terminal path of a take. Authoring may start one; it must never send a
    /// stop of its own, or a take could be stopped twice from two owners.
    func testTheBridgeNeverSendsAWatchStopItself() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Services/ReferenceAuthoringCaptureBridge.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("requestWatchCaptureStop"),
            "The engine's watchStopRequestHandler is the single stop authority (d3ecf2a6)."
        )
        XCTAssertTrue(
            source.contains("requestWatchCaptureStart"),
            "Authoring must use the established Capture start command, not a parallel protocol."
        )
    }
}

// MARK: - Take-start crossfader control state (engine side + sidecar schema)

/// The engine-owned observation, its correlation identities, and the
/// backward-compatible sidecar record that carries it.
///
/// Everything here is synthetic. No Core MIDI, no camera, no capture session,
/// and no physical take is read, altered, approved or promoted.
final class CrossfaderTakeStartStateTests: XCTestCase {

    private func observation(
        deviceName: String = "Rane ONE MKII",
        channel: Int = 15,
        controller: Int = 8,
        value: Int = 127,
        calibratedPosition: Double? = 1,
        observedAt: CFTimeInterval = 99.6,
        eventCount: Int = 412,
        connectionGeneration: UInt64 = 3,
        calibrationID: String? = "Rane ONE MKII#15#8"
    ) -> MacCaptureEngine.LiveCCObservation {
        MacCaptureEngine.LiveCCObservation(
            deviceName: deviceName,
            channel: channel,
            controller: controller,
            value: value,
            calibratedPosition: calibratedPosition,
            observedAt: observedAt,
            eventCount: eventCount,
            connectionGeneration: connectionGeneration,
            calibrationID: calibrationID
        )
    }

    private func classify(
        sessionID: String? = "session-008",
        takeID: String? = "take-008",
        takeGeneration: UInt64? = 8,
        midiSourceID: String = "midi_rane_one_mkii",
        connectionGeneration: UInt64 = 3,
        mapping: MacCaptureEngine.CrossfaderCCMapping? = MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8),
        observation: MacCaptureEngine.LiveCCObservation?,
        mediaStartHostTime: CFTimeInterval = 100.0
    ) -> CaptureCore.CrossfaderTakeStartState {
        MacCaptureEngine.crossfaderTakeStartState(
            sessionID: sessionID,
            takeID: takeID,
            takeGeneration: takeGeneration,
            midiSourceID: midiSourceID,
            connectionGeneration: connectionGeneration,
            mapping: mapping,
            observation: observation,
            mediaStartHostTime: mediaStartHostTime
        )
    }

    /// The take-008 shape: a fader parked hard open, last message 0.4 s before
    /// media start, nothing during the take at all.
    func testAParkedFaderIsRecordedAsAPreTakeSnapshotWithItsOriginalTime() {
        let state = classify(observation: observation())
        XCTAssertEqual(state.provenance, .preTakeSnapshot)
        XCTAssertTrue(state.isUsableSnapshot)
        XCTAssertEqual(state.rawValue, 127)
        XCTAssertEqual(state.channel, 15)
        XCTAssertEqual(state.controller, 8)
        XCTAssertEqual(state.calibrationID, "Rane ONE MKII#15#8")
        XCTAssertEqual(state.midiConnectionGeneration, 3)
        XCTAssertEqual(state.takeGeneration, 8)
        XCTAssertEqual(state.observationSequence, 412)
        // Its ORIGINAL instant, preserved and negative — never rewritten to 0
        // and never presented as an in-take packet.
        XCTAssertEqual(try XCTUnwrap(state.observedTakeRelativeTime), -0.4, accuracy: 1e-9)
        XCTAssertNil(state.unknownReason)
    }

    func testAbsentEvidenceIsRecordedAsExplicitUnknownRatherThanInvented() throws {
        let noObservation = classify(observation: nil)
        XCTAssertEqual(noObservation.provenance, .unknown)
        XCTAssertNil(noObservation.rawValue)
        XCTAssertNotNil(noObservation.unknownReason)
        XCTAssertFalse(noObservation.isUsableSnapshot)

        let noMapping = classify(mapping: nil, observation: observation())
        XCTAssertEqual(noMapping.provenance, .unknown)

        let noSource = classify(midiSourceID: "", observation: observation())
        XCTAssertEqual(noSource.provenance, .unknown)

        let noIdentity = classify(takeID: nil, observation: observation())
        XCTAssertEqual(noIdentity.provenance, .unknown)
    }

    func testAnObservationFromAPreviousDeviceConnectionIsNotAdopted() {
        let state = classify(observation: observation(connectionGeneration: 2))
        XCTAssertEqual(state.provenance, .unknown)
        XCTAssertEqual(
            state.unknownReason,
            "the cached observation predates the current MIDI device connection"
        )
    }

    func testAnObservationOnADifferentAddressIsNotAdopted() {
        let state = classify(observation: observation(channel: 0, controller: 6))
        XCTAssertEqual(state.provenance, .unknown)
        XCTAssertEqual(state.unknownReason, "the cached observation is not on the learned crossfader address")
    }

    // MARK: The recording-start reconnect must not retire a parked observation

    private func endpoint(
        sourceID: String = "midi_rane_one_mkii",
        endpointRef: MIDIEndpointRef = 4_210
    ) -> MacCaptureEngine.MIDIConnectionEndpointIdentity {
        MacCaptureEngine.MIDIConnectionEndpointIdentity(sourceID: sourceID, endpointRef: endpointRef)
    }

    /// Recording start closes and reopens the input port on purpose
    /// (`openMIDIInputForRecording`), and so does finalization. Both target
    /// the SAME endpoint of the SAME selected source, so neither changes
    /// anything an earlier reading was correlated against, and neither may
    /// retire it.
    func testASameEndpointInternalReconnectDoesNotAdvanceTheConnectionGeneration() {
        XCTAssertEqual(
            MacCaptureEngine.nextMIDIConnectionGeneration(
                current: 3,
                previous: endpoint(),
                next: endpoint()
            ),
            3
        )
    }

    /// Take 008's exact failure, now passing.
    ///
    /// The fader was parked hard open before recording, the operator correctly
    /// touched nothing, and recording start reconnected MIDI. The snapshot
    /// survives on the evidence that was genuinely there — no CC8 event is
    /// invented to carry it.
    func testAParkedObservationSurvivesTheRecordingStartReconnect() throws {
        let generationAtMediaStart = MacCaptureEngine.nextMIDIConnectionGeneration(
            current: 3,
            previous: endpoint(),
            next: endpoint()
        )
        let state = classify(
            connectionGeneration: generationAtMediaStart,
            observation: observation(connectionGeneration: 3)
        )
        XCTAssertEqual(state.provenance, .preTakeSnapshot)
        XCTAssertEqual(state.rawValue, 127)
        XCTAssertNil(state.unknownReason)
        // The ORIGINAL negative instant, preserved — never re-timed to media
        // start and never presented as an in-take packet.
        XCTAssertEqual(try XCTUnwrap(state.observedTakeRelativeTime), -0.4, accuracy: 1e-9)
        // The generation it records is the one still open, so the stop-time
        // correlation in `ReferenceCrossfaderTakeStart.correlate` matches too.
        XCTAssertEqual(state.midiConnectionGeneration, 3)
    }

    /// Every way the device session can ACTUALLY change still fails closed.
    func testAGenuineConnectionChangeAdvancesTheGenerationAndRetiresTheObservation() {
        // Unplug/replug: same source name and identifier, but Core MIDI mints
        // a fresh endpoint reference for the new device session.
        let replugged = MacCaptureEngine.nextMIDIConnectionGeneration(
            current: 3,
            previous: endpoint(),
            next: endpoint(endpointRef: 4_211)
        )
        XCTAssertEqual(replugged, 4)
        // A different controller selected entirely.
        let replacedSource = MacCaptureEngine.nextMIDIConnectionGeneration(
            current: 3,
            previous: endpoint(),
            next: endpoint(sourceID: "midi_ddj_grv6")
        )
        XCTAssertEqual(replacedSource, 4)
        // The selection resolved to no endpoint at all — a genuine disconnect.
        XCTAssertEqual(
            MacCaptureEngine.nextMIDIConnectionGeneration(
                current: 3,
                previous: endpoint(),
                next: nil
            ),
            4
        )
        // Absent identity on either side is a change, never a match: the very
        // first connect of the process advances too.
        XCTAssertEqual(
            MacCaptureEngine.nextMIDIConnectionGeneration(current: 0, previous: nil, next: endpoint()),
            1
        )

        // ...and the classifier refuses the now-stale observation at each one.
        for advanced in [replugged, replacedSource] {
            let state = classify(
                connectionGeneration: advanced,
                observation: observation(connectionGeneration: 3)
            )
            XCTAssertEqual(state.provenance, .unknown)
            XCTAssertEqual(
                state.unknownReason,
                "the cached observation predates the current MIDI device connection"
            )
        }
    }

    /// A message that landed at or after media start belongs to the take's own
    /// MIDI stream. Duplicating it here would create a second, contradictory
    /// claim about the same instant.
    func testAnInTakeMessageIsNotDuplicatedAsAPreTakeSnapshot() {
        let state = classify(observation: observation(observedAt: 100.25))
        XCTAssertEqual(state.provenance, .unknown)
        XCTAssertEqual(
            state.unknownReason,
            "an in-take crossfader message already establishes this take's start"
        )
    }

    // MARK: Sidecar schema: additive, backward compatible

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func makeSidecar(
        takeStartState: CaptureCore.CrossfaderTakeStartState? = nil
    ) -> CaptureCore.LocalRecordingSidecar {
        CaptureCore.LocalRecordingSidecar(
            sessionID: "session-008",
            takeID: "take-008",
            appLocalTakeNumber: 8,
            recordingRole: "mac_routine_capture",
            platform: "macOS",
            appSurface: "ScratchLab Routine Recorder",
            sourceDeviceName: "DJ",
            startedAt: Date(timeIntervalSince1970: 1_788_000_000),
            recordingStatus: "completed",
            mediaFileName: "session-008_take-008_routine.mov",
            sidecarFileName: "session-008_take-008_routine.json",
            crossfaderTakeStartState: takeStartState
        )
    }

    func testASidecarWrittenBeforeThisFieldExistedStillDecodes() throws {
        // The exact document shape a pre-existing take carries: no
        // `crossfaderTakeStartState` key at all.
        let legacy = """
        {
          "schemaVersion": "scratchlab_local_recording_sidecar_v1",
          "sessionID": "session-007",
          "takeID": "take-007",
          "appLocalTakeNumber": 7,
          "recordingRole": "mac_routine_capture",
          "platform": "macOS",
          "appSurface": "ScratchLab Routine Recorder",
          "sourceDeviceName": "DJ",
          "startedAt": "2026-09-05T00:00:00Z",
          "recordingStatus": "completed",
          "mediaFileName": "session-007_take-007_routine.mov",
          "sidecarFileName": "session-007_take-007_routine.json",
          "watchSyncState": "notRequested",
          "auditTrail": []
        }
        """
        let sidecar = try Self.decoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(sidecar.takeID, "take-007")
        XCTAssertNil(
            sidecar.crossfaderTakeStartState,
            "An absent field means NOT RECORDED, never an observed unknown position."
        )
    }

    func testTheTakeStartRecordRoundTripsThroughTheSidecar() throws {
        let state = classify(observation: observation())
        let data = try makeSidecar(takeStartState: state).encodedData()
        let decoded = try Self.decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)
        XCTAssertEqual(decoded.crossfaderTakeStartState, state)
        XCTAssertEqual(decoded.crossfaderTakeStartState?.schemaVersion, 1)

        // It lives BESIDE the detected notation, never inside it: a pre-take
        // snapshot is not one of the take's measured mixer MIDI events.
        XCTAssertNil(decoded.detectedNotation)
    }

    func testARecordFromAFutureSchemaIsRefusedRatherThanReinterpreted() {
        let state = CaptureCore.CrossfaderTakeStartState(
            schemaVersion: CaptureCore.CrossfaderTakeStartState.currentSchemaVersion + 1,
            provenance: .preTakeSnapshot,
            sessionID: "session-008",
            takeID: "take-008",
            takeGeneration: 8,
            midiSourceID: "midi_rane_one_mkii",
            deviceName: "Rane ONE MKII",
            midiConnectionGeneration: 3,
            channel: 15,
            controller: 8,
            rawValue: 127,
            calibratedPosition: 1,
            calibrationID: "Rane ONE MKII#15#8",
            observationSequence: 412,
            observedTakeRelativeTime: -0.4,
            unknownReason: nil
        )
        XCTAssertFalse(state.isUsableSnapshot)
        let outcome = ReferenceCrossfaderTakeStart.correlate(
            state,
            against: ReferenceCrossfaderTakeStart.Correlation(
                sessionID: "session-008",
                takeID: "take-008",
                takeGeneration: 8,
                midiSourceID: "midi_rane_one_mkii",
                midiConnectionGeneration: 3
            ),
            calibration: nil,
            recordedSamples: []
        )
        XCTAssertEqual(outcome, .rejected(.unsupportedSchema))
    }

    // MARK: Tear reaches the capture pipeline as Tear

    func testATearSetupCarriesTearIntoTheCapturePipelineConfiguration() {
        let configuration = ReferenceAuthoringBridgeTakeConfiguration(
            technique: .tear,
            bpm: 95,
            handedness: .right,
            notes: "tear reference"
        )
        // This is the exact value the bridge writes into
        // `MacCaptureEngine.recordingSessionConfig.scratchType`, and therefore
        // into the finalized sidecar's session config.
        XCTAssertEqual(configuration.technique.scratchType, .tear)
        XCTAssertEqual(configuration.technique.scratchType.rawValue, "tear")
        XCTAssertEqual(configuration.technique.scratchType.title, "Tear")
        // Never Baby Scratch as a fallback.
        XCTAssertNotEqual(configuration.technique.scratchType, .babyScratch)
    }

    func testAdvisoryDetectionOfBabyDoesNotProduceATechniqueSelection() {
        // The bridge maps a detected LABEL to an advisory technique. It is
        // read beside the operator's selection and never written into it.
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "Baby Scratch"),
            .babyScratch
        )
        XCTAssertEqual(
            ReferenceAuthoringCaptureBridge.autoDetectedTechnique(fromDetectedLabel: "Tear"),
            .tear
        )
    }

}
