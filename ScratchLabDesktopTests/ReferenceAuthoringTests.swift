// ReferenceAuthoringTests.swift
// ScratchLabDesktopTests
//
// Pure-model tests for reference authoring: technique requirements, take
// validation, lifecycle, the registry's refusal to fall back to deprecated
// assets, call-and-response scheduling, and package model validation.
//
// No CoreMIDI, no capture engine, no audio. Every artifact measurement is
// supplied as data, which is what lets the whole rule set be exercised without
// a controller or a take on disk.

import AVFoundation
import XCTest
@testable import ScratchLab

final class ReferenceExactBeatExportTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testBoundStemUsesPlayedLoopFramesAndConvertsToCapturedSampleRate() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .minimalFunk, bpm: 95, loopBeats: 4, rootURL: root)
        let loop = try ScratchLabBeatEngine.loadPreparedPlayback(preparedBeat: prepared, mode: prepared.mode, bpm: 95).loopBuffer
        let offset = Double(prepared.binding.countInFrameCount) / 48_000
        let frames = loop.frameLength + 256
        let stem = try SessionArchiveBuilder.renderedBoundBeatStem(binding: prepared.binding, beatRootURL: root,
            recordingStartOffsetSeconds: offset, outputFormat: loop.format, frameCount: frames)
        XCTAssertEqual(stem.frameLength, frames)
        for channel in 0..<2 {
            XCTAssertEqual(Data(bytes: stem.floatChannelData![channel], count: Int(loop.frameLength) * MemoryLayout<Float>.size),
                Data(bytes: loop.floatChannelData![channel], count: Int(loop.frameLength) * MemoryLayout<Float>.size))
            XCTAssertEqual(Data(bytes: stem.floatChannelData![channel] + Int(loop.frameLength), count: 256 * MemoryLayout<Float>.size),
                Data(bytes: loop.floatChannelData![channel], count: 256 * MemoryLayout<Float>.size))
        }
        let format441 = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let converted = try SessionArchiveBuilder.renderedBoundBeatStem(binding: prepared.binding, beatRootURL: root,
            recordingStartOffsetSeconds: offset, outputFormat: format441, frameCount: 44_100)
        XCTAssertEqual(converted.frameLength, 44_100)
        XCTAssertTrue((0..<Int(converted.frameLength)).contains { abs(converted.floatChannelData![0][$0]) > 0.01 })
        XCTAssertLessThanOrEqual(ScratchLabBeatEngine.GeneratedAudioHeadroom.peakAmplitude(of: converted),
            ScratchLabBeatEngine.GeneratedAudioHeadroom.amplitude(forDBFS: -1.0),
            "Resampling must preserve the existing exported generated-stem headroom contract.")
        let invalidOffsets: [Double?] = [nil, .nan, offset + 1]
        for invalid in invalidOffsets {
            XCTAssertThrowsError(try SessionArchiveBuilder.renderedBoundBeatStem(binding: prepared.binding, beatRootURL: root,
                recordingStartOffsetSeconds: invalid, outputFormat: loop.format, frameCount: 100))
        }
    }

    func testExactPackageReopensWithoutOriginalLibraryAndRejectsChangedBinding() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 95, loopBeats: 4, rootURL: library)
        let beat = prepared.binding
        let watch = watchFixture()
        let watchData = try WatchMotionCaptureCodec.encoder.encode(watch)
        let sidecar = CaptureCore.LocalRecordingSidecar(sessionID: "session",
            sessionConfig: CaptureSessionConfig(referenceCaptureIntent: intent(beat: beat)),
            takeID: "take-001", appLocalTakeNumber: 1, recordingRole: "reference_authoring", platform: "fixture",
            appSurface: "reference_authoring", sourceDeviceName: "Fixture", startedAt: watch.startedAt,
            recordingStatus: "completed", mediaFileName: "take.mov", sidecarFileName: "take.json",
            watchSyncState: .acknowledged, linkedMotionCaptureID: watch.id, linkedMotionFileName: "watch_motion.json")
        var inputs = try ReferenceApprovedPackageCoordinator.boundBeatInputs(binding: beat, rootURL: library)
        inputs += try ReferencePackageManifest.requiredArtifactRoles.enumerated().map { index, role in
            ReferencePackageInput(role: role, packagePath: "fixture/evidence_\(index).json",
                data: role == .takeSidecar ? try ReferencePackageIO.encoder.encode(sidecar) : Data("{}".utf8))
        }
        inputs.append(.init(role: .watchMotion, packagePath: "evidence/watch_motion.json", data: watchData))
        let packageURL = try ReferencePackageIO.writePackage(inputs: inputs, parentDirectory: root,
            packageDirectoryName: "tear.exact_beat_v1") { records in self.manifest(beat: beat, artifacts: records) }
        try FileManager.default.removeItem(at: library)
        XCTAssertEqual(ReferencePackageIO.verify(packageURL: packageURL), [])
        let reopened = try ReferenceApprovedPackageCoordinator.copyAndReopen(packageURL: packageURL,
            secondRoot: root.appendingPathComponent("second-machine"))
        XCTAssertEqual(reopened.metadata.captureIntent?.beatSpec, beat)
        XCTAssertEqual(reopened.metadata.sourceState, .linked(identity: watchIdentity, motionFileName: "watch_motion.json",
            sha256: ReferencePackageIO.sha256Hex(watchData)))
        let invalidStates: [ReferencePerTakeSourceState] = [
            .linked(identity: watchIdentity, motionFileName: "watch_motion.json", sha256: nil),
            .linked(identity: watchIdentity, motionFileName: nil, sha256: ReferencePackageIO.sha256Hex(watchData)),
            .unavailable(policy: "fixture")
        ]
        for invalidState in invalidStates {
            XCTAssertTrue(ReferencePackageValidator.manifestIssues(manifest(beat: beat, artifacts: reopened.artifacts,
                sourceState: invalidState)).contains { if case .sourceStateInvalid = $0 { return true }; return false })
        }
        let missingWatch = reopened.artifacts.filter { $0.role != .watchMotion }
        XCTAssertTrue(ReferencePackageValidator.manifestIssues(manifest(beat: beat, artifacts: missingWatch,
            sourceState: reopened.metadata.sourceState)).contains {
            if case .missingRequiredArtifact(let role) = $0 { return role == "watchMotion" }; return false
        })
        let changedRecords = reopened.artifacts.map { artifact in
            ReferenceArtifactRecord(path: artifact.path, byteCount: artifact.byteCount,
                sha256: artifact.role == .beatProductionMaster ? String(repeating: "0", count: 64) : artifact.sha256,
                role: artifact.role)
        }
        XCTAssertTrue(ReferencePackageValidator.manifestIssues(manifest(beat: beat, artifacts: changedRecords)).contains {
            if case .captureIntentInvalid = $0 { return true }; return false
        })
        let master = packageURL.appendingPathComponent("beat_assets/\(beat.id)/\(beat.productionMasterFileName)")
        try Data("changed".utf8).write(to: master)
        XCTAssertFalse(ReferencePackageIO.verify(packageURL: packageURL).isEmpty)
    }

    func testExactReferenceWithoutWatchExportsAndReopensWithExplicitAbsence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let beat = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 95, loopBeats: 4, rootURL: library).binding
        let sidecar = CaptureCore.LocalRecordingSidecar(sessionID: "session",
            sessionConfig: CaptureSessionConfig(referenceCaptureIntent: intent(beat: beat)),
            takeID: "take-001", appLocalTakeNumber: 1, recordingRole: "reference_authoring", platform: "fixture",
            appSurface: "reference_authoring", sourceDeviceName: "Fixture", startedAt: Date(),
            recordingStatus: "completed", mediaFileName: "take.mov", sidecarFileName: "take.json", watchSyncState: .notRequested)
        var inputs = try ReferenceApprovedPackageCoordinator.boundBeatInputs(binding: beat, rootURL: library)
        inputs += try ReferencePackageManifest.requiredArtifactRoles.enumerated().map { index, role in
            ReferencePackageInput(role: role, packagePath: "fixture/evidence_\(index).json",
                data: role == .takeSidecar ? try ReferencePackageIO.encoder.encode(sidecar) : Data("evidence".utf8))
        }
        let package = try ReferencePackageIO.writePackage(inputs: inputs, parentDirectory: root.appendingPathComponent("out"),
            packageDirectoryName: "tear.exact_beat_v1") { records in
                self.manifest(beat: beat, artifacts: records,
                    sourceState: .notRequested(policy: "Optional wrist motion not requested"), watchLinked: false)
            }
        let reopened = try ReferencePackageIO.readManifest(atPackageURL: package)
        let records = reopened.artifacts
        var contradictorySidecar = sidecar
        contradictorySidecar.watchSyncState = .acknowledged
        let contradictoryInputs = try inputs.map { input in
            input.role == .takeSidecar
                ? ReferencePackageInput(role: input.role, packagePath: input.packagePath,
                    data: try ReferencePackageIO.encoder.encode(contradictorySidecar)) : input
        }
        let contradictoryPackage = try ReferencePackageIO.writePackage(inputs: contradictoryInputs,
            parentDirectory: root.appendingPathComponent("contradictory"), packageDirectoryName: "tear.exact_beat_v1") { records in
                self.manifest(beat: beat, artifacts: records,
                    sourceState: .notRequested(policy: "Optional"), watchLinked: false)
            }
        XCTAssertTrue(ReferencePackageIO.verify(packageURL: contradictoryPackage).contains {
            $0.contains("contradicts the declared absence")
        })
        var twoCameraSidecar = sidecar
        let angle = Data("second camera artifact".utf8)
        var camera = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .captured)
        camera.fileName = "take.second-camera.mov"; camera.sha256 = ReferencePackageIO.sha256Hex(angle)
        camera.frameCount = 30; camera.firstFrameSeconds = 0.03; camera.lastFrameSeconds = 1
        twoCameraSidecar.secondaryCamera = camera
        var twoCameraInputs = try inputs.map { input in
            input.role == .takeSidecar ? ReferencePackageInput(role: input.role, packagePath: input.packagePath,
                data: try ReferencePackageIO.encoder.encode(twoCameraSidecar)) : input
        }
        twoCameraInputs.append(.init(role: .secondaryVideo, packagePath: "video/second_camera.mov", data: angle))
        let twoCameraPackage = try ReferencePackageIO.writePackage(inputs: twoCameraInputs,
            parentDirectory: root.appendingPathComponent("two-camera"), packageDirectoryName: "tear.exact_beat_v1") { records in
                self.manifest(beat: beat, artifacts: records, sourceState: .notRequested(policy: "Optional"), watchLinked: false)
            }
        XCTAssertTrue(ReferencePackageIO.verify(packageURL: twoCameraPackage).isEmpty)
        let missingCameraPackage = try ReferencePackageIO.writePackage(inputs: twoCameraInputs.filter { $0.role != .secondaryVideo },
            parentDirectory: root.appendingPathComponent("missing-camera"), packageDirectoryName: "tear.exact_beat_v1") { records in
                self.manifest(beat: beat, artifacts: records, sourceState: .notRequested(policy: "Optional"), watchLinked: false)
            }
        XCTAssertTrue(ReferencePackageIO.verify(packageURL: missingCameraPackage).contains {
            $0.contains("Second-camera file and take-sidecar evidence do not match")
        })
        try FileManager.default.removeItem(at: library)
        XCTAssertTrue(ReferencePackageIO.verify(packageURL: twoCameraPackage).isEmpty)
        XCTAssertFalse(reopened.requiresExactWatchArtifact)
        XCTAssertFalse(reopened.metadata.deviceInfo.watchLinked)
        XCTAssertNil(reopened.artifact(role: .watchMotion))
        XCTAssertTrue(ReferencePackageIO.verify(packageURL: package).isEmpty)
        let contradictory = manifest(beat: beat, artifacts: records,
            sourceState: .notRequested(policy: "Optional"), watchLinked: true)
        XCTAssertFalse(ReferencePackageValidator.manifestIssues(contradictory).isEmpty)
        let unresolved = manifest(beat: beat, artifacts: records,
            sourceState: .timedOut(identity: watchIdentity), watchLinked: false)
        XCTAssertFalse(ReferencePackageValidator.manifestIssues(unresolved).isEmpty)
    }

    func testRawBoundAssetCopyPreservesBindingAndHasNoGlobalLibraryFallback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaRoot = root.appendingPathComponent("capture")
        let beatRoot = mediaRoot.appendingPathComponent("beat_assets")
        let prepared = try ReferenceBeatAssetStore.prepare(mode: .battleLoop, bpm: 95, loopBeats: 4, rootURL: beatRoot)
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let media = mediaRoot.appendingPathComponent("take.mov")
        let sidecarURL = mediaRoot.appendingPathComponent("take.json")
        let sidecar = CaptureCore.LocalRecordingSidecar(
            sessionID: "session",
            sessionConfig: CaptureSessionConfig(referenceCaptureIntent: intent(beat: prepared.binding)),
            takeID: "take-001", appLocalTakeNumber: 1, recordingRole: "reference_authoring",
            platform: "macOS", appSurface: "reference_authoring", sourceDeviceName: "Fixture",
            captureTiming: CaptureTimingMetadata(clickStartHostTime: 100, recordingStartHostTime: 200,
                recordingStartOffsetSeconds: Double(prepared.binding.countInFrameCount) / 48_000),
            startedAt: date, recordingStatus: "completed", mediaFileName: "take.mov", sidecarFileName: "take.json"
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: sidecarURL)
        let records = try SessionArchiveBuilder.boundBeatExportArtifacts(sidecar: sidecar, mediaURL: media,
            sidecarURL: sidecarURL, takeNumber: 1)
        XCTAssertEqual(Set(records.map(\.source)), ["reference_beat_master", "reference_beat_analysis", "reference_beat_manifest",
            "reference_beat_rights", "reference_take_sidecar"])
        let archive = root.appendingPathComponent("archive")
        for record in records {
            let destination = archive.appendingPathComponent(record.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: record.sourceURL, to: destination)
        }
        try FileManager.default.removeItem(at: mediaRoot)
        XCTAssertNoThrow(try ReferenceBeatAssetStore.resolve(binding: prepared.binding,
            rootURL: archive.appendingPathComponent("beat_assets/take_001")))
        XCTAssertThrowsError(try SessionArchiveBuilder.boundBeatExportArtifacts(sidecar: sidecar, mediaURL: media,
            sidecarURL: sidecarURL, takeNumber: 1))
    }

    private func intent(beat: ReferenceBeatSpecBinding) -> ReferenceCaptureIntent {
        .init(id: "intent", parentTechniqueID: ReferenceTechnique.tear.id, variantID: "tear.forward.open",
            recipeID: "exact_beat", startingPlatterDirection: .forward, faderForm: .faderOpenThroughout,
            bpm: beat.bpm, beatsPerCycle: 4, plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1), beatSpec: beat)
    }

    private var watchIdentity: ReferenceTakeSourceIdentity {
        .init(sessionID: "session", takeID: "take-001", takeNumber: 1, takeToken: "token-001")
    }

    private func watchFixture() -> WatchMotionCaptureSession {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let samples = (0..<1_500).map { index in
            WatchMotionSample(elapsedTime: Double(index) / 100, coreMotionTimestamp: Double(index) / 100,
                attitudeRoll: 0, attitudePitch: 0, attitudeYaw: 0,
                quaternionX: 0, quaternionY: 0, quaternionZ: 0, quaternionW: 1,
                gravityX: 0, gravityY: -1, gravityZ: 0,
                userAccelerationX: 0.1, userAccelerationY: 0, userAccelerationZ: 0,
                rotationRateX: 0.2, rotationRateY: 0, rotationRateZ: 0)
        }
        return .init(sessionID: "session", takeID: "take-001", commandID: "command-001",
            requestedAt: start, acknowledgedAt: start, syncState: .acknowledged,
            sourceDeviceName: "Synthetic Watch", sampleRateHz: 100, startedAt: start,
            endedAt: start.addingTimeInterval(15), deviceRecordedAtStart: start,
            deviceRecordedAtEnd: start.addingTimeInterval(15), appVersion: "fixture", timingMetadata: nil, samples: samples)
    }

    private func manifest(beat: ReferenceBeatSpecBinding, artifacts: [ReferenceArtifactRecord],
                          sourceState: ReferencePerTakeSourceState? = nil, watchLinked: Bool = true) -> ReferencePackageManifest {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: Double(beat.countInFrameCount) / 48_000)
        let duration = 24 * 60.0 / Double(beat.bpm) - origin.recordingStartOffsetSeconds
        let timing = ReferenceWitnessedTiming(clickStartHostTime: 100, intendedMediaOriginHostTime: 200,
            actualRecordingOriginHostTime: 200, sampleRate: 48_000, countInFrameCount: beat.countInFrameCount,
            loopStartFrame: beat.loopStartFrame, loopFrameCount: beat.loopFrameCount, beatsPerCycle: 4,
            plannedRepetitions: 4, plannedDurationSeconds: duration, measuredWAVDurationSeconds: duration,
            measuredMOVDurationSeconds: nil, uncertaintySeconds: 1 / 48_000.0, source: .syntheticFixture)
        let decision = ReferenceReviewDecision(outcome: .approved, decidedBy: "Fixture", decidedAt: date,
            notes: "Synthetic package verification only", selectedRepetitionIndex: 0)
        let metadata = ReferenceTakeMetadata(referenceTakeID: "reference-take", authoringSessionID: "authoring", takeNumber: 1,
            operatorName: "Fixture", technique: .tear, pattern: .init(id: "exact_beat", name: "Exact beat", phraseBars: 1),
            bpm: beat.bpm, startingPlatterDirection: .forward, faderVariant: .faderOpenThroughout,
            captureIntent: intent(beat: beat), witnessedTiming: timing, mediaTimeOrigin: origin,
            sourceState: sourceState ?? .linked(identity: watchIdentity, motionFileName: "watch_motion.json",
                sha256: artifacts.first { $0.role == .watchMotion }?.sha256),
            referenceVersion: 1, crossfaderCalibration: nil,
            deviceInfo: .init(platform: "fixture", appVersion: "1", controllerName: "fixture", controllerIdentifier: "fixture",
                audioDeviceName: nil, videoDeviceName: nil, watchLinked: watchLinked),
            recordedAt: date, lifecycleState: .approvedCanonical, reviewDecision: decision)
        return ReferencePackageManifest(referenceID: "tear.exact_beat", referenceVersion: 1, packageBuiltAt: date,
            metadata: metadata, boundaries: .nominal(for: metadata), selectedRepetitionIndex: 0,
            publishedPhraseStartSeconds: 0, publishedPhraseEndSeconds: 4 * 60.0 / Double(beat.bpm), publishedPhraseBeats: 4,
            approval: decision, validation: .init(report: .init(findings: [], evaluatedAt: date)), artifacts: artifacts)
    }
}

final class ReferenceAuthoringTests: XCTestCase {

    // MARK: - Shared fixtures

    private static let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        ),
        fullLeftRawValue: 0,
        centerRawValue: 52,
        fullRightRawValue: 104,
        openEnd: .left,
        activeDeck: .rightDeck,
        calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    private static let deviceInfo = ReferenceDeviceInfo(
        platform: "macOS",
        appVersion: "1.0.1",
        controllerName: "Rane ONE MKII",
        controllerIdentifier: "Rane ONE MKII",
        audioDeviceName: "Rane ONE MKII",
        videoDeviceName: "Studio Camera",
        // Linked wrist motion is REQUIRED evidence for a canonical reference,
        // so the shared "clean take" fixture carries it; the missing-Watch
        // case has its own test.
        watchLinked: true
    )

    private func makeMetadata(
        technique: ReferenceTechnique = .babyScratch,
        bpm: Int = 95,
        phraseBars: Int = 1,
        repetitionCount: Int = 4,
        lifecycleState: ReferenceLifecycleState = .draft,
        mediaTimeOrigin: ReferenceMediaTimeOrigin? = nil
    ) -> ReferenceTakeMetadata {
        ReferenceTakeMetadata(
            referenceTakeID: "ref-take-0001",
            authoringSessionID: "auth-0001",
            takeNumber: 1,
            operatorName: "Karl",
            technique: technique,
            pattern: ReferencePatternIdentity(
                id: "quarter_notes",
                name: "Quarter notes",
                phraseBars: phraseBars
            ),
            bpm: bpm,
            repetitionCount: repetitionCount,
            startingPlatterDirection: .forward,
            faderVariant: technique == .babyScratch ? .faderOpenThroughout : .crossfader,
            mediaTimeOrigin: mediaTimeOrigin,
            referenceVersion: 1,
            crossfaderCalibration: Self.calibration,
            deviceInfo: Self.deviceInfo,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_100),
            lifecycleState: lifecycleState
        )
    }

    func testMediaOriginPreservesLegacyTimingAndOffsetsNew95BPMBoundaries() throws {
        let offset = 4 * 60.0 / 95
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: offset)
        let metadata = makeMetadata(mediaTimeOrigin: origin)
        let restored = try JSONDecoder().decode(ReferenceTakeMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(restored.mediaTimeOrigin, origin)
        let boundaries = ReferencePhraseBoundaries.nominal(for: restored)
        for (index, boundary) in boundaries.repetitions.enumerated() {
            XCTAssertEqual(boundary.startBeat, Double((index + 1) * 4))
            XCTAssertEqual(boundary.startSeconds(metadata: restored), Double(index) * offset, accuracy: 0.0000001)
            XCTAssertEqual(boundary.endSeconds(metadata: restored), Double(index + 1) * offset, accuracy: 0.0000001)
        }
        XCTAssertEqual(restored.firstRepetitionStartSeconds, 0, accuracy: 0.0000001)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        legacyJSON.removeValue(forKey: "mediaTimeOrigin")
        let legacy = try JSONDecoder().decode(ReferenceTakeMetadata.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.mediaTimeOrigin)
        XCTAssertEqual(boundaries.repetitions[0].startSeconds(metadata: legacy), offset, accuracy: 0.0000001)
        XCTAssertEqual(legacy.firstRepetitionStartSeconds, offset, accuracy: 0.0000001)
    }

    func testMalformedMediaOriginsFailValidationInsteadOfFallingBackToLegacyZero() {
        for origin in [
            ReferenceMediaTimeOrigin(clickStartHostTime: 0, recordingStartHostTime: 2, recordingStartOffsetSeconds: 1),
            ReferenceMediaTimeOrigin(clickStartHostTime: 2, recordingStartHostTime: 1, recordingStartOffsetSeconds: 1),
            ReferenceMediaTimeOrigin(clickStartHostTime: 1, recordingStartHostTime: 2, recordingStartOffsetSeconds: -1),
            ReferenceMediaTimeOrigin(clickStartHostTime: 1, recordingStartHostTime: 2, recordingStartOffsetSeconds: .nan),
            ReferenceMediaTimeOrigin(clickStartHostTime: 1, recordingStartHostTime: 1, recordingStartOffsetSeconds: 1),
        ] {
            let metadata = makeMetadata(mediaTimeOrigin: origin)
            XCTAssertTrue(metadata.mediaSeconds(forBeat: 4).isNaN)
            XCTAssertTrue(ReferenceValidator.validate(makeEvidence(metadata: metadata)).findings.contains {
                if case .witnessedTimingInvalid = $0 { return true }; return false
            })
        }
    }

    func testFaderRepetitionChecksUseTheSameMediaOriginAsPlayback() {
        let offset = 4 * 60.0 / 95
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: offset)
        let events = (0..<4).map { (CrossfaderSemanticEventKind.cut, Double($0) * offset + 0.1, Double($0) * offset + 0.15) }
        let derived = derivation([(.open, 0, 11)], events: events)
        let expectation = ReferenceTechnique.chirp.defaultFaderExpectation.confirmed(by: "CXL", at: Date())
        func insufficient(_ metadata: ReferenceTakeMetadata) -> [ReferenceValidationFinding] {
            ReferenceValidator.validate(makeEvidence(metadata: metadata, derivation: derived), expectation: expectation).findings.filter {
                if case .insufficientCutEvents = $0 { return true }; return false
            }
        }
        XCTAssertTrue(insufficient(makeMetadata(technique: .chirp, mediaTimeOrigin: origin)).isEmpty)
        XCTAssertFalse(insufficient(makeMetadata(technique: .chirp)).isEmpty,
            "Legacy grid begins one bar later; the fixture deliberately has no fifth media bar cut.")
    }

    func testSelectedAudioCropUsesNewMediaOriginAndSharedOverlap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("full.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288_000))
        buffer.frameLength = 288_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let offset = 4 * 60.0 / 95
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = Double(frame) < (offset * 48_000).rounded() ? 0.25 : 0.75 }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try file.write(from: buffer)
            if #available(macOS 15.0, *) { file.close() }
        }
        XCTAssertEqual(try AVAudioFile(forReading: sourceURL).length, 288_000,
            "The fixture must be finalized before testing the crop.")
        // Sample rounding can put the nominal downbeat just before media zero.
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: offset + 0.00001)
        let metadata = makeMetadata(mediaTimeOrigin: origin)
        let boundary = ReferencePhraseBoundaries.nominal(for: metadata).repetitions[0]
        let start = boundary.startSeconds(metadata: metadata)
        let end = boundary.endSeconds(metadata: metadata)
        let expected = try XCTUnwrap(ReferenceMediaTimeRange.clamped(start: start, end: end, duration: 6))
        XCTAssertEqual(expected.lowerBound, 0)
        let destinationURL = root.appendingPathComponent("selected.wav")
        let range = try ReferenceApprovedPackageCoordinator.extractSelectedAudio(sourceURL: sourceURL,
            destinationURL: destinationURL, startSeconds: start, endSeconds: end)
        XCTAssertEqual(range.lowerBound, expected.lowerBound)
        XCTAssertEqual(range.upperBound, expected.upperBound, accuracy: 1.0 / 48_000)
        let selected = try AVAudioFile(forReading: destinationURL)
        XCTAssertEqual(selected.length, Int64((expected.upperBound * 48_000).rounded()))
        let actual = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: selected.processingFormat, frameCapacity: AVAudioFrameCount(selected.length)))
        try selected.read(into: actual)
        XCTAssertEqual(actual.floatChannelData![0][0], 0.25, accuracy: 0.00001,
            "Crop must begin at the recorded first repetition, not the old second bar.")
        XCTAssertNil(ReferenceMediaTimeRange.clamped(start: -3, end: -1, duration: 6))
    }

    private func goodAudio(fileName: String = "reference.wav") -> ReferenceArtifactMeasurement {
        ReferenceArtifactMeasurement(
            fileName: fileName,
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.82,
            frameCount: 256_000
        )
    }

    private func goodSidecar() -> ReferenceArtifactMeasurement {
        ReferenceArtifactMeasurement(fileName: "take.json", exists: true, byteCount: 4_096)
    }

    /// Build a derivation directly from state intervals, so a test can state
    /// the fader behaviour it means without simulating a MIDI stream.
    private func derivation(
        _ pieces: [(CrossfaderGateState, Double, Double)],
        events: [(CrossfaderSemanticEventKind, Double, Double)] = []
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: pieces.map {
                CrossfaderStateInterval(
                    state: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    startPosition: $0.0 == .open ? 1 : 0,
                    endPosition: $0.0 == .open ? 1 : 0
                )
            },
            events: events.map {
                CrossfaderSemanticEvent(
                    kind: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    fromPosition: 0,
                    toPosition: 1
                )
            }
        )
    }

    private func makeEvidence(
        metadata: ReferenceTakeMetadata,
        boundaries: ReferencePhraseBoundaries? = nil,
        audio: ReferenceArtifactMeasurement? = nil,
        video: ReferenceArtifactMeasurement? = nil,
        crossfaderSampleCount: Int = 800,
        platterEventCount: Int = 42,
        derivation: CrossfaderDerivation? = nil,
        observedAddress: CrossfaderMIDIAddress? = ReferenceAuthoringTests.calibration.address,
        // Linked wrist evidence is the shared "clean take" default; the
        // pending / missing / mismatched states have their own cases.
        watchEvidence: ReferenceWatchEvidence = .linked(motionFileName: "watch-motion.json")
    ) -> ReferenceTakeEvidence {
        var resolvedBoundaries = boundaries ?? ReferencePhraseBoundaries.nominal(for: metadata)
        if resolvedBoundaries.selectedRepetitionIndex == nil {
            resolvedBoundaries.selectedRepetitionIndex = 0
        }
        let samples = (0..<crossfaderSampleCount).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 1,
                normalizedPosition: 1.0
            )
        }
        return ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: resolvedBoundaries,
            audio: audio ?? goodAudio(),
            video: video,
            sidecar: goodSidecar(),
            actualMediaFileName: video?.fileName,
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: observedAddress,
            platterMovementEventCount: platterEventCount,
            derivation: derivation ?? self.derivation([(.open, 0, 10)]),
            watchEvidence: watchEvidence
        )
    }

    // MARK: - Technique identity

    func testCaptureCatalogueCoversEveryCollectionLabelWithoutMergingDistinctExamples() throws {
        let catalogue = ReferenceTechnique.authorableSet
        XCTAssertEqual(catalogue.count, 23)
        XCTAssertEqual(Set(catalogue.map(\.id)).count, catalogue.count)
        let mapped = ScratchClassLabel.allCases.map { ReferenceTechnique(exampleLabel: $0) }
        XCTAssertEqual(mapped.count, 23)
        XCTAssertEqual(Set(mapped).count, mapped.count)
        XCTAssertEqual(Set(catalogue), Set(mapped))
        XCTAssertFalse(catalogue.contains(.flare(.twoClick)))
        XCTAssertFalse(catalogue.contains(.flare(.threeClick)))
        XCTAssertNotEqual(ReferenceTechnique.originalFlare, .flare(.oneClick))
        XCTAssertNotEqual(ReferenceTechnique.tips.scratchType, .stab)
        XCTAssertNotEqual(ReferenceTechnique.reverseCutting.scratchType, .backwardScratch)
    }

    func testSelectableAndLegacyReferenceTechniquesRetainIdentityThroughMetadataEncoding() throws {
        let techniques = ReferenceTechnique.authorableSet + [.flare(.twoClick), .flare(.threeClick)]
        for technique in techniques {
            XCTAssertEqual(ReferenceTechnique(scratchType: technique.scratchType), technique)
            XCTAssertEqual(ReferenceTechnique(scratchTypeID: technique.id), technique)
            let original = makeMetadata(technique: technique)
            let decoded = try JSONDecoder().decode(ReferenceTakeMetadata.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.technique, technique)
            XCTAssertEqual(decoded.lifecycleState, .draft)
            XCTAssertNil(decoded.reviewDecision)
        }
        XCTAssertNil(ReferenceTechnique(scratchType: .unknown))
        XCTAssertNil(ReferenceTechnique(scratchTypeID: "unrecognised"))
    }

    func testExpandedCaptureDoesNotExpandTrainingOrInventCutRequirements() {
        XCTAssertEqual(ReferenceTechnique.minimumRequiredSet,
            [.babyScratch, .chirp, .transform, .flare(.oneClick), .flare(.twoClick), .flare(.threeClick)])
        for technique in ReferenceTechnique.authorableSet
            where !ReferenceTechnique.minimumRequiredSet.contains(technique) && technique != .tear {
            let rule = technique.defaultFaderExpectation
            XCTAssertFalse(rule.source.isOperatorConfirmed)
            XCTAssertFalse(rule.requiresContinuouslyOpenFader)
            XCTAssertEqual(rule.minimumCutEventsPerRepetition, 0)
            XCTAssertTrue(rule.requiresOperatorApproval)
            XCTAssertTrue(technique.requiresCalibratedCrossfader)
            XCTAssertFalse(ReferenceCapturePreflight.evaluate(snapshot: makeSnapshot(), technique: technique).blocksRecording)
            XCTAssertTrue(ReferenceCapturePreflight.evaluate(snapshot: makeSnapshot(calibration: nil), technique: technique).blocksRecording)
        }
    }

    func testLegacyTechniqueEncodingStillDecodes() throws {
        let legacy: [(String, ReferenceTechnique)] = [
            (#"{"babyScratch":{}}"#, .babyScratch), (#"{"tear":{}}"#, .tear),
            (#"{"chirp":{}}"#, .chirp), (#"{"transform":{}}"#, .transform),
            (#"{"flare":{"_0":2}}"#, .flare(.twoClick))
        ]
        for (json, technique) in legacy {
            XCTAssertEqual(try JSONDecoder().decode(ReferenceTechnique.self, from: Data(json.utf8)), technique)
        }
    }

    func testFlareCannotExistWithoutAClickCount() {
        // A generic "flare" token is not a technique and must not resolve.
        XCTAssertNil(ReferenceTechnique(scratchTypeID: "flare"))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_1click"), .flare(.oneClick))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_2click"), .flare(.twoClick))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_3click"), .flare(.threeClick))
    }

    func testFlareClickCountDrivesTheRequiredCutCount() {
        XCTAssertEqual(ReferenceTechnique.flare(.oneClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 1)
        XCTAssertEqual(ReferenceTechnique.flare(.twoClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 2)
        XCTAssertEqual(ReferenceTechnique.flare(.threeClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 3)
    }

    func testBabyScratchExpectsAContinuouslyOpenFaderAndNoCuts() {
        let expectation = ReferenceTechnique.babyScratch.defaultFaderExpectation
        XCTAssertTrue(expectation.requiresContinuouslyOpenFader)
        XCTAssertEqual(expectation.minimumCutEventsPerRepetition, 0)
        XCTAssertEqual(expectation.maximumUnknownEventRatio, 0)
    }

    func testChirpAndTransformRequireFaderActivity() {
        XCTAssertFalse(ReferenceTechnique.chirp.defaultFaderExpectation.requiresContinuouslyOpenFader)
        XCTAssertGreaterThanOrEqual(ReferenceTechnique.chirp.defaultFaderExpectation.minimumCutEventsPerRepetition, 1)
        XCTAssertGreaterThanOrEqual(ReferenceTechnique.transform.defaultFaderExpectation.minimumCutEventsPerRepetition, 2)
    }

    func testEveryTechniqueRequiresOperatorApproval() {
        for technique in ReferenceTechnique.minimumRequiredSet {
            XCTAssertTrue(
                technique.defaultFaderExpectation.requiresOperatorApproval,
                "\(technique.displayName) must not be publishable without a human decision."
            )
        }
    }

    func testOnlyBabyScratchHasVerifiedTargetSemanticsToday() {
        XCTAssertTrue(ReferenceTechnique.babyScratch.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.chirp.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.transform.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.flare(.twoClick).hasVerifiedTargetSemantics)
    }

    // MARK: - Validation: a clean take

    func testACleanBabyScratchTakePassesValidation() {
        let evidence = makeEvidence(metadata: makeMetadata())
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(report.passes, "Unexpected failures: \(report.failureMessages)")
    }

    // MARK: - Validation: technique fader requirements

    func testBabyScratchFailsWhenTheFaderLeavesTheOpenZone() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation(
                [(.open, 0, 2), (.closed, 2, 3), (.open, 3, 10)],
                events: [(.cut, 2, 2.1), (.release, 2.9, 3)]
            )
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("crossfader open") },
            report.failureMessages.description
        )
    }

    func testUnconfirmedTransformCutRequirementIsAdvisoryNotBlocking() {
        // ScratchLab has not been shown a correct transform — no recorded
        // take is valid reference material — so the shipped
        // `.provisionalDefault` cut-count requirement must NOT fail a take on
        // its own. Automated validation only enforces capture integrity here;
        // technique correctness is CXL's call in review.
        let metadata = makeMetadata(technique: .transform, bpm: 100)
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 2.5, 2.6)]
            )
        )
        XCTAssertFalse(
            ReferenceTechnique.transform.defaultFaderExpectation.source.isOperatorConfirmed
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.failureMessages.filter { $0.contains("crossfader cut") }.isEmpty,
            "An unconfirmed technique-shape requirement must not block approval: \(report.failureMessages)"
        )
    }

    func testOnceCXLConfirmsTheTransformRequirementTheSameTakeFails() {
        let metadata = makeMetadata(technique: .transform, bpm: 100)
        // One cut in repetition 0, nothing anywhere else.
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 2.5, 2.6)]
            )
        )
        let confirmed = ReferenceTechnique.transform.defaultFaderExpectation.confirmed(
            by: "CXL",
            at: Date(timeIntervalSince1970: 1_788_000_000)
        )
        XCTAssertTrue(confirmed.source.isOperatorConfirmed)
        let report = ReferenceValidator.validate(evidence, expectation: confirmed)
        XCTAssertFalse(report.passes)
        let cutFindings = report.failureMessages.filter { $0.contains("crossfader cut") }
        XCTAssertEqual(cutFindings.count, 4, "Every repetition should be reported, not just the first.")
    }

    func testTwoClickFlarePassesAgainstAConfirmedRequirementWithAPulseFigure() {
        let metadata = makeMetadata(technique: .flare(.twoClick), bpm: 60, phraseBars: 1)
        // At 60 bpm one bar is 4 s; count-in ends at 4 s, so repetition 0 runs
        // 4…8 s, repetition 1 8…12 s, and so on.
        let events: [(CrossfaderSemanticEventKind, Double, Double)] = [
            (.pulse, 4.5, 4.8),
            (.pulse, 8.5, 8.8),
            (.pulse, 12.5, 12.8),
            (.pulse, 16.5, 16.8)
        ]
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation([(.open, 0, 20)], events: events)
        )
        let confirmed = ReferenceTechnique.flare(.twoClick).defaultFaderExpectation.confirmed(
            by: "CXL",
            at: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let report = ReferenceValidator.validate(evidence, expectation: confirmed)
        XCTAssertTrue(report.passes, "Unexpected failures: \(report.failureMessages)")
    }

    // MARK: - Validation: unknown-event ratio

    func testExcessiveUnknownFaderEventsBlockApproval() {
        // The shape of the 2026-09-04 take: 20 events, 12 unclassified.
        var events: [(CrossfaderSemanticEventKind, Double, Double)] = []
        for index in 0..<12 {
            events.append((.unknown, Double(index) * 0.1, Double(index) * 0.1 + 0.05))
        }
        for index in 12..<20 {
            events.append((.cut, Double(index) * 0.1, Double(index) * 0.1 + 0.05))
        }
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .chirp),
            derivation: derivation([(.open, 0, 10)], events: events)
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("could not be classified") },
            report.failureMessages.description
        )
    }

    func testUnknownRatioIsMeasuredAgainstTheEventCountNotTheSampleCount() {
        let derived = derivation(
            [(.open, 0, 10)],
            events: [(.unknown, 0, 1), (.cut, 1, 2), (.cut, 2, 3), (.cut, 3, 4)]
        )
        XCTAssertEqual(derived.unknownEventCount, 1)
        XCTAssertEqual(derived.unknownEventRatio, 0.25, accuracy: 0.0001)
    }

    // MARK: - Validation: missing evidence

    /// "No crossfader MIDI was recorded" is now the rule for techniques that
    /// REQUIRE fader cuts. Baby Scratch is performed with the fader held open
    /// and has its own open-state rule — see the D2 cases below.
    func testMissingCrossfaderEvidenceIsReportedExplicitly() {
        let evidence = ReferenceTakeEvidence(
            metadata: makeMetadata(technique: .chirp),
            boundaries: {
                var b = ReferencePhraseBoundaries.nominal(for: makeMetadata(technique: .chirp))
                b.selectedRepetitionIndex = 0
                return b
            }(),
            audio: goodAudio(),
            video: nil,
            sidecar: goodSidecar(),
            actualMediaFileName: nil,
            crossfaderRawSamples: [],
            observedCrossfaderAddress: nil,
            platterMovementEventCount: 42,
            derivation: derivation([(.open, 0, 10)]),
            watchEvidence: .linked(motionFileName: "watch-motion.json")
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No crossfader MIDI was recorded") },
            report.failureMessages.description
        )
    }

    func testMissingPlatterEvidenceIsReportedExplicitly() {
        let evidence = makeEvidence(metadata: makeMetadata(), platterEventCount: 0)
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No platter movement") },
            report.failureMessages.description
        )
    }

    func testAnUnidentifiedControllerIsReportedExplicitly() {
        var metadata = makeMetadata()
        metadata = ReferenceTakeMetadata(
            referenceTakeID: metadata.referenceTakeID,
            authoringSessionID: metadata.authoringSessionID,
            takeNumber: metadata.takeNumber,
            operatorName: metadata.operatorName,
            technique: metadata.technique,
            pattern: metadata.pattern,
            bpm: metadata.bpm,
            startingPlatterDirection: metadata.startingPlatterDirection,
            faderVariant: metadata.faderVariant,
            handedness: metadata.handedness,
            referenceVersion: metadata.referenceVersion,
            crossfaderCalibration: metadata.crossfaderCalibration,
            deviceInfo: ReferenceDeviceInfo(
                platform: "macOS",
                appVersion: "1.0.1",
                controllerName: "",
                controllerIdentifier: "",
                audioDeviceName: nil,
                videoDeviceName: nil,
                watchLinked: false
            ),
            recordedAt: metadata.recordedAt
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: metadata))
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("could not be identified") },
            report.failureMessages.description
        )
    }

    func testACalibrationMeasuredOnADifferentAddressIsRejected() {
        let evidence = makeEvidence(
            metadata: makeMetadata(),
            observedAddress: CrossfaderMIDIAddress(
                deviceIdentifier: "Rane ONE MKII",
                deviceName: "Rane ONE MKII",
                channel: 1,
                controller: 6
            )
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("Recalibrate on the controller") },
            report.failureMessages.description
        )
    }

    // MARK: - Validation: artifacts

    func testSilentProgramAudioIsRejectedWithItsMeasuredPeak() {
        let silent = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.0,
            frameCount: 256_000
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(), audio: silent))
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("which is silence") },
            report.failureMessages.description
        )
    }

    func testAnUnreadableAudioFileIsDistinguishedFromAMissingOne() {
        let unreadable = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 900,
            readError: "The file couldn't be opened."
        )
        let unreadableReport = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(), audio: unreadable)
        )
        XCTAssertTrue(
            unreadableReport.failureMessages.contains { $0.contains("exists but could not be read") },
            unreadableReport.failureMessages.description
        )

        let missing = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: false,
            byteCount: 0
        )
        let missingReport = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(), audio: missing)
        )
        XCTAssertTrue(
            missingReport.failureMessages.contains { $0.contains("is missing from the take folder") },
            missingReport.failureMessages.description
        )
        XCTAssertFalse(
            missingReport.failureMessages.contains { $0.contains("exists but could not be read") }
        )
    }

    func testAnArtifactHashMismatchNamesTheFile() {
        let tampered = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.8,
            frameCount: 256_000,
            recordedSHA256: String(repeating: "a", count: 64),
            currentSHA256: String(repeating: "b", count: 64)
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(), audio: tampered))
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains {
                $0.contains("reference.wav") && $0.contains("does not match its recorded hash")
            },
            report.failureMessages.description
        )
    }

    func testAFileNameSidecarMismatchIsReported() {
        let video = ReferenceArtifactMeasurement(
            fileName: "declared.mov",
            exists: true,
            byteCount: 500_000
        )
        var evidence = makeEvidence(metadata: makeMetadata(), video: video)
        evidence = ReferenceTakeEvidence(
            metadata: evidence.metadata,
            boundaries: evidence.boundaries,
            audio: evidence.audio,
            video: video,
            sidecar: evidence.sidecar,
            actualMediaFileName: "actual.mov",
            crossfaderRawSamples: evidence.crossfaderRawSamples,
            observedCrossfaderAddress: evidence.observedCrossfaderAddress,
            platterMovementEventCount: evidence.platterMovementEventCount,
            derivation: evidence.derivation
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("names its media file as declared.mov") },
            report.failureMessages.description
        )
    }

    // MARK: - Validation: metadata and boundaries

    func testAnOutOfRangeBPMIsRejectedWithTheSupportedRange() {
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(bpm: 300)))
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("BPM 300 is outside the supported range") },
            report.failureMessages.description
        )
    }

    func testARepetitionCountOtherThanFourIsRejected() {
        let report = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(repetitionCount: 3))
        )
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("must contain 4") },
            report.failureMessages.description
        )
    }

    func testOverlappingRepetitionBoundariesAreRejected() {
        let metadata = makeMetadata()
        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        boundaries.repetitions[1].startBeat = boundaries.repetitions[0].endBeat - 1
        boundaries.selectedRepetitionIndex = 0
        let report = ReferenceValidator.validate(
            makeEvidence(metadata: metadata, boundaries: boundaries)
        )
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("starts before repetition") },
            report.failureMessages.description
        )
    }

    func testNoSelectedRepetitionBlocksApproval() {
        let metadata = makeMetadata()
        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        boundaries.selectedRepetitionIndex = nil
        let evidence = ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: boundaries,
            audio: goodAudio(),
            video: nil,
            sidecar: goodSidecar(),
            actualMediaFileName: nil,
            crossfaderRawSamples: [
                CrossfaderPositionSample(takeRelativeTime: 0, rawValue: 1, normalizedPosition: 1)
            ],
            observedCrossfaderAddress: Self.calibration.address,
            platterMovementEventCount: 10,
            derivation: derivation([(.open, 0, 10)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No repetition has been selected") },
            report.failureMessages.description
        )
    }

    func testNominalBoundariesStartAfterTheCountInBar() {
        let metadata = makeMetadata(bpm: 60, phraseBars: 1)
        let boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        XCTAssertEqual(boundaries.repetitions.count, 4)
        XCTAssertEqual(boundaries.repetitions[0].startBeat, 4)
        XCTAssertEqual(boundaries.repetitions[3].endBeat, 20)
        // Count-in bar + 4 repetitions + tail bar = 24 beats.
        XCTAssertEqual(metadata.totalBeats, 24)
        XCTAssertEqual(boundaries.repetitions[0].startSeconds(bpm: 60), 4.0, accuracy: 0.0001)
    }

    // MARK: - Lifecycle

    func testLifecycleAdvancesOneStepAtATime() {
        XCTAssertTrue(ReferenceLifecycleState.draft.canAdvance(to: .reviewed))
        XCTAssertFalse(ReferenceLifecycleState.draft.canAdvance(to: .approvedCanonical))
        XCTAssertFalse(ReferenceLifecycleState.draft.canAdvance(to: .published))
        XCTAssertTrue(ReferenceLifecycleState.reviewed.canAdvance(to: .approvedCanonical))
        XCTAssertTrue(ReferenceLifecycleState.approvedCanonical.canAdvance(to: .published))
        XCTAssertTrue(ReferenceLifecycleState.published.permittedNextStates.isEmpty == false)
        XCTAssertEqual(ReferenceLifecycleState.published.permittedNextStates, [.deprecated])
    }

    func testARawCaptureIsNeverPlayableByALearner() {
        XCTAssertFalse(ReferenceLifecycleState.diagnostic.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.draft.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.reviewed.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.approvedCanonical.isPlayableByLearner)
        XCTAssertTrue(ReferenceLifecycleState.published.isPlayableByLearner)
    }

    func testAnIllegalLifecycleMoveIsNamed() {
        let finding = ReferenceValidator.lifecycleFinding(from: .draft, to: .published)
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("draft → reviewed → approved canonical → published") ?? false)
        XCTAssertNil(ReferenceValidator.lifecycleFinding(from: .draft, to: .reviewed))
    }

    // MARK: - Registry: no fallback to deprecated data

    func testTheShippedRegistryServesNothingAndSaysWhy() {
        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )
        XCTAssertTrue(registry.isEmptyOfServableReferences)
        for technique in ReferenceTechnique.minimumRequiredSet {
            XCTAssertFalse(
                registry.resolve(technique: technique).isTrainable,
                "\(technique.displayName) must not be trainable before a calibrated re-record is approved."
            )
        }
    }

    func testADeprecatedAssetExplainsAnAbsenceButIsNeverServed() {
        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let availability = registry.resolve(technique: .babyScratch)
        guard case .awaitingReRecord(let assetID, let reason) = availability else {
            return XCTFail("Baby Scratch has deprecated assets, so it should report awaitingReRecord, got \(availability)")
        }
        XCTAssertNotNil(assetID)
        XCTAssertEqual(reason, .uncalibratedCrossfader)
        XCTAssertNil(availability.entry, "A deprecated asset must never surface as a servable entry.")
        XCTAssertFalse(availability.isTrainable)
        XCTAssertNotNil(availability.learnerMessage(for: .babyScratch))
    }

    func testATechniqueWithNoAssetsAtAllReportsUnavailable() {
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [],
                deprecatedAssets: [],
                trainingEnabledTechniques: [.chirp]
            )
        )
        XCTAssertEqual(registry.resolve(technique: .chirp), .unavailable)
    }

    func testAnApprovedEntryBecomesTrainableAndTheHighestVersionWins() {
        let entryV1 = makeRegistryEntry(version: 1, approvedAt: Date(timeIntervalSince1970: 1_788_000_000))
        let entryV2 = makeRegistryEntry(version: 2, approvedAt: Date(timeIntervalSince1970: 1_788_100_000))
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [entryV1, entryV2],
                deprecatedAssets: LegacyReferenceInventory.deprecatedAssets(deprecatedAt: Date()),
                trainingEnabledTechniques: [.babyScratch]
            )
        )
        let availability = registry.resolve(technique: .babyScratch)
        XCTAssertTrue(availability.isTrainable)
        XCTAssertEqual(availability.entry?.referenceVersion, 2)
    }

    func testACandidateEntryIsNotServable() {
        var entry = makeRegistryEntry(version: 1, approvedAt: Date())
        entry = ReferenceRegistryEntry(
            referenceID: entry.referenceID,
            technique: entry.technique,
            pattern: entry.pattern,
            bpm: entry.bpm,
            referenceVersion: entry.referenceVersion,
            lifecycleState: .reviewed,
            audioResourcePath: entry.audioResourcePath,
            manifestResourcePath: entry.manifestResourcePath,
            audioSHA256: entry.audioSHA256,
            phraseBeats: entry.phraseBeats,
            startingPlatterDirection: entry.startingPlatterDirection,
            approvedAt: entry.approvedAt,
            approvedBy: entry.approvedBy
        )
        XCTAssertFalse(entry.isServable)
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [entry],
                deprecatedAssets: [],
                trainingEnabledTechniques: [.babyScratch]
            )
        )
        XCTAssertFalse(registry.resolve(technique: .babyScratch).isTrainable)
    }

    private func makeRegistryEntry(version: Int, approvedAt: Date) -> ReferenceRegistryEntry {
        ReferenceRegistryEntry(
            referenceID: "baby_scratch.quarter_notes",
            technique: .babyScratch,
            pattern: ReferencePatternIdentity(id: "quarter_notes", name: "Quarter notes", phraseBars: 1),
            bpm: 95,
            referenceVersion: version,
            lifecycleState: .published,
            audioResourcePath: "References/baby_scratch/quarter_notes.wav",
            manifestResourcePath: "References/baby_scratch/manifest.json",
            audioSHA256: String(repeating: "c", count: 64),
            phraseBeats: 4,
            startingPlatterDirection: .forward,
            approvedAt: approvedAt,
            approvedBy: "Karl"
        )
    }

    // MARK: - Call and response

    func testListenThenCopyOpensAResponseWindowEqualToThePhrase() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.4,
                countInBeats: 4,
                bpm: 100
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        // 4 beats at 100 bpm = 2.4 s count-in.
        XCTAssertEqual(schedule.phases.first?.kind, .countIn)
        XCTAssertEqual(schedule.phases.first?.duration ?? 0, 2.4, accuracy: 0.0001)
        XCTAssertEqual(schedule.responseWindows.count, 1)
        XCTAssertEqual(schedule.responseWindows[0].endTime - schedule.responseWindows[0].startTime, 2.4, accuracy: 0.0001)
        XCTAssertEqual(schedule.totalDuration, 7.2, accuracy: 0.0001)
    }

    func testResponseWindowLengthIsConfigurableWithoutRerecording() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                responseDurationSeconds: 6.0,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertEqual(schedule.responseWindows[0].endTime - schedule.responseWindows[0].startTime, 6.0, accuracy: 0.0001)
    }

    func testRepeatedRoundsAlternateReferenceAndResponse() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .repeatedRounds,
                phraseDurationSeconds: 2.0,
                roundCount: 4,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertEqual(schedule.responseWindows.count, 4)
        XCTAssertEqual(schedule.roundCount, 4)
        let kinds = schedule.phases.dropLast().map(\.kind)
        XCTAssertEqual(kinds, [.reference, .response, .reference, .response, .reference, .response, .reference, .response])
    }

    func testListenOnlyAndLoopingOpenNoResponseWindow() {
        for mode in [CallAndResponseMode.listenOnly, .loopingReference] {
            guard let schedule = CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: mode,
                    phraseDurationSeconds: 2.0,
                    roundCount: 3,
                    countInBeats: 0,
                    bpm: 120
                )
            ) else {
                return XCTFail("Usable configuration produced no schedule for \(mode).")
            }
            XCTAssertTrue(schedule.responseWindows.isEmpty)
            XCTAssertFalse(schedule.capturesLearner(at: 1.0))
        }
    }

    func testTheLearnerIsCapturedOnlyInsideTheResponseWindow() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertFalse(schedule.capturesLearner(at: 1.0))
        XCTAssertTrue(schedule.capturesLearner(at: 3.0))
        XCTAssertEqual(schedule.phase(at: 3.0)?.kind.displayLabel, "YOUR TURN")
    }

    func testTheClickCanBeSilencedThroughTheResponseWindowOnly() {
        guard let running = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120,
                clickRunsThroughResponse: true
            )
        ),
        let silent = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120,
                clickRunsThroughResponse: false
            )
        ) else {
            return XCTFail("Usable configurations produced no schedule.")
        }
        XCTAssertTrue(running.clickIsAudible(at: 1.0))
        XCTAssertTrue(running.clickIsAudible(at: 3.0))
        XCTAssertTrue(silent.clickIsAudible(at: 1.0))
        XCTAssertFalse(silent.clickIsAudible(at: 3.0))
    }

    func testAnUnusableConfigurationProducesNoSchedule() {
        XCTAssertNil(
            CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: .listenThenCopy,
                    phraseDurationSeconds: 0,
                    bpm: 120
                )
            )
        )
        XCTAssertNil(
            CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: .listenThenCopy,
                    phraseDurationSeconds: 2,
                    bpm: 0
                )
            )
        )
    }

    func testComparisonIsGatedOnVerifiedTargetSemantics() {
        XCTAssertTrue(CallAndResponseComparisonGate.decision(for: .babyScratch).isComparable)
        for technique in [ReferenceTechnique.chirp, .transform, .flare(.oneClick)] {
            let decision = CallAndResponseComparisonGate.decision(for: technique)
            XCTAssertFalse(
                decision.isComparable,
                "\(technique.displayName) has no verified target notation and must not be scored."
            )
            if case .notComparable(let reason) = decision {
                XCTAssertTrue(reason.contains("will not score"))
            }
        }
    }

    // MARK: - Preflight

    private func makeSnapshot(
        calibration: CrossfaderCalibration? = ReferenceAuthoringTests.calibration,
        controllerName: String? = "Rane ONE MKII",
        rawValue: Int? = 1,
        platterEvents: Int = 500,
        platterMoving: Bool = true,
        audioPeak: Double? = 0.4,
        watchReachable: Bool = true,
        crossfaderSecondsSinceLastMessage: Double? = 0.1
    ) -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: controllerName,
            controllerIdentifier: controllerName,
            observedCrossfaderAddress: controllerName == nil ? nil : Self.calibration.address,
            latestCrossfaderRawValue: rawValue,
            calibration: calibration,
            crossfaderEventCount: 120,
            platterEventCount: platterEvents,
            platterIsMoving: platterMoving,
            audioInputPeakLevel: audioPeak,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: watchReachable,
            watchMotionIsStreaming: watchReachable,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: crossfaderSecondsSinceLastMessage
        )
    }

    func testPreflightPassesWithEverythingConnectedAndCalibrated() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(),
            technique: .babyScratch
        )
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
    }

    func testPreflightBlocksRecordingWithoutACalibration() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(calibration: nil),
            technique: .chirp
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(
            result.blockingChecks.contains { $0.detail.contains("No calibration on file") },
            result.blockingSummary ?? ""
        )
    }

    func testPreflightBlocksRecordingWithoutAController() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(controllerName: nil),
            technique: .transform
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(result.blockingChecks.contains { $0.id == "controller" })
    }

    func testPreflightAllowsBabyScratchToStartWithAClosedFader() {
        // raw 52 is fully closed on this calibration.
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(rawValue: 52),
            technique: .babyScratch
        )
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
        XCTAssertEqual(result.checks.first { $0.id == "crossfaderState" }?.status, .advisory)
    }

    func testPreflightAllowsAClosedFaderForATransform() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(rawValue: 52),
            technique: .transform
        )
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
    }

    func testPreflightBlocksWhenAudioSamplesAreUnavailable() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(audioPeak: nil),
            technique: .chirp
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(result.blockingChecks.contains { $0.id == "audioInput" })
    }

    func testPreflightAllowsDiagnosticRecordingWhenTheWatchIsUnreachable() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(watchReachable: false),
            technique: .chirp
        )
        XCTAssertEqual(result.checks.first { $0.id == "watch" }?.status, .advisory)
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
    }

    func testPreflightAllowsEveryCalibratedFaderPositionWithQuietAudioAndNoWatch() {
        for technique: ReferenceTechnique in [.babyScratch, .tear, .transform] {
            for rawValue in 0...127 {
                let result = ReferenceCapturePreflight.evaluate(
                    snapshot: makeSnapshot(rawValue: rawValue, audioPeak: 0, watchReachable: false),
                    technique: technique
                )
                XCTAssertFalse(result.blocksRecording, "\(technique) raw \(rawValue): \(result.blockingSummary ?? "")")
                XCTAssertEqual(result.checks.first { $0.id == "audioInput" }?.status, .advisory)
            }
        }
    }

    func testPreflightBlocksInvalidAudioLevels() {
        for peak in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            let result = ReferenceCapturePreflight.evaluate(
                snapshot: makeSnapshot(audioPeak: peak), technique: .tear
            )
            XCTAssertTrue(result.blockingChecks.contains { $0.id == "audioInput" })
        }
    }

    func testPreflightAcceptsAReachableWatch() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(watchReachable: true),
            technique: .chirp
        )
        XCTAssertEqual(result.checks.first { $0.id == "watch" }?.status, .satisfied)
    }

    func testPreflightNeverFallsBackToFullRangeNormalization() {
        // No calibration: the calibrated value must be absent, not raw/127.
        let snapshot = makeSnapshot(calibration: nil, rawValue: 52)
        XCTAssertNil(snapshot.calibratedCrossfaderPosition)
        XCTAssertNil(snapshot.crossfaderGateState())
    }

    // MARK: - Crossfader liveness in the preflight panel

    func testAParkedCrossfaderOnTheCurrentConnectionStaysReady() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: 90)
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertEqual(row?.status, .satisfied)
        XCTAssertTrue(row?.detail.contains("Ready — idle") ?? false, row?.detail ?? "")
        XCTAssertTrue(row?.detail.contains("120 since launch") ?? false, row?.detail ?? "")
        XCTAssertTrue(row?.detail.contains("90.0s ago") ?? false, row?.detail ?? "")
        XCTAssertFalse(ReferenceCapturePreflight.crossfaderIsRecentlyActive(snapshot: snapshot))
    }

    func testAStillPlatterOnTheCurrentConnectionStaysReady() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(platterMoving: false), technique: .tear)
        let row = result.checks.first { $0.id == "platter" }
        XCTAssertEqual(row?.status, .satisfied)
        XCTAssertTrue(row?.detail.contains("Ready — idle") ?? false)
    }

    func testDisconnectedSourceCannotStayReadyFromNonzeroCachedCounts() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(controllerName: nil, platterMoving: false), technique: .tear)
        XCTAssertNotEqual(result.checks.first { $0.id == "crossfaderEvents" }?.status, .satisfied)
        XCTAssertNotEqual(result.checks.first { $0.id == "platter" }?.status, .satisfied)
    }

    func testNeverObservedPlatterDoesNotBecomeReadyJustBecauseItIsIdle() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(platterEvents: 0, platterMoving: false), technique: .tear)
        XCTAssertNotEqual(result.checks.first { $0.id == "platter" }?.status, .satisfied)
    }

    func testCrossfaderObservationFromAnotherSourceCannotClaimReady() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(controllerName: "Different MIDI source"), technique: .tear)
        XCTAssertEqual(result.checks.first { $0.id == "crossfaderEvents" }?.status, .advisory)
    }

    func testNoRawObservationCannotClaimCrossfaderReady() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(rawValue: nil), technique: .tear)
        XCTAssertEqual(result.checks.first { $0.id == "crossfaderEvents" }?.status, .advisory)
    }

    func testInvalidRawCrossfaderCannotClaimReady() {
        for raw in [-1, 128] {
            let result = ReferenceCapturePreflight.evaluate(
                snapshot: makeSnapshot(rawValue: raw), technique: .tear)
            XCTAssertEqual(result.checks.first { $0.id == "crossfaderEvents" }?.status, .advisory)
        }
    }

    func testARecentCrossfaderMessageIsSatisfied() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: 0.2)
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertEqual(row?.status, .satisfied)
        XCTAssertTrue(row?.detail.contains("moving now") ?? false, row?.detail ?? "")
    }

    func testAnUnknownCrossfaderMessageAgeIsTreatedAsSilent() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: nil)
        XCTAssertFalse(ReferenceCapturePreflight.crossfaderIsRecentlyActive(snapshot: snapshot))
    }

    /// While a take is recording the panel reports the number that actually
    /// reaches the sidecar, not just the lifetime total.
    func testTheRowReportsTheTakeScopedCountWhileRecording() {
        let snapshot = ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: Self.calibration.address,
            latestCrossfaderRawValue: 1,
            calibration: Self.calibration,
            crossfaderEventCount: 1_089,
            platterEventCount: 20_440,
            platterIsMoving: true,
            audioInputPeakLevel: 0.4,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 42,
            takeScopedCrossfaderEventCount: 0,
            isRecordingTake: true
        )
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertTrue(row?.detail.contains("0 in this take") ?? false, row?.detail ?? "")
        XCTAssertEqual(
            row?.status, .satisfied,
            "A parked, observed control stays ready; its separate zero take count must remain visible."
        )
    }

    // MARK: - Technique-aware fader validation (D2, from the 2026-09-05 test)
    //
    // Baby Scratch declares `requiresContinuouslyOpenFader: true` and
    // `minimumCutEventsPerRepetition: 0` — it is PERFORMED without moving the
    // fader. Validation nevertheless demanded crossfader movement
    // unconditionally, so the one authorable technique could never pass. Karl
    // performed it correctly on hardware and take-003 was blocked by
    // "No crossfader MIDI was recorded".

    func testBabyScratchWithACalibratedOpenBaselineAndZeroCutsPassesTheFaderRequirement() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 20)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertEqual(
            ReferenceValidator.faderOpenEvidence(for: evidence),
            .provenContinuouslyOpen
        )
        XCTAssertTrue(report.passes, report.failureMessages.description)
    }

    func testZeroDurationOpenBaselineCannotProveTheRecordedRepetition() {
        let evidence = makeEvidence(metadata: makeMetadata(technique: .tear),
            crossfaderSampleCount: 0, derivation: derivation([(.open, 0, 0)]))
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("A sampled point has no positive coverage and must not prove an open repetition.")
        }
        XCTAssertTrue(ReferenceValidator.validate(evidence).findings.contains {
            if case .faderOpenStateUnknown = $0 { return true }; return false
        })
    }

    func testOpenFaderCoverageMustReachTheSelectedRepetitionEnd() {
        let evidence = makeEvidence(metadata: makeMetadata(technique: .tear),
            derivation: derivation([(.open, 0, 3)]))
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("Open evidence ending at 3s does not cover the selected 2.526–5.053s repetition.")
        }
    }

    func testOpenFaderIntervalsCannotBridgeAnInternalGap() {
        let evidence = makeEvidence(metadata: makeMetadata(technique: .tear),
            derivation: derivation([(.open, 0, 3), (.open, 3.01, 20)]))
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("The baseline allowance must not erase an internal 10ms evidence gap.")
        }
    }

    func testAdjacentPositiveOpenIntervalsCoverTheSelectedRepetition() {
        let evidence = makeEvidence(metadata: makeMetadata(technique: .tear),
            derivation: derivation([(.open, 3, 20), (.open, 0, 3)]))
        XCTAssertEqual(ReferenceValidator.faderOpenEvidence(for: evidence), .provenContinuouslyOpen)
    }

    func testOpenCoverageUsesSelectedRepetitionAndRecordedMediaOrigin() {
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: 4)
        let metadata = makeMetadata(technique: .tear, bpm: 60, mediaTimeOrigin: origin)
        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        boundaries.selectedRepetitionIndex = 1 // Beats 8–12 are recorded seconds 4–8.
        let covered = makeEvidence(metadata: metadata, boundaries: boundaries,
            derivation: derivation([(.open, 0, 8)]))
        XCTAssertEqual(ReferenceValidator.faderOpenEvidence(for: covered), .provenContinuouslyOpen)
        let short = makeEvidence(metadata: metadata, boundaries: boundaries,
            derivation: derivation([(.open, 0, 7.99)]))
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: short) else {
            return XCTFail("The selected repetition's recorded end remains required, without a 0.5s tail allowance.")
        }
    }

    func testMalformedFaderTimingCannotProveContinuousOpen() {
        let cases: [[(CrossfaderGateState, Double, Double)]] = [
            [(.open, 0, .infinity)], [(.open, .nan, 20)], [(.open, 3, 2)]
        ]
        for pieces in cases {
            let evidence = makeEvidence(metadata: makeMetadata(technique: .tear), derivation: derivation(pieces))
            guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
                return XCTFail("Invalid timing must fail closed.")
            }
        }
    }

    func testBabyScratchNeverFailsForCrossfaderEvidenceMissingWhenMovementIsSimplyZero() {
        // Zero cut-family events, zero movement — exactly a correct baby
        // scratch. The fader's OPEN state is still proven by its intervals.
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 20)], events: [])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(
            report.findings.contains(.crossfaderEvidenceMissing),
            "an open-fader technique must not be failed for the absence of fader MOVEMENT"
        )
        XCTAssertTrue(report.passes, report.failureMessages.description)
    }

    func testBabyScratchWithAClosedIntervalFails() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 5), (.closed, 5, 6), (.open, 6, 20)])
        )
        XCTAssertEqual(
            ReferenceValidator.faderOpenEvidence(for: evidence),
            .provenClosedAtSomePoint(closedIntervalCount: 1)
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("open") },
            report.failureMessages.description
        )
    }

    /// The third state. No derivation at all means the fader was never
    /// measured — which is NOT the same as measured-and-open, and must not
    /// silently pass.
    func testBabyScratchWithNoCalibratedReadingIsBlockedAsUnknownNotPassed() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            crossfaderSampleCount: 0,
            derivation: CrossfaderDerivation(intervals: [], events: [])
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("no intervals must classify as unknown")
        }
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes, "unknown must never silently pass")
        XCTAssertTrue(
            report.findings.contains { finding in
                if case .faderOpenStateUnknown = finding { return true }
                return false
            },
            report.failureMessages.description
        )
    }

    /// A reading that only starts well into the take says nothing about the
    /// take's start, so it is unknown rather than open.
    func testABaselineThatArrivesTooLateIsUnknown() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 4.0, 20)])
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("a late first reading must classify as unknown")
        }
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testRawObservationsArePreservedAndNoEventsAreFabricated() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            crossfaderSampleCount: 25,
            derivation: derivation([(.open, 0, 20)], events: [])
        )
        XCTAssertEqual(evidence.crossfaderRawSamples.count, 25)
        XCTAssertTrue(
            evidence.derivation?.events.isEmpty ?? false,
            "validation must not invent fader events to satisfy a requirement"
        )
    }

    // MARK: Clicked techniques are NOT weakened

    func testAClickedTechniqueStillFailsWithNoCrossfaderEvidence() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .flare(.oneClick)),
            crossfaderSampleCount: 0,
            derivation: derivation([(.open, 0, 20)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.findings.contains(.crossfaderEvidenceMissing),
            "a technique that requires cuts still requires fader evidence"
        )
        XCTAssertFalse(report.passes)
    }

    func testAConfirmedClickedTechniqueStillEnforcesItsMinimumCutCount() {
        let metadata = makeMetadata(technique: .flare(.twoClick))
        let expectation = ReferenceTechnique.flare(.twoClick)
            .defaultFaderExpectation
            .confirmed(by: "CXL", at: Date(timeIntervalSince1970: 1_788_000_000))
        // One cut in a repetition that requires two.
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 4.1, 4.2)]
            )
        )
        let report = ReferenceValidator.validate(evidence, expectation: expectation)
        XCTAssertTrue(
            report.findings.contains { finding in
                if case .insufficientCutEvents = finding { return true }
                return false
            },
            report.failureMessages.description
        )
    }

    // MARK: - Watch evidence states (D1)

    func testAbsentOptionalWatchWarnsWithoutBlockingOtherwiseValidReference() {
        var metadata = makeMetadata(technique: .babyScratch)
        metadata.deviceInfo = .init(platform: "fixture", appVersion: "1", controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII", audioDeviceName: nil, videoDeviceName: nil, watchLinked: false)
        for source in [ReferencePerTakeSourceState.notRequested(policy: "Optional Watch"), .unavailable(policy: "No Watch connected")] {
            metadata.sourceState = source
            let evidence = makeEvidence(metadata: metadata, watchEvidence: .missing(syncState: "unavailable"))
            let report = ReferenceValidator.validate(evidence)
            XCTAssertTrue(report.passes, report.failureMessages.joined(separator: "; "))
            XCTAssertTrue(report.findings.contains(.watchEvidenceMissing))
            XCTAssertEqual(ReferenceValidationFinding.watchEvidenceMissing.severity, .warning)
        }
    }

    func testMissingWatchCannotHideClaimedOrConflictingSource() {
        let evidence = makeEvidence(metadata: makeMetadata(), watchEvidence: .missing(syncState: "notRequested"))
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(report.findings.contains(.watchEvidenceStateInconsistent))
    }

    func testAPendingWatchTransferBlocksButIsReportedAsPendingNotMissing() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .acknowledgedTransferPending
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(report.findings.contains(.watchEvidenceTransferPending))
        XCTAssertFalse(report.findings.contains(.watchEvidenceMissing))
        XCTAssertFalse(report.passes, "approval stays blocked while the transfer is in flight")
    }

    func testAFailedWatchTransferBlocks() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .transferFailed(detail: "synthetic failure.")
        )
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testMismatchedWatchIdentityBlocks() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .identityMismatch(expected: "s/take-001", found: "s/take-002")
        )
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testLinkedWatchEvidencePasses() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .linked(motionFileName: "scratch-motion.json")
        )
        XCTAssertTrue(ReferenceValidator.validate(evidence).passes)
    }
}

final class ReferenceCaptureIntentTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    private func beat(
        version: Int = 1,
        bpm: Int = 90,
        masterFile: String = "pilot-master.wav",
        analysisFile: String = "pilot-analysis.wav",
        loopStart: Int64 = 192_000,
        masterHash: String? = nil,
        role: ReferenceBeatMixRole = .productionMaster
    ) -> ReferenceBeatSpecBinding {
        ReferenceBeatSpecBinding(
            id: "scratchlab.pilot.boom-bap-swing-90",
            version: version,
            family: "boom-bap",
            bpm: bpm,
            feel: .swing,
            countInFrameCount: 192_000,
            loopStartFrame: loopStart,
            loopFrameCount: 384_000,
            sampleRate: 48_000,
            productionMasterFileName: masterFile,
            productionMasterSHA256: masterHash ?? hashA,
            sparseAnalysisMixFileName: analysisFile,
            sparseAnalysisMixSHA256: hashB,
            availableStemSHA256: ["drums.wav": hashA],
            mixRole: role,
            rightsState: .procedurallyGeneratedOriginal,
            provenance: "Generated by ScratchLabBeatEngine recipe v1."
        )
    }

    private func intent(beat: ReferenceBeatSpecBinding? = nil) -> ReferenceCaptureIntent {
        ReferenceCaptureIntent(
            id: "authoring.intent.v1",
            parentTechniqueID: ReferenceTechnique.tear.id,
            variantID: "tear.tear_1bar.forward.faderOpenThroughout.right",
            recipeID: "tear_1bar",
            startingPlatterDirection: .forward,
            faderForm: .faderOpenThroughout,
            bpm: 90,
            beatsPerCycle: 4,
            plan: .init(countInBars: 1, repetitionCount: 4, tailBars: 1),
            beatSpec: beat
        )
    }

    private func metadata(intent: ReferenceCaptureIntent?) -> ReferenceTakeMetadata {
        ReferenceTakeMetadata(
            referenceTakeID: "authoring-take-001",
            authoringSessionID: "authoring",
            takeNumber: 1,
            operatorName: "Karl",
            technique: .tear,
            pattern: .init(id: "tear_1bar", name: "Tear", phraseBars: 1),
            bpm: 90,
            startingPlatterDirection: .forward,
            faderVariant: .faderOpenThroughout,
            captureIntent: intent,
            referenceVersion: 1,
            crossfaderCalibration: nil,
            deviceInfo: .init(
                platform: "macOS",
                appVersion: "1",
                controllerName: "RANE",
                controllerIdentifier: "midi_rane",
                audioDeviceName: nil,
                videoDeviceName: nil,
                watchLinked: false
            ),
            recordedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    func testExactBeatIntentPersistsThroughConfigSidecarAndMetadataRoundTrip() throws {
        let captureIntent = intent(beat: beat())
        XCTAssertTrue(ReferenceCaptureIntentValidator.issues(
            intent: captureIntent,
            metadata: metadata(intent: captureIntent),
            requireBeatSpec: true
        ).isEmpty)

        let config = CaptureSessionConfig(referenceCaptureIntent: captureIntent)
        let folder = FileManager.default.temporaryDirectory
        let files = CaptureCore.LocalRecordingFiles(
            baseName: "take",
            mediaURL: folder.appendingPathComponent("take.mov"),
            sidecarURL: folder.appendingPathComponent("take.json")
        )
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: "authoring",
            sessionConfig: config,
            takeIdentity: .init(sessionID: "authoring", takeID: "take-001", takeNumber: 1),
            files: files,
            recordingRole: "reference_authoring",
            platform: "macOS",
            appSurface: "reference_authoring",
            sourceDeviceName: "Synthetic",
            startedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedSidecar = try decoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: sidecar.encodedData()
        )
        XCTAssertEqual(decodedSidecar.sessionConfig?.referenceCaptureIntent, captureIntent)

        let decodedMetadata = try JSONDecoder().decode(
            ReferenceTakeMetadata.self,
            from: JSONEncoder().encode(metadata(intent: captureIntent))
        )
        XCTAssertEqual(decodedMetadata.captureIntent, captureIntent)
    }

    func testLegacyDocumentsDecodeWithExplicitlyAbsentIntent() throws {
        let encoded = try JSONEncoder().encode(metadata(intent: nil))
        let decoded = try JSONDecoder().decode(ReferenceTakeMetadata.self, from: encoded)
        XCTAssertNil(decoded.captureIntent)
        XCTAssertEqual(
            ReferenceCaptureIntentValidator.issues(
                intent: decoded.captureIntent,
                metadata: decoded,
                requireBeatSpec: true
            ),
            [.missingIntent]
        )
    }

    func testBeatSpecRejectsVersionFilenameRoleFrameAndHashDrift() {
        let variants: [(String, ReferenceBeatSpecBinding)] = [
            ("beat.identity", beat(version: 0)),
            ("beat.fileName", beat(analysisFile: "pilot-master.wav")),
            ("beat.mixRole", beat(role: .sparseAnalysis)),
            ("beat.frameContract", beat(loopStart: 192_001)),
            ("beat.hash", beat(masterHash: "ABC")),
        ]
        for (field, changed) in variants {
            let issues = ReferenceCaptureIntentValidator.issues(
                intent: intent(beat: changed),
                requireBeatSpec: true
            )
            XCTAssertTrue(issues.contains {
                if case .invalid(let actual, _) = $0 { return actual == field }
                if case .mismatch(let actual, _, _) = $0 { return actual == field }
                return false
            }, "Expected \(field), got \(issues)")
        }
    }

    func testMetadataAndBeatBPMMismatchesFailClosed() {
        let bound = intent(beat: beat(bpm: 91))
        let issues = ReferenceCaptureIntentValidator.issues(
            intent: bound,
            metadata: metadata(intent: bound),
            requireBeatSpec: true
        )
        XCTAssertTrue(issues.contains {
            if case .mismatch(let field, _, _) = $0 { return field == "beat.bpm" }
            return false
        })
    }
}

// MARK: - Canonical tear projection

/// The bridge from tear-segmentation evidence into `ScratchNotation.GestureRecord`.
///
/// These tests are the guarantee that a Tear is DRAWN as a tear: same-direction
/// subdivisions separated by horizontal internal holds, N holds and N+1 moving
/// subdivisions, a physical reversal ending the gesture rather than becoming a
/// hold, and fader clicks staying fader evidence. Everything is synthetic; no
/// physical take is read.
final class ReferenceTearCanonicalProjectionTests: XCTestCase {

    /// Gesture-relative controller telemetry, the only coordinate the
    /// projection will claim as platter revolutions. Forward runs rise from
    /// the run's own baseline; backward runs return to it.
    private func controllerRun(
        start: Double,
        end: Double,
        direction: String,
        excursion: Double,
        confidence: Double = 1,
        movementKind: ScratchMovementKind? = nil,
        source: String = "controller"
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        let forward = direction == "forward"
        return CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: start,
            endTime: end,
            startPosition: forward ? 0 : excursion,
            endPosition: forward ? excursion : 0,
            direction: direction,
            movementKind: movementKind ?? (forward ? .normalPush : .normalPull),
            speed: excursion / max(1e-6, end - start),
            confidence: confidence,
            source: source
        )
    }

    private func derivation(
        openFrom: Double,
        to end: Double,
        clicks: [(CrossfaderSemanticEventKind, Double, Double)] = []
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .open,
                    startTime: openFrom,
                    endTime: end,
                    startPosition: 1,
                    endPosition: 1
                )
            ],
            events: clicks.map {
                CrossfaderSemanticEvent(
                    kind: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    fromPosition: 1,
                    toPosition: 0
                )
            }
        )
    }

    /// forward → bounded hold → SAME-direction forward.
    private var tearEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10)
        ]
    }

    private func project(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent],
        derivation: CrossfaderDerivation? = nil
    ) -> ReferenceTearCanonicalProjection {
        ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: events,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(events),
            derivation: derivation,
            referenceTakeID: "synthetic-tear"
        )
    }

    func testMoveHoldSameDirectionMoveProducesTwoSubdivisionsAndOneHorizontalHold() throws {
        let projection = project(tearEvents)
        XCTAssertEqual(projection.records.count, 1, "One same-direction gesture, not two strokes.")
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertTrue(
            record.motionValidationIssues().isEmpty,
            "Issues: \(record.motionValidationIssues())"
        )
        XCTAssertEqual(record.direction, .forward)
        XCTAssertEqual(record.subdivisions.count, 2)
        XCTAssertEqual(record.internalHolds.count, 1)
        // The canonical invariant, derived from structure and never stored.
        XCTAssertEqual(record.subdivisions.count, record.internalHolds.count + 1)
        XCTAssertEqual(record.tearLabel, "tear1")

        let hold = try XCTUnwrap(record.internalHolds.first)
        XCTAssertEqual(hold.span.startTime, 0.20, accuracy: 1e-9)
        XCTAssertEqual(hold.span.endTime, 0.40, accuracy: 1e-9)
        XCTAssertEqual(hold.label.effective, .stationary)
        // Horizontal: the hold sits at the position both neighbours share.
        let holdPosition = try XCTUnwrap(hold.position)
        XCTAssertEqual(holdPosition, 0.10, accuracy: 1e-9)
        XCTAssertEqual(record.subdivisions[0].measuredCurve?.endPosition, holdPosition)
        XCTAssertEqual(record.subdivisions[1].measuredCurve?.startPosition, holdPosition)
        // Measured durations survive, unrounded.
        XCTAssertEqual(record.subdivisions[0].span.duration, 0.20, accuracy: 1e-9)
        XCTAssertEqual(record.subdivisions[1].span.duration, 0.20, accuracy: 1e-9)
    }

    func testTheHoldRendersAsAHorizontalSegmentThroughTheSharedGeometry() throws {
        let projection = project(tearEvents, derivation: derivation(openFrom: 0, to: 0.60))
        let frame = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: 0...0.60,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: projection.coordinateSpace,
                beatsPerMinute: 95
            )
        )
        let geometry = ScratchStrokeGeometry.canonicalGeometry(
            records: projection.records,
            layer: .performance,
            frame: frame
        )
        XCTAssertTrue(geometry.missingMotion.isEmpty, "Every interval must be placed.")
        let holds = geometry.motion.segments.filter(\.isHold)
        XCTAssertEqual(holds.count, 1, "Exactly one internal tear hold.")
        let hold = try XCTUnwrap(holds.first)
        XCTAssertEqual(hold.travel, 0, accuracy: 1e-9, "A tear hold must be horizontal.")
        XCTAssertEqual(hold.startTime, 0.20, accuracy: 1e-9)
        XCTAssertEqual(hold.endTime, 0.40, accuracy: 1e-9)
        // Not one uninterrupted diagonal, and not a reversal: two travel runs
        // separated by a flat hold.
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertGreaterThanOrEqual(travel.count, 2)
        XCTAssertTrue(travel.allSatisfy { $0.endPosition >= $0.startPosition },
                      "A forward tear never draws a backward slope.")
    }

    func testADirectionReversalEndsTheTearGesture() throws {
        // The backward run is longer than the reversal-confirmation window, so
        // it is a real polarity flip and not absorbed sign chatter.
        let events = [
            controllerRun(start: 0.00, end: 0.30, direction: "forward", excursion: 0.15),
            controllerRun(start: 0.40, end: 0.90, direction: "backward", excursion: 0.15)
        ]
        let projection = project(events)
        XCTAssertEqual(projection.records.count, 2, "A reversal ends the gesture; it never becomes a hold.")
        XCTAssertEqual(projection.records[0].direction, .forward)
        XCTAssertEqual(projection.records[1].direction, .backward)
        XCTAssertTrue(projection.records.allSatisfy { $0.internalHolds.isEmpty })
        XCTAssertTrue(projection.records.allSatisfy { $0.tearLabel == nil })
    }

    // MARK: - Tear topology (continuous platter trajectory)

    private func firstSubdivisionStart(_ record: ScratchNotation.GestureRecord) -> Double? {
        record.subdivisions.first?.measuredCurve?.startPosition
    }

    private func lastSubdivisionEnd(_ record: ScratchNotation.GestureRecord) -> Double? {
        record.subdivisions.last?.measuredCurve?.endPosition
    }

    /// A Tear subdivision is NOT a new platter origin. A clean forward →
    /// backward turnaround must depart from the physical apex the forward run
    /// ended on, so the shared apex cannot be re-anchored to zero.
    func testADirectionReversalPreservesOnePositionContinuousApex() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.30, direction: "forward", from: 0.0, to: 0.5),
            normalizedRun(start: 0.30, end: 0.90, direction: "backward", from: 0.5, to: 0.0)
        ]
        let projection = project(events)

        XCTAssertEqual(projection.records.count, 2)
        let forward = projection.records[0]
        let backward = projection.records[1]
        XCTAssertEqual(forward.direction, .forward)
        XCTAssertEqual(backward.direction, .backward)

        // The apex is one physical position: forward's terminal equals
        // backward's initial, not a fresh zero-anchored ramp.
        let forwardApex = try XCTUnwrap(lastSubdivisionEnd(forward))
        let backwardApex = try XCTUnwrap(firstSubdivisionStart(backward))
        XCTAssertEqual(forwardApex, 0.5, accuracy: 1e-9)
        XCTAssertEqual(backwardApex, 0.5, accuracy: 1e-9)

        // The combined track is one continuous up-down V, not two diagonal
        // ramps separated by a teleport back to the origin.
        let track = rescaledToOwnSpan(positionTrack(projection))
        let expected = [0.0, 1.0, 1.0, 0.0]
        XCTAssertEqual(track.count, expected.count)
        for (a, b) in zip(track, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    /// forward → bounded hold → forward, but the second run DEPARTS from the
    /// first run's terminal position (0.6), not from a fresh origin.
    func testAForwardTearArticulationKeepsOneContinuousPosition() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.20, direction: "forward", from: 0.3, to: 0.6),
            normalizedRun(start: 0.40, end: 0.60, direction: "forward", from: 0.6, to: 0.9)
        ]
        let projection = project(events)

        XCTAssertEqual(projection.records.count, 1)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.direction, .forward)
        XCTAssertEqual(record.subdivisions.count, 2)
        XCTAssertEqual(record.internalHolds.count, 1)

        // The hold sits at the continuous apex (0.6), not the per-run
        // excursion (0.3).
        let holdPosition = try XCTUnwrap(record.internalHolds.first?.position)
        XCTAssertEqual(holdPosition, 0.6, accuracy: 1e-9)

        // The two subdivisions share one boundary and preserve the absolute
        // start of the gesture.
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[0].measuredCurve?.startPosition), 0.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[0].measuredCurve?.endPosition), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[1].measuredCurve?.startPosition), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[1].measuredCurve?.endPosition), 0.9, accuracy: 1e-9)
    }

    /// The mirror image: backward → bounded hold → backward stays one continuous
    /// descending trajectory instead of two zero-anchored negative ramps.
    func testAReverseTearArticulationKeepsOneContinuousPosition() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.20, direction: "backward", from: 0.9, to: 0.6),
            normalizedRun(start: 0.40, end: 0.60, direction: "backward", from: 0.6, to: 0.3)
        ]
        let projection = project(events)

        XCTAssertEqual(projection.records.count, 1)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.direction, .backward)
        XCTAssertEqual(record.subdivisions.count, 2)
        XCTAssertEqual(record.internalHolds.count, 1)

        let holdPosition = try XCTUnwrap(record.internalHolds.first?.position)
        XCTAssertEqual(holdPosition, 0.6, accuracy: 1e-9)

        XCTAssertEqual(try XCTUnwrap(record.subdivisions[0].measuredCurve?.startPosition), 0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[0].measuredCurve?.endPosition), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[1].measuredCurve?.startPosition), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.subdivisions[1].measuredCurve?.endPosition), 0.3, accuracy: 1e-9)
    }

    /// A clover tear: forward hold forward, then a direct reversal into a
    /// backward hold backward. The ascent apex must be the descent's starting
    /// position, so the whole gesture is one continuous up-then-down shape.
    func testACloverTearPreservesTheAscentApexIntoTheDescent() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.15, direction: "forward", from: 0.00, to: 0.25),
            normalizedRun(start: 0.20, end: 0.35, direction: "forward", from: 0.25, to: 0.50),
            normalizedRun(start: 0.35, end: 0.50, direction: "backward", from: 0.50, to: 0.25),
            normalizedRun(start: 0.55, end: 0.70, direction: "backward", from: 0.25, to: 0.00)
        ]
        let projection = project(events)

        XCTAssertEqual(projection.records.count, 2)
        let forward = projection.records[0]
        let backward = projection.records[1]
        XCTAssertEqual(forward.direction, .forward)
        XCTAssertEqual(backward.direction, .backward)

        // The ascent apex and descent start are one physical position (0.50).
        let forwardApex = try XCTUnwrap(lastSubdivisionEnd(forward))
        let backwardStart = try XCTUnwrap(firstSubdivisionStart(backward))
        XCTAssertEqual(forwardApex, 0.50, accuracy: 1e-9)
        XCTAssertEqual(backwardStart, 0.50, accuracy: 1e-9)

        let track = rescaledToOwnSpan(positionTrack(projection))
        let expected = [0.0, 0.5, 0.5, 1.0, 1.0, 0.5, 0.5, 0.0]
        XCTAssertEqual(track.count, expected.count)
        for (a, b) in zip(track, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    /// A brief backward twitch (0.30 → 0.29) between two forward runs is
    /// absorbed as sign chatter; the following forward run must still join the
    /// measured trajectory, not re-anchor to zero.
    func testAbsorbedChatterDoesNotReAnchorTheFollowingSameDirectionRamp() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.20, direction: "forward", from: 0.00, to: 0.30),
            normalizedRun(start: 0.20, end: 0.25, direction: "backward", from: 0.30, to: 0.29),
            normalizedRun(start: 0.25, end: 0.60, direction: "forward", from: 0.29, to: 0.59)
        ]
        let projection = project(events)

        XCTAssertEqual(projection.records.count, 2)
        XCTAssertEqual(projection.records.map(\.direction), [.forward, .forward])

        let firstEnd = try XCTUnwrap(lastSubdivisionEnd(projection.records[0]))
        let secondStart = try XCTUnwrap(firstSubdivisionStart(projection.records[1]))

        // The second ramp departs from the measured 0.29, not from zero; the
        // 0.01 gap is exactly the absorbed chatter dip and stays unknown.
        XCTAssertEqual(firstEnd, 0.30, accuracy: 1e-9)
        XCTAssertEqual(secondStart, 0.29, accuracy: 1e-9)
    }

    /// The live preview and finalized review must draw the same REVERSAL
    /// topology: each records a forward-then-backward with a shared apex in
    /// its own declared unit, not two disconnected zero-anchored ramps.
    func testLiveAndFinalizedReversalShareTheSameApexAndShape() throws {
        // Live: gesture-relative calibrated revolutions.
        let liveReversal = [
            calibratedRun(start: 0.00, end: 0.30, direction: "forward", steps: 540),
            calibratedRun(start: 0.30, end: 0.90, direction: "backward", steps: 540)
        ]
        // Finalized: the same physical gesture span-normalised.
        let finalizedReversal = [
            normalizedRun(start: 0.00, end: 0.30, direction: "forward", from: 0.0, to: 0.5),
            normalizedRun(start: 0.30, end: 0.90, direction: "backward", from: 0.5, to: 0.0)
        ]
        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: liveReversal,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(liveReversal),
            derivation: nil,
            referenceTakeID: "live-preview",
            coordinates: .raneOneMKIIDirectMIDI()
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: finalizedReversal,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(finalizedReversal),
            derivation: derivation(openFrom: 0, to: 0.90),
            referenceTakeID: "ref-take-0008",
            coordinates: .normalizedTakeLocal()
        )

        // Each states its own unit.
        XCTAssertEqual(live.coordinateSpace, .platterRevolutions)
        XCTAssertEqual(finalized.coordinateSpace, .normalizedTakeLocalDisplacement)

        // Same reversal topology: forward then backward.
        XCTAssertEqual(live.records.count, 2)
        XCTAssertEqual(finalized.records.count, 2)
        XCTAssertEqual(live.records.map(\.direction), finalized.records.map(\.direction))

        // The apex is shared WITHIN each projection (the audited defect).
        for projection in [live, finalized] {
            let forwardApex = try XCTUnwrap(lastSubdivisionEnd(projection.records[0]))
            let backwardApex = try XCTUnwrap(firstSubdivisionStart(projection.records[1]))
            XCTAssertEqual(forwardApex, backwardApex, "reversal must not reset to zero")
        }

        // Same drawn V shape in each unit.
        let liveTrack = rescaledToOwnSpan(positionTrack(live))
        let finalizedTrack = rescaledToOwnSpan(positionTrack(finalized))
        XCTAssertEqual(liveTrack.count, finalizedTrack.count)
        for (a, b) in zip(liveTrack, finalizedTrack) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    func testFaderClicksNeverIncrementTheTearHoldCount() throws {
        let clicked = derivation(
            openFrom: 0,
            to: 0.60,
            clicks: [(.cut, 0.25, 0.27), (.transformPulse, 0.45, 0.47)]
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents),
            derivation: clicked
        )
        XCTAssertEqual(review.totalCountedTearHoldCount, 1, "Two fader clicks add no platter holds.")

        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.internalHolds.count, 1)
        XCTAssertEqual(record.tearLabel, "tear1")
        // Clicks appear as FADER evidence — glyphs, not holds.
        XCTAssertEqual(record.faderTransitions.count, 2)
        XCTAssertTrue(record.faderValidationIssues().isEmpty,
                      "Issues: \(record.faderValidationIssues())")
        XCTAssertTrue(projection.reasons.contains(.faderClicksCitedNotCounted))
    }

    func testUnobservedFaderStaysUnknownAndIsNeverDrawnAsOpen() throws {
        let projection = project(tearEvents)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertTrue(record.faderIntervals.isEmpty, "No observation means no rail, never an assumed open one.")
        XCTAssertTrue(projection.reasons.contains(.faderUnobserved))
    }

    func testClosedFaderTravelIsProjectedAsAGhostRegionNotASoundingStroke() throws {
        let closed = CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .closed,
                    startTime: 0,
                    endTime: 0.60,
                    startPosition: 0,
                    endPosition: 0
                )
            ],
            events: []
        )
        let projection = project(tearEvents, derivation: closed)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.faderIntervals.count, 1)
        XCTAssertEqual(record.faderIntervals.first?.state, .closed)
        XCTAssertTrue(projection.reasons.contains(.ghostMovementPresent))
    }

    func testFreePlaybackIsNeverFlattenedIntoAnOrdinaryStroke() throws {
        let events = [
            controllerRun(
                start: 0.00,
                end: 0.40,
                direction: "forward",
                excursion: 0.20,
                movementKind: .releaseNormalPlayback
            )
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(
            record.motionValidationIssues().isEmpty,
            "Released playback carries no gesture polarity and must not validate as travel."
        )
        XCTAssertTrue(projection.reasons.contains(.releasedPlaybackPresent))
    }

    func testLowConfidenceEvidenceIsProjectedAsUnknown() throws {
        let events = [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10, confidence: 0.2),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10, confidence: 0.2)
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(record.motionValidationIssues().isEmpty)
        XCTAssertTrue(projection.reasons.contains(.lowMovementConfidence))
    }

    func testNonControllerCoordinatesAreProjectedAsUnknownRatherThanClaimedAsRevolutions() throws {
        let events = [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10, source: "video"),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10, source: "video")
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(record.motionValidationIssues().isEmpty)
        XCTAssertTrue(projection.reasons.contains(.unsupportedCoordinateSpace))
    }

    /// The live preview and the finalized review must not disagree about a
    /// gesture's structure. Both go through the SAME projection; only the
    /// fader stream differs, because a live preview has no committed
    /// derivation yet.
    func testLiveAndFinalizedProjectionsShareTheSameCanonicalStructure() throws {
        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: tearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents),
            derivation: nil,
            referenceTakeID: "live-preview"
        )
        let finalizedReview = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0008",
            movementEvents: tearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents),
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(finalizedReview)

        XCTAssertEqual(live.records.count, finalized.records.count)
        XCTAssertEqual(live.coordinateSpace, finalized.coordinateSpace)
        for (liveRecord, finalRecord) in zip(live.records, finalized.records) {
            XCTAssertEqual(liveRecord.direction, finalRecord.direction)
            XCTAssertEqual(liveRecord.subdivisions.map(\.span), finalRecord.subdivisions.map(\.span))
            XCTAssertEqual(liveRecord.internalHolds.map(\.span), finalRecord.internalHolds.map(\.span))
            XCTAssertEqual(liveRecord.internalHolds.map(\.position), finalRecord.internalHolds.map(\.position))
            XCTAssertEqual(liveRecord.tearLabel, finalRecord.tearLabel)
            XCTAssertEqual(
                liveRecord.subdivisions.compactMap { $0.measuredCurve?.points.map(\.position) },
                finalRecord.subdivisions.compactMap { $0.measuredCurve?.points.map(\.position) }
            )
        }
        // The one legitimate difference: the finalized take has fader evidence.
        XCTAssertTrue(live.records.allSatisfy { $0.faderIntervals.isEmpty })
        XCTAssertTrue(finalized.records.allSatisfy { !$0.faderIntervals.isEmpty })
    }

    func testAnOperatorRemovedHoldRepartitionsTheGestureAndKeepsTheInvariant() throws {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents),
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let candidate = try XCTUnwrap(review.candidates.first)
        let boundary = try XCTUnwrap(candidate.boundaries.first)
        XCTAssertTrue(
            review.setBoundaryRemoved(
                inCandidate: candidate.id,
                boundaryID: boundary.id,
                removed: true,
                correction: ReferenceTearCorrection(
                    correctedBy: "Karl",
                    correctedAt: Date(timeIntervalSince1970: 1_788_000_600),
                    notes: "not a hold",
                    reason: "test"
                )
            )
        )
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.internalHolds.count, 0, "A struck-out boundary contributes no hold.")
        XCTAssertEqual(record.subdivisions.count, 1, "N holds still require N+1 subdivisions.")
        XCTAssertNil(record.tearLabel)
        XCTAssertTrue(record.motionValidationIssues().isEmpty,
                      "Issues: \(record.motionValidationIssues())")
    }

    // MARK: - Coordinate contract

    /// One decoder run projected the way the LIVE path projects it: raw CC6
    /// step displacement divided by a stated steps-per-revolution.
    private func calibratedRun(
        start: Double,
        end: Double,
        direction: String,
        steps: Double
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        let signed = direction == "forward" ? steps : -steps
        let coordinates = PlatterCoordinateSemantics.gestureRelativeNotation(
            signedDisplacementSteps: signed
        )
        return CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: start,
            endTime: end,
            startPosition: coordinates.startPosition,
            endPosition: coordinates.endPosition,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: steps / max(1e-6, end - start),
            confidence: 1,
            source: "controller"
        )
    }

    /// The same run as FINALIZATION persists it: `decodePlatterCore`
    /// span-normalises the integrated position over the take's own range, so
    /// the endpoints are 0…1 fractions of this take and nothing else.
    private func normalizedRun(
        start: Double,
        end: Double,
        direction: String,
        from startPosition: Double,
        to endPosition: Double
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: start,
            endTime: end,
            startPosition: startPosition,
            endPosition: endPosition,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: abs(endPosition - startPosition) / max(1e-6, end - start),
            confidence: 1,
            source: "controller"
        )
    }

    /// forward 540 steps → bounded hold → forward 360 steps.
    private var calibratedTearEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            calibratedRun(start: 0.00, end: 0.20, direction: "forward", steps: 540),
            calibratedRun(start: 0.40, end: 0.60, direction: "forward", steps: 360)
        ]
    }

    /// The identical physical gesture after span normalisation over the take's
    /// own integrated range (0 → 540 → 900 steps, span 900).
    private var normalizedTearEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            normalizedRun(start: 0.00, end: 0.20, direction: "forward", from: 0.0, to: 0.6),
            normalizedRun(start: 0.40, end: 0.60, direction: "forward", from: 0.6, to: 1.0)
        ]
    }

    private func positionTrack(
        _ projection: ReferenceTearCanonicalProjection
    ) -> [Double] {
        projection.records.flatMap { record in
            record.subdivisions.compactMap(\.measuredCurve).flatMap { $0.points.map(\.position) }
        }
    }

    /// Positions rescaled onto their own 0…1 span, which is exactly what the
    /// renderer's `CanonicalFrame` does at draw time. Two tracks that agree
    /// here draw the same shape whatever unit each is measured in.
    private func rescaledToOwnSpan(_ positions: [Double]) -> [Double] {
        guard let low = positions.min(), let high = positions.max(), high > low else {
            return positions.map { _ in 0 }
        }
        return positions.map { ($0 - low) / (high - low) }
    }

    /// The audited defect: a finalized take's positions are span-normalised
    /// over that take's own range, and the projection used to hand them to a
    /// record whose declared space said "platter revolutions".
    func testFinalizedNormalizedPositionsAreNeverLabelledPlatterRevolutions() throws {
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0008",
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            coordinates: .normalizedTakeLocal()
        )
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)

        XCTAssertEqual(projection.coordinateSpace, .normalizedTakeLocalDisplacement)
        XCTAssertNotEqual(projection.coordinateSpace, .platterRevolutions)
        XCTAssertTrue(
            projection.records.allSatisfy { $0.coordinateSpace == .normalizedTakeLocalDisplacement },
            "Every record must carry the space its positions are actually in."
        )
        XCTAssertTrue(projection.reasons.contains(.gestureLocalNormalizedDisplacement))
        XCTAssertFalse(
            projection.reasons.contains(.gestureLocalPlatterRevolutions),
            "An uncalibrated take must not state a revolution unit."
        )
        // Uncertainty stays stated, not silently dropped.
        XCTAssertTrue(review.reasons.contains(.uncalibratedPlatterCoordinates))
        // The structure itself is unaffected: this is a units repair, not a
        // segmentation change.
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.subdivisions.count, 2)
        XCTAssertEqual(record.internalHolds.count, 1)
        XCTAssertEqual(record.tearLabel, "tear1")
    }

    func testCalibratedInputIsProjectedAsPlatterRevolutionsAndStatesItsReference() throws {
        let coordinates = CaptureCore.PlatterNotationCoordinates.raneOneMKIIDirectMIDI()
        XCTAssertTrue(coordinates.isCalibrated)
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "live-preview",
            movementEvents: calibratedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(calibratedTearEvents),
            derivation: nil,
            coordinates: coordinates
        )
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)

        XCTAssertEqual(projection.coordinateSpace, .platterRevolutions)
        XCTAssertTrue(projection.reasons.contains(.gestureLocalPlatterRevolutions))
        XCTAssertFalse(projection.reasons.contains(.gestureLocalNormalizedDisplacement))
        XCTAssertFalse(
            review.reasons.contains(.uncalibratedPlatterCoordinates),
            "A calibrated basis must not also claim its coordinates are uncalibrated."
        )
        XCTAssertTrue(
            review.platterCoordinates.reference.contains("3600.0")
                || review.platterCoordinates.reference.contains("steps per revolution"),
            "The calibration reference must be stated: \(review.platterCoordinates.reference)"
        )
        // 540 steps / 3600 steps-per-revolution = 0.15 revolutions.
        let hold = try XCTUnwrap(projection.records.first?.internalHolds.first?.position)
        XCTAssertEqual(hold, 0.15, accuracy: 1e-9)
    }

    /// A calibration is never invented. An unusable steps-per-revolution must
    /// fail CLOSED to the take-local basis with the reason stated, never to a
    /// silent revolution claim.
    func testARevolutionClaimCannotBeMadeWithoutAUsableReference() {
        XCTAssertNil(
            CaptureCore.PlatterNotationCoordinates.calibratedRevolutions(
                stepsPerRevolution: 0,
                reference: "anything"
            )
        )
        XCTAssertNil(
            CaptureCore.PlatterNotationCoordinates.calibratedRevolutions(
                stepsPerRevolution: .nan,
                reference: "anything"
            )
        )
        XCTAssertNil(
            CaptureCore.PlatterNotationCoordinates.calibratedRevolutions(
                stepsPerRevolution: 3600,
                reference: "   "
            )
        )
        let failedClosed = CaptureCore.PlatterNotationCoordinates
            .raneOneMKIIDirectMIDI(stepsPerRevolution: 0)
        XCTAssertFalse(failedClosed.isCalibrated)
        XCTAssertEqual(failedClosed.coordinateSpace, .normalizedTakeLocalDisplacement)
        XCTAssertTrue(failedClosed.reference.contains("cannot"))
    }

    /// Live (calibrated revolutions) and finalized (take-local normalized) are
    /// the SAME physical gesture measured in two different units. They must
    /// agree on time, grid, direction and hold structure, and must draw the
    /// same shape once each is rescaled onto its own span — which is exactly
    /// what `CanonicalFrame` does. Neither may borrow the other's unit label.
    func testLiveAndFinalizedRenderEquivalentFixturesOnTheSameTimeGridAndDirection() throws {
        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: calibratedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(calibratedTearEvents),
            derivation: nil,
            referenceTakeID: "live-preview",
            coordinates: .raneOneMKIIDirectMIDI()
        )
        let finalizedReview = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0008",
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            coordinates: .normalizedTakeLocal()
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(finalizedReview)

        // Each states its own true unit — and they are different units.
        XCTAssertEqual(live.coordinateSpace, .platterRevolutions)
        XCTAssertEqual(finalized.coordinateSpace, .normalizedTakeLocalDisplacement)

        // Same time grid.
        XCTAssertEqual(live.timeRange, finalized.timeRange)
        XCTAssertEqual(live.records.count, finalized.records.count)
        for (liveRecord, finalRecord) in zip(live.records, finalized.records) {
            XCTAssertEqual(liveRecord.direction, finalRecord.direction)
            XCTAssertEqual(liveRecord.timingDomain, finalRecord.timingDomain)
            XCTAssertEqual(liveRecord.subdivisions.map(\.span), finalRecord.subdivisions.map(\.span))
            XCTAssertEqual(liveRecord.internalHolds.map(\.span), finalRecord.internalHolds.map(\.span))
            XCTAssertEqual(liveRecord.tearLabel, finalRecord.tearLabel)
        }

        // Same drawn shape, in each one's own declared unit.
        let liveTrack = rescaledToOwnSpan(positionTrack(live))
        let finalizedTrack = rescaledToOwnSpan(positionTrack(finalized))
        XCTAssertEqual(liveTrack.count, finalizedTrack.count)
        for (a, b) in zip(liveTrack, finalizedTrack) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
        // The raw magnitudes really are different, so the agreement above is
        // not an accident of identical fixtures.
        XCTAssertNotEqual(
            try XCTUnwrap(live.records.first?.internalHolds.first?.position),
            try XCTUnwrap(finalized.records.first?.internalHolds.first?.position)
        )
    }

    /// Dense live and finalized projections of equivalent physical motion
    /// must retain the same measured velocity profile after each coordinate
    /// space is rescaled onto its own span. This catches either path silently
    /// falling back to endpoint-linear geometry.
    func testDenseLiveAndFinalizedProjectionsPreserveTheSameMeasuredShape() throws {
        let liveEvent = calibratedRun(
            start: 0.00, end: 0.30,
            direction: "forward",
            steps: 540
        )
        let finalizedEvent = normalizedRun(
            start: 0.00, end: 0.30,
            direction: "forward",
            from: 0.0, to: 1.0
        )

        let trajectory = CaptureCore.PlatterTrajectorySegment(
            boundaryBefore: nil,
            samples: [
                .init(takeRelativeTime: 0.00, displacementSteps: 0),
                .init(takeRelativeTime: 0.05, displacementSteps: 108),
                .init(takeRelativeTime: 0.10, displacementSteps: 216),
                .init(takeRelativeTime: 0.15, displacementSteps: 226),
                .init(takeRelativeTime: 0.20, displacementSteps: 238),
                .init(takeRelativeTime: 0.25, displacementSteps: 378),
                .init(takeRelativeTime: 0.30, displacementSteps: 540)
            ]
        )

        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: [liveEvent],
            platterTrajectorySegments: [trajectory],
            derivation: nil,
            referenceTakeID: "dense-live",
            coordinates: .raneOneMKIIDirectMIDI()
        )

        let finalized = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: [finalizedEvent],
            platterTrajectorySegments: [trajectory],
            derivation: nil,
            referenceTakeID: "dense-finalized",
            coordinates: .normalizedTakeLocal()
        )

        XCTAssertEqual(live.coordinateSpace, .platterRevolutions)
        XCTAssertEqual(finalized.coordinateSpace, .normalizedTakeLocalDisplacement)

        let liveTrack = rescaledToOwnSpan(positionTrack(live))
        let finalizedTrack = rescaledToOwnSpan(positionTrack(finalized))

        XCTAssertEqual(liveTrack.count, 7)
        XCTAssertEqual(finalizedTrack.count, 7)
        XCTAssertEqual(liveTrack.count, finalizedTrack.count)

        for (livePosition, finalizedPosition) in zip(liveTrack, finalizedTrack) {
            XCTAssertEqual(livePosition, finalizedPosition, accuracy: 1e-9)
        }

        let midpoint = try XCTUnwrap(liveTrack.indices.contains(4) ? liveTrack[4] : nil)
        XCTAssertNotEqual(
            midpoint,
            0.20 / 0.30,
            "Dense parity must preserve measured non-uniform velocity rather than endpoint interpolation."
        )
    }

    // MARK: - Dense canonical platter geometry

    func testDenseTrajectoryPreservesMeasuredNonUniformVelocity() throws {
        let event = normalizedRun(
            start: 0.00, end: 0.30,
            direction: "forward",
            from: 0.0, to: 1.0
        )
        let trajectory = CaptureCore.PlatterTrajectorySegment(
            boundaryBefore: nil,
            samples: [
                .init(takeRelativeTime: 0.00, displacementSteps: 0),
                .init(takeRelativeTime: 0.05, displacementSteps: 20),
                .init(takeRelativeTime: 0.10, displacementSteps: 40),
                .init(takeRelativeTime: 0.15, displacementSteps: 42),
                .init(takeRelativeTime: 0.20, displacementSteps: 44),
                .init(takeRelativeTime: 0.25, displacementSteps: 70),
                .init(takeRelativeTime: 0.30, displacementSteps: 100)
            ]
        )

        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: [event],
            platterTrajectorySegments: [trajectory],
            derivation: nil,
            referenceTakeID: "dense-forward",
            coordinates: .normalizedTakeLocal()
        )

        let record = try XCTUnwrap(projection.records.first)
        let curve = try XCTUnwrap(record.subdivisions.first?.measuredCurve)

        XCTAssertEqual(curve.points.count, 7)
        let measured = try XCTUnwrap(
            curve.points.first { abs($0.time - 0.20) < 1e-9 }
        )
        XCTAssertEqual(measured.position, 0.44, accuracy: 1e-9)
        XCTAssertNotEqual(
            measured.position,
            measured.time / 0.30,
            "Dense geometry must preserve measured velocity, not endpoint-linear interpolation."
        )
    }

    func testDenseTrajectoryPreservesReverseShape() throws {
        let event = normalizedRun(
            start: 0.00, end: 0.30,
            direction: "backward",
            from: 1.0, to: 0.0
        )
        let trajectory = CaptureCore.PlatterTrajectorySegment(
            boundaryBefore: nil,
            samples: [
                .init(takeRelativeTime: 0.00, displacementSteps: 0),
                .init(takeRelativeTime: 0.10, displacementSteps: -20),
                .init(takeRelativeTime: 0.20, displacementSteps: -80),
                .init(takeRelativeTime: 0.30, displacementSteps: -100)
            ]
        )

        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: [event],
            platterTrajectorySegments: [trajectory],
            derivation: nil,
            referenceTakeID: "dense-reverse",
            coordinates: .normalizedTakeLocal()
        )

        let curve = try XCTUnwrap(
            projection.records.first?.subdivisions.first?.measuredCurve
        )
        let expectedPositions = [1.0, 0.8, 0.2, 0.0]
        XCTAssertEqual(curve.points.count, expectedPositions.count)
        for (point, expected) in zip(curve.points, expectedPositions) {
            XCTAssertEqual(point.position, expected, accuracy: 1e-9)
        }
    }

    func testDenseTrajectoryDoesNotBridgeADiscontinuity() throws {
        let event = normalizedRun(
            start: 0.00, end: 0.30,
            direction: "forward",
            from: 0.0, to: 1.0
        )
        let trajectory = [
            CaptureCore.PlatterTrajectorySegment(
                boundaryBefore: nil,
                samples: [
                    .init(takeRelativeTime: 0.00, displacementSteps: 0),
                    .init(takeRelativeTime: 0.10, displacementSteps: 40)
                ]
            ),
            CaptureCore.PlatterTrajectorySegment(
                boundaryBefore: .packetGap,
                samples: [
                    .init(takeRelativeTime: 0.20, displacementSteps: 0),
                    .init(takeRelativeTime: 0.30, displacementSteps: 60)
                ]
            )
        ]

        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: [event],
            platterTrajectorySegments: trajectory,
            derivation: nil,
            referenceTakeID: "dense-gap",
            coordinates: .normalizedTakeLocal()
        )

        let curve = try XCTUnwrap(
            projection.records.first?.subdivisions.first?.measuredCurve
        )
        XCTAssertEqual(
            curve.points.count, 2,
            "No dense curve may be manufactured across a packet discontinuity."
        )
        XCTAssertEqual(curve.startPosition, 0.0)
        XCTAssertEqual(curve.endPosition, 1.0)
    }

    func testMissingDenseTrajectoryLeavesExistingProjectionUnchanged() {
        let withoutArgument = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            referenceTakeID: "sparse-existing",
            coordinates: .normalizedTakeLocal()
        )
        let explicitEmpty = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: normalizedTearEvents,
            platterTrajectorySegments: [],
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            referenceTakeID: "sparse-existing",
            coordinates: .normalizedTakeLocal()
        )

        XCTAssertEqual(withoutArgument, explicitEmpty)
    }

    /// A record whose declared space differs from the frame's is drawn as
    /// explicit MOTION UNKNOWN through the SHARED renderer — the units repair
    /// cannot silently mix two coordinates into one curve.
    func testAMismatchedCoordinateSpaceRendersAsUnknownThroughTheSharedGeometry() throws {
        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            referenceTakeID: "ref-take-0008",
            coordinates: .normalizedTakeLocal()
        )
        let matching = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: 0...0.60,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: projection.coordinateSpace,
                beatsPerMinute: 95
            )
        )
        XCTAssertTrue(
            ScratchStrokeGeometry.canonicalGeometry(
                records: projection.records, layer: .performance, frame: matching
            ).missingMotion.isEmpty
        )

        let mismatched = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: 0...0.60,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: .platterRevolutions,
                beatsPerMinute: 95
            )
        )
        let geometry = ScratchStrokeGeometry.canonicalGeometry(
            records: projection.records, layer: .performance, frame: mismatched
        )
        XCTAssertFalse(
            geometry.missingMotion.isEmpty,
            "Normalized records placed on a revolutions frame must read UNKNOWN."
        )
        XCTAssertTrue(
            geometry.motion.segments.filter(\.isHold).isEmpty,
            "An unknown region must never acquire a horizontal tear hold."
        )
    }

    /// Curve samples that contradict the gesture's direction stay UNKNOWN.
    /// They are never flattened into a horizontal hold to make the tear
    /// structure look clean.
    func testAContraryDirectionCurveStaysUnknownAndManufacturesNoHold() throws {
        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: derivation(openFrom: 0, to: 0.60),
            referenceTakeID: "ref-take-0008",
            coordinates: .normalizedTakeLocal()
        )
        let original = try XCTUnwrap(projection.records.first)
        let evidence = ScratchNotation.GestureRecord.Evidence(
            provenance: .measured,
            observation: ScratchNotationEvidence(
                source: .platterTimeline,
                confidence: 1,
                reason: "contrary_direction_fixture",
                rawSampleCount: 2
            )
        )
        // A FORWARD gesture whose first subdivision actually travels backward.
        let contrary = ScratchNotation.GestureRecord(
            id: original.id,
            direction: .forward,
            timingDomain: .seconds,
            coordinateSpace: original.coordinateSpace,
            evidence: original.evidence,
            subdivisions: [
                ScratchNotation.GestureRecord.Subdivision(
                    id: "\(original.id)#contrary",
                    span: .init(startTime: 0.0, endTime: 0.20),
                    evidence: evidence,
                    measuredCurve: ScratchNotation.GestureRecord.MotionCurve(
                        points: [
                            .init(time: 0.00, position: 0.6),
                            .init(time: 0.20, position: 0.0)
                        ],
                        evidence: evidence
                    )
                )
            ],
            internalHolds: [],
            faderTransitions: original.faderTransitions,
            faderIntervals: original.faderIntervals
        )
        let frame = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: 0...0.60,
                positionRange: 0...1,
                coordinateSpace: original.coordinateSpace,
                beatsPerMinute: 95
            )
        )
        let geometry = ScratchStrokeGeometry.canonicalGeometry(
            records: [contrary], layer: .performance, frame: frame
        )
        XCTAssertFalse(geometry.missingMotion.isEmpty, "A contrary curve must read UNKNOWN.")
        XCTAssertTrue(
            geometry.motion.segments.filter(\.isHold).isEmpty,
            "No horizontal hold may be manufactured from contrary evidence."
        )
    }

    /// The finalized boundary must DECLARE its unit at the source, not leave
    /// it to be inferred, and the projection must no longer carry a hardcoded
    /// coordinate-space constant.
    func testTheCoordinateContractIsDeclaredAtItsSourceBoundaries() throws {
        let referenceTake = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ScratchLab/Models/Reference/ReferenceTake.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            referenceTake.contains("coordinates: .normalizedTakeLocal()"),
            "build(for: evidence) must state that persisted positions are take-local."
        )
        XCTAssertFalse(
            referenceTake.contains(
                "static let coordinateSpace: ScratchNotation.GestureRecord.CoordinateSpace = .platterRevolutions"
            ),
            "The projection must not hardcode a coordinate space."
        )
        let captureCore = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ScratchLab/Models/CaptureCore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            captureCore.contains("case normalizedTakeLocalDisplacement"),
            "The normalized take-local space must exist as a named coordinate."
        )
    }

    func testAHoldRenamedAFaderClickStopsCountingWithoutDeletingAnything() throws {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents),
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let candidate = try XCTUnwrap(review.candidates.first)
        let boundary = try XCTUnwrap(candidate.boundaries.first)
        XCTAssertTrue(
            review.setBoundaryKind(
                inCandidate: candidate.id,
                boundaryID: boundary.id,
                to: .faderClick,
                correction: ReferenceTearCorrection(
                    correctedBy: "Karl",
                    correctedAt: Date(timeIntervalSince1970: 1_788_000_600),
                    notes: "fader work",
                    reason: "test"
                )
            )
        )
        XCTAssertEqual(review.totalCountedTearHoldCount, 0)
        let retained = try XCTUnwrap(review.candidates.first?.boundaries.first)
        XCTAssertNotNil(retained.proposal, "The machine proposal is retained, never deleted.")
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        XCTAssertEqual(projection.records.first?.internalHolds.count, 0)
    }

    // MARK: - Live / finalized evidence parity

    /// A derivation that genuinely CHANGES state inside the gesture, so a
    /// projection that stamped one instantaneous state over the whole span
    /// would disagree with one that placed the transition in time.
    private func openThenClosedDerivation(
        openFrom: Double,
        switchAt: Double,
        closedUntil: Double
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .open, startTime: openFrom, endTime: switchAt,
                    startPosition: 1, endPosition: 1
                ),
                CrossfaderStateInterval(
                    state: .closed, startTime: switchAt, endTime: closedUntil,
                    startPosition: 0, endPosition: 0
                )
            ],
            events: []
        )
    }

    /// SEMANTIC parity, deliberately not byte parity. The live path measures
    /// calibrated platter revolutions and a finalized take measures its own
    /// span-normalised displacement, so only unit-independent facts are
    /// compared: gesture structure, where observed platter stillness placed
    /// its holds, and what the fader evidence says over which time spans.
    private func assertSemanticParity(
        live: ReferenceTearCanonicalProjection,
        finalized: ReferenceTearCanonicalProjection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            live.records.count, finalized.records.count,
            "gesture count must not depend on which path projected it",
            file: file, line: line
        )
        guard live.records.count == finalized.records.count else { return }

        for index in live.records.indices {
            let liveRecord = live.records[index]
            let finalizedRecord = finalized.records[index]
            XCTAssertEqual(liveRecord.direction, finalizedRecord.direction,
                           "record \(index) direction", file: file, line: line)
            XCTAssertEqual(liveRecord.subdivisions.count, finalizedRecord.subdivisions.count,
                           "record \(index) subdivision count", file: file, line: line)
            XCTAssertEqual(liveRecord.tearLabel, finalizedRecord.tearLabel,
                           "record \(index) tear label", file: file, line: line)

            // Observed platter stillness must land in the same place.
            XCTAssertEqual(liveRecord.internalHolds.count, finalizedRecord.internalHolds.count,
                           "record \(index) hold count", file: file, line: line)
            guard liveRecord.internalHolds.count == finalizedRecord.internalHolds.count else { continue }
            for holdIndex in liveRecord.internalHolds.indices {
                let liveHold = liveRecord.internalHolds[holdIndex]
                let finalizedHold = finalizedRecord.internalHolds[holdIndex]
                XCTAssertEqual(liveHold.span.startTime, finalizedHold.span.startTime, accuracy: 1e-9,
                               "record \(index) hold \(holdIndex) start", file: file, line: line)
                XCTAssertEqual(liveHold.span.endTime, finalizedHold.span.endTime, accuracy: 1e-9,
                               "record \(index) hold \(holdIndex) end", file: file, line: line)
                XCTAssertEqual(liveHold.label.effective, finalizedHold.label.effective,
                               "record \(index) hold \(holdIndex) label", file: file, line: line)
            }

            // Fader evidence: same states over the same time spans.
            XCTAssertEqual(
                liveRecord.faderIntervals.map(\.state), finalizedRecord.faderIntervals.map(\.state),
                "record \(index) fader states", file: file, line: line
            )
            guard liveRecord.faderIntervals.count == finalizedRecord.faderIntervals.count else { continue }
            for faderIndex in liveRecord.faderIntervals.indices {
                let liveSpan = liveRecord.faderIntervals[faderIndex].span
                let finalizedSpan = finalizedRecord.faderIntervals[faderIndex].span
                XCTAssertEqual(liveSpan.startTime, finalizedSpan.startTime, accuracy: 1e-9,
                               "record \(index) fader \(faderIndex) start", file: file, line: line)
                XCTAssertEqual(liveSpan.endTime, finalizedSpan.endTime, accuracy: 1e-9,
                               "record \(index) fader \(faderIndex) end", file: file, line: line)
            }
        }

        XCTAssertEqual(
            live.reasons.contains(.faderUnobserved), finalized.reasons.contains(.faderUnobserved),
            "an unobserved fader must be declared by both paths or by neither",
            file: file, line: line
        )
    }

    /// The LIVE one-call projection and the FINALIZED review-then-project
    /// route must agree on where observed platter stillness placed its hold
    /// and on what the crossfader was doing, even though the live take is in
    /// calibrated revolutions and the finalized take is in its own normalised
    /// displacement.
    func testLiveAndFinalizedAgreeOnStillnessPlacementAndOpenFader() throws {
        let open = derivation(openFrom: 0, to: 0.60)

        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: calibratedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(calibratedTearEvents),
            derivation: open,
            referenceTakeID: "live-preview",
            coordinates: .raneOneMKIIDirectMIDI()
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0009",
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: open,
            coordinates: .normalizedTakeLocal()
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(review)

        // The declared units genuinely differ; the semantics must not.
        XCTAssertEqual(live.coordinateSpace, .platterRevolutions)
        XCTAssertEqual(finalized.coordinateSpace, .normalizedTakeLocalDisplacement)
        assertSemanticParity(live: live, finalized: finalized)

        // The specific facts the live card was missing before this slice.
        let liveHold = try XCTUnwrap(live.records.first?.internalHolds.first)
        XCTAssertEqual(liveHold.span.startTime, 0.20, accuracy: 1e-9)
        XCTAssertEqual(liveHold.span.endTime, 0.40, accuracy: 1e-9)
        XCTAssertEqual(liveHold.label.effective, .stationary)
        XCTAssertEqual(live.records.first?.faderIntervals.map(\.state), [.open])
        XCTAssertFalse(
            live.reasons.contains(.faderUnobserved),
            "a fully covered open interval is observed evidence, not FADER UNKNOWN"
        )
    }

    /// A real open -> closed change inside the gesture must be PLACED in time
    /// by both paths. Stamping the whole gesture with one state — the
    /// instantaneous-preflight shortcut this slice must never take — would
    /// produce a single interval here.
    func testLiveAndFinalizedAgreeOnAFaderTransitionAndNeverStampOneState() throws {
        let switching = openThenClosedDerivation(openFrom: 0, switchAt: 0.30, closedUntil: 0.60)

        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: calibratedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(calibratedTearEvents),
            derivation: switching,
            referenceTakeID: "live-preview",
            coordinates: .raneOneMKIIDirectMIDI()
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0009",
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: switching,
            coordinates: .normalizedTakeLocal()
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(review)

        assertSemanticParity(live: live, finalized: finalized)

        let record = try XCTUnwrap(live.records.first)
        XCTAssertEqual(
            record.faderIntervals.map(\.state), [.open, .closed],
            "the transition must be placed in time, not stamped from one value"
        )
        let openSpan = try XCTUnwrap(record.faderIntervals.first).span
        let closedSpan = try XCTUnwrap(record.faderIntervals.last).span
        XCTAssertEqual(openSpan.startTime, 0.00, accuracy: 1e-9)
        XCTAssertEqual(openSpan.endTime, 0.30, accuracy: 1e-9)
        XCTAssertEqual(closedSpan.startTime, 0.30, accuracy: 1e-9)
        XCTAssertEqual(closedSpan.endTime, 0.60, accuracy: 1e-9)

        // The fader changing state is fader work; it never mints a platter hold.
        XCTAssertEqual(record.internalHolds.count, 1, "still exactly the one observed stillness hold")
    }

    /// Fail closed, identically, on both paths: no derivation means no fader
    /// rails and a declared unobserved reason, never an assumed open line.
    func testLiveAndFinalizedBothStayFaderUnknownWithoutDerivation() throws {
        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: calibratedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(calibratedTearEvents),
            derivation: nil,
            referenceTakeID: "live-preview",
            coordinates: .raneOneMKIIDirectMIDI()
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0009",
            movementEvents: normalizedTearEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(normalizedTearEvents),
            derivation: nil,
            coordinates: .normalizedTakeLocal()
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(review)

        assertSemanticParity(live: live, finalized: finalized)
        XCTAssertTrue(live.records.allSatisfy { $0.faderIntervals.isEmpty })
        XCTAssertTrue(finalized.records.allSatisfy { $0.faderIntervals.isEmpty })
        XCTAssertTrue(live.reasons.contains(.faderUnobserved))
        XCTAssertTrue(finalized.reasons.contains(.faderUnobserved))

        // Missing fader evidence must not cost the platter its stillness hold.
        XCTAssertEqual(live.records.first?.internalHolds.count, 1)
        XCTAssertEqual(finalized.records.first?.internalHolds.count, 1)
    }

    // MARK: - Sample-loop notation phase (presentation-only wrap)

    /// Build the live-preview projection the way `ReferenceAuthoringView` does,
    /// then hand it to the shared canonical geometry at a stated wrap period.
    private func loopGeometry(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent],
        wrapPeriod: Double?,
        timeRange: ClosedRange<Double>
    ) throws -> (ReferenceTearCanonicalProjection, ScratchStrokeGeometry.CanonicalGeometry) {
        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: events,
            platterEvidenceIntervals: [],
            derivation: nil,
            referenceTakeID: "live-preview",
            coordinates: .normalizedTakeLocal()
        )
        let frame = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: timeRange,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: projection.coordinateSpace,
                beatsPerMinute: 95
            )
        )
        return (
            projection,
            ScratchStrokeGeometry.canonicalGeometry(
                records: projection.records,
                layer: .performance,
                frame: frame,
                wrapPeriod: wrapPeriod
            )
        )
    }

    /// Unsafe presentation arithmetic must retain the complete unwrapped
    /// geometry and its evidence instead of emitting partial loop fragments.
    private func assertUnsafeLoopFallsBackToUnwrappedGeometry(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent],
        period: Double,
        timeRange: ClosedRange<Double>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (projection, unwrapped) = try loopGeometry(events, wrapPeriod: nil, timeRange: timeRange)
        let originalRecords = projection.records
        XCTAssertFalse(originalRecords.isEmpty, "the fixture must contain measured motion", file: file, line: line)
        XCTAssertTrue(originalRecords.allSatisfy { $0.motionValidationIssues().isEmpty },
                      "valid evidence must reach the numeric wrapping guard", file: file, line: line)
        XCTAssertFalse(unwrapped.motion.segments.isEmpty, file: file, line: line)
        let frame = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: timeRange,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: projection.coordinateSpace,
                beatsPerMinute: 95
            ), file: file, line: line
        )
        let bounded = ScratchStrokeGeometry.canonicalGeometry(
            records: projection.records, layer: .performance, frame: frame, wrapPeriod: period
        )

        XCTAssertEqual(bounded, unwrapped,
                       "the whole geometry must fall back, including earlier records and evidence gaps",
                       file: file, line: line)
        XCTAssertTrue(bounded.motion.segments.allSatisfy {
            $0.startTime.isFinite && $0.endTime.isFinite
                && $0.startPosition.isFinite && $0.endPosition.isFinite
        }, "fallback must retain finite geometry", file: file, line: line)
        XCTAssertEqual(projection.records, originalRecords,
                       "presentation arithmetic must not rewrite the canonical records", file: file, line: line)
    }

    func testLoopWrappingFallsBackWhenFiniteLapIndexCannotAdvance() throws {
        let start = 1e16
        // At this magnitude Double cannot represent the next integer lap.
        XCTAssertEqual(start + 1, start)
        let events = [normalizedRun(start: 0, end: 1, direction: "forward", from: start, to: start + 4)]
        try assertUnsafeLoopFallsBackToUnwrappedGeometry(events, period: 1, timeRange: 0...1)
    }

    func testLoopWrappingFallsBackWhenFinitePeriodExceedsPieceBudget() throws {
        let events = [normalizedRun(start: 0, end: 1, direction: "forward", from: 0, to: 1)]
        // Finite, exactly representable input would otherwise make 8192
        // pieces from one observed curve pair, exceeding the 4096-piece cap.
        try assertUnsafeLoopFallsBackToUnwrappedGeometry(events, period: 1.0 / 8_192, timeRange: 0...1)
    }

    func testLoopWrappingPieceBudgetAppliesAcrossTheWholeGeometry() throws {
        let events = [
            normalizedRun(start: 0, end: 1, direction: "forward", from: 0, to: 1),
            normalizedRun(start: 1, end: 2, direction: "backward", from: 1, to: 0),
            normalizedRun(start: 2, end: 3, direction: "forward", from: 0, to: 1)
        ]
        // Each curve needs only 2048 pieces, but the complete geometry needs
        // 6144. A per-curve cap would miss this and retain partial wrapping.
        try assertUnsafeLoopFallsBackToUnwrappedGeometry(events, period: 1.0 / 2_048, timeRange: 0...3)
    }

    func testLoopWrappingFallsBackWhenFinitePositionPeriodQuotientOverflows() throws {
        let period = Double.leastNonzeroMagnitude
        XCTAssertTrue(period.isFinite && period > 0)
        XCTAssertFalse((1.0 / period).isFinite)
        let events = [normalizedRun(start: 0, end: 1, direction: "forward", from: 1, to: 2)]
        try assertUnsafeLoopFallsBackToUnwrappedGeometry(events, period: period, timeRange: 0...1)
    }

    /// Untouched forward playback through three sample loops draws three
    /// rising traces, each bottom to top, with NO connector between them.
    func testThreeForwardSampleLoopsDrawThreeRisingTracesAndNoConnector() throws {
        // One continuous forward run covering exactly three loop periods.
        let events = [normalizedRun(start: 0.0, end: 3.0, direction: "forward", from: 0.0, to: 3.0)]
        let (projection, geometry) = try loopGeometry(events, wrapPeriod: 1.0, timeRange: 0...3.0)

        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertEqual(travel.count, 3, "one rising trace per sample loop, got \(travel.count)")
        XCTAssertTrue(
            travel.allSatisfy { $0.endPosition > $0.startPosition },
            "a loop wrap must never draw a descending trace"
        )
        for (index, segment) in travel.enumerated() {
            XCTAssertEqual(segment.startPosition, 0, accuracy: 1e-9, "loop \(index) starts at the bottom")
            XCTAssertEqual(segment.endPosition, 1, accuracy: 1e-9, "loop \(index) ends at the top")
        }
        // A wrap is a presentation discontinuity, never absent evidence.
        XCTAssertTrue(geometry.missingMotion.isEmpty, "a loop wrap is not MOTION UNKNOWN")
        // And never a reversal: one forward gesture throughout.
        XCTAssertEqual(projection.records.count, 1)
        XCTAssertEqual(projection.records.first?.direction, .forward)
        XCTAssertTrue(
            travel.allSatisfy { $0.kind == .stroke(.forward) },
            "every drawn loop stays a forward stroke"
        )
    }

    /// The same physical evidence without a loop period keeps today's single
    /// unbounded rising trace - the wrap is opt-in presentation only.
    func testWithoutALoopPeriodTheTraceStaysOneUnwrappedRamp() throws {
        let events = [normalizedRun(start: 0.0, end: 3.0, direction: "forward", from: 0.0, to: 3.0)]
        let (_, geometry) = try loopGeometry(events, wrapPeriod: nil, timeRange: 0...3.0)
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertEqual(travel.count, 1, "no wrap period means no split")
        XCTAssertEqual(try XCTUnwrap(travel.first).startPosition, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(travel.first).endPosition, 1, accuracy: 1e-9)
    }

    /// A DJ physically pulling the platter back must still draw a descending
    /// trace. A loop reset and a negative platter delta are not the same thing.
    func testRealBackwardPlatterMotionStillDrawsADescendingTrace() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.40, direction: "forward", from: 0.0, to: 0.4),
            normalizedRun(start: 0.50, end: 0.90, direction: "backward", from: 0.4, to: 0.1)
        ]
        let (projection, geometry) = try loopGeometry(events, wrapPeriod: 1.0, timeRange: 0...0.9)

        XCTAssertEqual(projection.records.map(\.direction), [.forward, .backward])
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertTrue(
            travel.contains { $0.endPosition < $0.startPosition },
            "genuine backward platter movement must draw a descending trace"
        )
        XCTAssertTrue(travel.contains { $0.endPosition > $0.startPosition })
    }

    /// forward -> backward -> forward inside ONE loop stays continuous
    /// bidirectional motion; nothing is split because no lap boundary is
    /// crossed.
    func testForwardBackwardForwardInsideOneLoopStaysContinuous() throws {
        let events = [
            normalizedRun(start: 0.00, end: 0.20, direction: "forward", from: 0.10, to: 0.40),
            normalizedRun(start: 0.20, end: 0.40, direction: "backward", from: 0.40, to: 0.20),
            normalizedRun(start: 0.40, end: 0.60, direction: "forward", from: 0.20, to: 0.50)
        ]
        let (_, geometry) = try loopGeometry(events, wrapPeriod: 1.0, timeRange: 0...0.6)
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertTrue(travel.contains { $0.endPosition > $0.startPosition })
        XCTAssertTrue(travel.contains { $0.endPosition < $0.startPosition })
        // Time-contiguous evidence inside one loop: nothing is uncovered, and
        // no wrap occurs, so the lane has no discontinuity at all.
        XCTAssertTrue(geometry.missingMotion.isEmpty)
        XCTAssertTrue(
            travel.allSatisfy { $0.startPosition >= 0 && $0.endPosition <= 1 },
            "wrapped phase stays inside the lane"
        )
    }

    /// Backward across the loop origin must wrap to the TOP, not fabricate a
    /// huge forward jump. Truth comes from the physical signed motion.
    func testBackwardAcrossTheLoopOriginWrapsToTheTopWithoutAForwardJump() throws {
        // 0.2 down to -0.3: one physical backward run crossing the origin.
        let events = [normalizedRun(start: 0.0, end: 1.0, direction: "backward", from: 0.2, to: -0.3)]
        let (projection, geometry) = try loopGeometry(events, wrapPeriod: 1.0, timeRange: 0...1.0)

        XCTAssertEqual(projection.records.first?.direction, .backward)
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertEqual(travel.count, 2, "one wrap crossing splits the run in two")
        XCTAssertTrue(
            travel.allSatisfy { $0.endPosition < $0.startPosition },
            "a backward run stays descending on both sides of the origin"
        )
        XCTAssertTrue(
            travel.allSatisfy { $0.kind == .stroke(.backward) },
            "the wrap must not relabel backward travel as forward"
        )
        XCTAssertEqual(try XCTUnwrap(travel.first).endPosition, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(travel.last).startPosition, 1, accuracy: 1e-9)
    }
}

/// Companion fixtures are synthetic values/JSON only. The separate connected
/// pipeline suite exercises the actual bridge, worker and archive writer.
final class ReferenceTearEvidenceCodecTests: XCTestCase {
    private typealias Codec = ReferenceTearEvidenceCodec
    private typealias Record = ScratchNotation.GestureRecord
    private typealias Fixture = (binding: ReferenceTearEvidenceSourceBinding,
                                review: ReferenceTearSegmentationReview,
                                projection: ReferenceTearCanonicalProjection)

    private func movement(_ start: Double, _ end: Double, confidence: Double = 1,
                          source: String = "controller", kind: ScratchMovementKind = .normalPush)
        -> CaptureCore.DetectedNotationRecordMovementEvent {
        .init(startTime: start, endTime: end, startPosition: -0.1, endPosition: 0.3,
              direction: "forward", movementKind: kind, speed: 1, confidence: confidence, source: source)
    }

    private func fixture(events supplied: [CaptureCore.DetectedNotationRecordMovementEvent]? = nil) throws -> Fixture {
        let events = supplied ?? [movement(0, 0.2), movement(0.35, 0.65), movement(0.9, 1.4)]
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "controller", notationConfidence: 1, detectedLabel: nil,
            labelSource: "unavailable", labelConfidence: nil, detectionSources: ["controller"],
            recordMovementEvents: events, audioEvents: [], faderEvents: [], mixerMidiEvents: [],
            capturedAt: Date(timeIntervalSinceReferenceDate: 0))
        let sidecar = CaptureCore.LocalRecordingSidecar(
            sessionID: "captured-session", takeID: "captured-take", appLocalTakeNumber: 1,
            recordingRole: "reference", platform: "macOS", appSurface: "reference_authoring",
            sourceDeviceName: "synthetic", startedAt: Date(timeIntervalSinceReferenceDate: 0),
            endedAt: Date(timeIntervalSinceReferenceDate: 2), recordingStatus: "completed",
            mediaFileName: "fixture.mov", sidecarFileName: "fixture.json", detectedNotation: snapshot)
        let binding = try Codec.makeSourceBinding(rawSidecarData: sidecar.encodedData(), fileName: "fixture.json")
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "reference-take", movementEvents: events,
            platterEvidenceIntervals: [
                .init(startTime: 0.2, endTime: 0.35, kind: .observedStillness),
                .init(startTime: 0.65, endTime: 0.9, kind: .observedStillness)
            ], derivation: .init(intervals: [
                .init(state: .open, startTime: 0, endTime: 1.4, startPosition: 1, endPosition: 1)
            ], events: []))
        return (binding, review, ReferenceTearCanonicalProjectionBuilder.project(review))
    }

    private func encoded(_ value: Fixture) throws -> Data {
        try Codec.encode(sourceBinding: value.binding, review: value.review, projection: value.projection,
                         performedLimitations: value.review.requiredIntrinsicComparisonLimitations)
    }

    private func corrected(_ time: Double = 123.1234567890123) -> ReferenceTearCorrection {
        .init(correctedBy: "Synthetic operator", correctedAt: Date(timeIntervalSinceReferenceDate: time),
              notes: "retained notes", reason: "synthetic review correction")
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func changed(_ data: Data, _ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        var json = try object(data)
        try mutation(&json)
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func changedReview(_ data: Data, _ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        try changed(data) { json in
            var review = try XCTUnwrap(json["review"] as? [String: Any])
            try mutation(&review)
            json["review"] = review
        }
    }

    private func changedCandidate(_ data: Data, _ mutation: (inout [String: Any]) throws -> Void) throws -> Data {
        try changedReview(data) { review in
            var candidates = try XCTUnwrap(review["candidates"] as? [[String: Any]])
            XCTAssertFalse(candidates.isEmpty)
            var first = try XCTUnwrap(candidates.first)
            try mutation(&first)
            candidates[0] = first
            review["candidates"] = candidates
        }
    }

    func testGoldenV1DocumentRetainsOriginalSourceBytesAndKnownHash() throws {
        let raw = Data(#"{"schemaVersion":"scratchlab_local_recording_sidecar_v1","sessionID":"captured-session","takeID":"captured-take","appLocalTakeNumber":1,"recordingRole":"reference","platform":"macOS","appSurface":"reference_authoring","sourceDeviceName":"synthetic","startedAt":"2001-01-01T00:00:00Z","recordingStatus":"completed","mediaFileName":"fixture.mov","sidecarFileName":"fixture.json","watchSyncState":"notRequested","auditTrail":[]}"#.utf8)
        let hash = "358f8bc895680db4aec1006dd7ba0218adcb373e46c330f4d0be7c6bc44bf7f3"
        let golden = Data("""
        {"schemaVersion":"scratchlab_reference_tear_evidence_v1","referenceTakeID":"reference-take",
         "sourceBinding":{"capturedSessionID":"captured-session","capturedTakeID":"captured-take","capturedTakeNumber":1,
          "rawSidecarFileName":"fixture.json","rawSidecarData":"\(raw.base64EncodedString())","rawSidecarSHA256":"\(hash)"},
         "review":{"referenceTakeID":"reference-take","rawMovementEvents":[],
          "platterCoordinates":{"basis":"normalizedTakeLocalDisplacement","reference":"golden take-local"},
          "platterEvidenceIntervals":[],"segments":[],"reversals":[],"faderIntervals":[],"faderClicks":[],
          "reasons":[],"candidates":[],"notes":"golden","noteCorrections":[]},
         "projection":{"records":[],"coordinateSpace":"normalizedTakeLocalDisplacement","reasons":[]},
         "performedLimitations":{}}
        """.utf8)
        let document = try Codec.decodeDocument(golden)
        XCTAssertEqual(document.sourceBinding.rawSidecarData, raw)
        XCTAssertEqual(document.sourceBinding.rawSidecarSHA256, hash)
        XCTAssertEqual(document.review.notes, "golden")
        XCTAssertTrue(document.projection.records.isEmpty)
        let stable = try Codec.encode(sourceBinding: document.sourceBinding, review: document.review,
                                      projection: document.projection, performedLimitations: document.performedLimitations)
        XCTAssertEqual(try Codec.decodeDocument(stable), document)
        XCTAssertEqual(stable, try Codec.encode(sourceBinding: document.sourceBinding, review: document.review,
                                               projection: document.projection, performedLimitations: document.performedLimitations))
        XCTAssertEqual(Set(try object(stable).keys),
                       Set(["schemaVersion", "sourceBinding", "referenceTakeID", "review", "projection", "performedLimitations"]))
    }

    func testRoundTripRetainsEveryStoredValueAndIntrinsicLimitation() throws {
        let f = try fixture(), original = f.review
        let id = try XCTUnwrap(f.projection.records.first?.id)
        let limits: [String: [CanonicalTearComparison.UnavailableReason]] = [id: [.interpolatedCurve, .ambiguousEvidence]]
        let data = try Codec.encode(sourceBinding: f.binding, review: f.review, projection: f.projection,
                                    performedLimitations: limits)
        guard case .restored(let restored) = try Codec.decode(data, expectedSource: f.binding,
                                                              expectedReferenceTakeID: "reference-take") else {
            return XCTFail("present valid evidence must restore")
        }
        XCTAssertEqual(restored.review, original)
        XCTAssertEqual(restored.projection, f.projection)
        XCTAssertEqual(restored.performedLimitations, limits)
        XCTAssertEqual(restored.sourceBinding, f.binding)
        XCTAssertEqual(restored.projection.records.first?.internalHolds.map(\.evidence.provenance), [.inferred, .inferred])
        XCTAssertEqual(f.review, original)
    }

    func testCorrectionDatesKeepReferenceDoublePrecisionAndAppendOrder() throws {
        let f = try fixture()
        var review = f.review
        let first = corrected(), earlierWallClock = corrected(122.0000000000001)
        review.setNotes("first", correction: first)
        review.setNotes("second", correction: earlierWallClock)
        let data = try Codec.encode(sourceBinding: f.binding, review: review, projection: f.projection,
                                    performedLimitations: review.requiredIntrinsicComparisonLimitations)
        let restored = try Codec.decodeDocument(data)
        XCTAssertEqual(restored.review.noteCorrections, [first, earlierWallClock])
        XCTAssertEqual(restored.review.noteCorrections[0].correctedAt.timeIntervalSinceReferenceDate,
                       first.correctedAt.timeIntervalSinceReferenceDate)
        XCTAssertEqual(restored.review.notes, "second")
        let reviewJSON = try XCTUnwrap(try object(data)["review"] as? [String: Any])
        let corrections = try XCTUnwrap(reviewJSON["noteCorrections"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(corrections.first?["correctedAt"] as? Double),
                       first.correctedAt.timeIntervalSinceReferenceDate)
    }

    func testTombstonesProposalsCorrectionsAndCounterSurviveContinuedEditing() throws {
        let f = try fixture()
        var review = f.review
        let candidate = try XCTUnwrap(review.candidates.first), boundary = try XCTUnwrap(candidate.boundaries.first)
        XCTAssertTrue(review.moveBoundary(inCandidate: candidate.id, boundaryID: boundary.id,
            to: .init(startTime: 0.21, endTime: 0.34), correction: corrected()))
        let added = try XCTUnwrap(review.addBoundary(toCandidate: candidate.id,
            span: .init(startTime: 1.0, endTime: 1.1), kind: .hold, evidenceQuality: .ambiguous, correction: corrected(124)))
        XCTAssertTrue(review.setBoundaryRemoved(inCandidate: candidate.id, boundaryID: added,
                                                 removed: true, correction: corrected(125)))
        XCTAssertTrue(review.classifyCandidate(id: candidate.id, as: .unknown, correction: corrected(126)))
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        let restored = try Codec.decodeDocument(Codec.encode(sourceBinding: f.binding, review: review, projection: projection,
            performedLimitations: review.requiredIntrinsicComparisonLimitations))
        XCTAssertEqual(restored.review, review)
        XCTAssertEqual(restored.review.candidates[0].boundaries.first { $0.id == boundary.id }?.proposal, boundary.proposal)
        XCTAssertTrue(try XCTUnwrap(restored.review.candidates[0].boundaries.first { $0.id == added }).isRemoved)
        var continued = restored.review
        let next = try XCTUnwrap(continued.addBoundary(toCandidate: candidate.id,
            span: .init(startTime: 1.15, endTime: 1.25), kind: .hold, evidenceQuality: .clear, correction: corrected(127)))
        XCTAssertEqual(next, "\(candidate.id)-added-001")
        XCTAssertNotEqual(next, added)
        XCTAssertEqual(continued.candidates[0].addedBoundaryCount, 2)
        _ = try Codec.encode(sourceBinding: f.binding, review: continued,
                             projection: ReferenceTearCanonicalProjectionBuilder.project(continued),
                             performedLimitations: continued.requiredIntrinsicComparisonLimitations)
    }

    func testCoalescedAddedBoundaryKeepsCounterWithoutLosingCorrection() throws {
        let f = try fixture()
        var review = f.review
        let id = try XCTUnwrap(review.candidates.first?.id)
        let span = ReferenceTearTimeSpan(startTime: 1.0, endTime: 1.1)
        let first = review.addBoundary(toCandidate: id, span: span, kind: .hold, evidenceQuality: .clear, correction: corrected())
        let again = review.addBoundary(toCandidate: id, span: span, kind: .hold, evidenceQuality: .clear, correction: corrected(124))
        XCTAssertEqual(first, again)
        XCTAssertNotNil(first)
        let restored = try Codec.decodeDocument(Codec.encode(sourceBinding: f.binding, review: review,
            projection: ReferenceTearCanonicalProjectionBuilder.project(review),
            performedLimitations: review.requiredIntrinsicComparisonLimitations))
        XCTAssertEqual(restored.review.candidates[0].addedBoundaryCount, 1)
        XCTAssertEqual(restored.review.candidates[0].boundaries.first { $0.id == first }?.corrections.count, 2)
    }

    func testUnsupportedProductionProjectionsRoundTripWithoutMotionValidationGate() throws {
        for event in [movement(0, 0.4, confidence: 0.2), movement(0, 0.4, source: "video"),
                      movement(0, 0.4, kind: .releaseNormalPlayback)] {
            let f = try fixture(events: [event])
            let record = try XCTUnwrap(f.projection.records.first)
            XCTAssertFalse(record.motionValidationIssues().isEmpty)
            XCTAssertEqual(record.evidence.provenance, .unknown)
            let document = try Codec.decodeDocument(encoded(f))
            XCTAssertEqual(document.projection, f.projection)
            XCTAssertEqual(document.review, f.review)
        }
    }

    func testFiniteMalformedRawMovementAndOriginalChronologyAreRetained() throws {
        let events = [movement(0.9, 1.4), movement(0, 0.2), movement(0.35, 0.65), movement(2, 2)]
        let f = try fixture(events: events)
        XCTAssertTrue(f.review.reasons.contains(.malformedMovementEvent))
        let document = try Codec.decodeDocument(encoded(f))
        XCTAssertEqual(document.review.rawMovementEvents, events)
        XCTAssertEqual(document.review.segments, f.review.segments)
        XCTAssertEqual(document.projection, f.projection)
    }

    func testNegativeZeroRawValuesSurviveAlongsideMalformedZeroDuration() throws {
        let event = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: -0.0, endTime: -0.0, startPosition: -0.0, endPosition: -0.0,
            direction: "forward", movementKind: .normalPush, speed: -0.0, confidence: 1, source: "controller")
        let f = try fixture(events: [event])
        XCTAssertTrue(f.review.reasons.contains(.malformedMovementEvent))
        let restored = try Codec.decodeDocument(encoded(f))
        let observed = try XCTUnwrap(restored.review.rawMovementEvents.first)
        XCTAssertEqual(observed.startTime.bitPattern, event.startTime.bitPattern)
        XCTAssertEqual(observed.endTime.bitPattern, event.endTime.bitPattern)
        XCTAssertEqual(observed.startPosition.bitPattern, event.startPosition.bitPattern)
        XCTAssertEqual(observed.endPosition.bitPattern, event.endPosition.bitPattern)
        XCTAssertEqual(observed.speed.bitPattern, event.speed.bitPattern)
        XCTAssertEqual(restored.sourceBinding.rawSidecarData, f.binding.rawSidecarData)
    }

    func testFiniteMalformedStoredCanonicalValuesAreNotReprojectedOrRepaired() throws {
        let f = try fixture()
        let data = try changed(encoded(f)) { json in
            var projection = try XCTUnwrap(json["projection"] as? [String: Any])
            var records = try XCTUnwrap(projection["records"] as? [[String: Any]])
            var subdivisions = try XCTUnwrap(records[0]["subdivisions"] as? [[String: Any]])
            subdivisions[0]["span"] = ["startTime": 0.2, "endTime": -0.1]
            var evidence = try XCTUnwrap(records[0]["evidence"] as? [String: Any])
            var observation = try XCTUnwrap(evidence["observation"] as? [String: Any])
            observation["confidence"] = 1.7
            evidence["observation"] = observation
            records[0]["evidence"] = evidence
            records[0]["subdivisions"] = subdivisions
            projection["records"] = records
            json["projection"] = projection
        }
        let document = try Codec.decodeDocument(data)
        let record = try XCTUnwrap(document.projection.records.first)
        XCTAssertEqual(record.subdivisions.first?.span.endTime, -0.1)
        XCTAssertEqual(record.evidence.observation.confidence, 1.7)
        XCTAssertFalse(record.motionValidationIssues().isEmpty)
        XCTAssertNotEqual(document.projection, ReferenceTearCanonicalProjectionBuilder.project(document.review))
        let again = try Codec.decodeDocument(Codec.encode(sourceBinding: document.sourceBinding,
            review: document.review, projection: document.projection, performedLimitations: document.performedLimitations))
        XCTAssertEqual(again.projection, document.projection)
    }

    func testOnlyAbsentCompanionMeansNotAnalysed() throws {
        let f = try fixture()
        XCTAssertEqual(try Codec.decode(nil, expectedSource: f.binding), .notAnalysed)
        for invalid in [Data(), Data("{".utf8), Data("{}".utf8), Data("null".utf8)] {
            XCTAssertThrowsError(try Codec.decode(invalid, expectedSource: f.binding))
        }
    }

    func testUnknownVersionAndTruncatedRequiredFieldsFailExplicitly() throws {
        let f = try fixture(), data = try encoded(f)
        let future = try changed(data) { $0["schemaVersion"] = "scratchlab_reference_tear_evidence_v2" }
        XCTAssertThrowsError(try Codec.decodeDocument(future)) {
            XCTAssertEqual($0 as? Codec.Error, .unsupportedSchema("scratchlab_reference_tear_evidence_v2"))
        }
        for key in ["review", "projection", "sourceBinding", "performedLimitations"] {
            let truncated = try changed(data) { $0.removeValue(forKey: key) }
            XCTAssertThrowsError(try Codec.decodeDocument(truncated))
        }
    }

    func testCapturedAndReferenceIdentityMismatchesFail() throws {
        let f = try fixture(), data = try encoded(f)
        XCTAssertThrowsError(try Codec.decode(data, expectedSource: f.binding, expectedReferenceTakeID: "other-reference"))
        for key in ["capturedSessionID", "capturedTakeID", "rawSidecarSHA256", "rawSidecarFileName"] {
            let invalid = try changed(data) { json in
                var source = try XCTUnwrap(json["sourceBinding"] as? [String: Any])
                source[key] = "mismatched"
                json["sourceBinding"] = source
            }
            XCTAssertThrowsError(try Codec.decodeDocument(invalid))
        }
        let wrongNumber = try changed(data) { json in
            var source = try XCTUnwrap(json["sourceBinding"] as? [String: Any])
            source["capturedTakeNumber"] = 2
            json["sourceBinding"] = source
        }
        XCTAssertThrowsError(try Codec.decodeDocument(wrongNumber))
    }

    func testLaterSidecarRewriteFailsEvenWhenDecodedValuesAreEqual() throws {
        let f = try fixture(), data = try encoded(f)
        var rewritten = f.binding.rawSidecarData
        rewritten.append(Data("\n ".utf8))
        let later = try Codec.makeSourceBinding(rawSidecarData: rewritten, fileName: f.binding.rawSidecarFileName)
        XCTAssertEqual(later.capturedTakeID, f.binding.capturedTakeID)
        XCTAssertNotEqual(later.rawSidecarSHA256, f.binding.rawSidecarSHA256)
        XCTAssertThrowsError(try Codec.decode(data, expectedSource: later))
        XCTAssertEqual(try Codec.decodeDocument(data).sourceBinding.rawSidecarData, f.binding.rawSidecarData)
    }

    func testSourceFilenameMustBeItsDeclaredPlainLeafName() throws {
        let f = try fixture()
        for name in ["", ".", "..", "../fixture.json", "/fixture.json", "folder\\fixture.json", "different.json"] {
            XCTAssertThrowsError(try Codec.makeSourceBinding(rawSidecarData: f.binding.rawSidecarData, fileName: name))
        }
    }

    func testRawReviewObservationsCannotBeReboundOrDropped() throws {
        let data = try encoded(fixture())
        let dropped = try changedReview(data) { $0["rawMovementEvents"] = [] }
        XCTAssertThrowsError(try Codec.decodeDocument(dropped))
        let other = try changedReview(data) { $0["referenceTakeID"] = "other-reference" }
        XCTAssertThrowsError(try Codec.decodeDocument(other))
    }

    func testBrokenOrdinalAndEvidenceReferencesFail() throws {
        let data = try encoded(fixture())
        for indices in [[999], [-1], [0, 0], [2, 0]] {
            let invalid = try changedCandidate(data) { $0["motionSegmentIndices"] = indices }
            XCTAssertThrowsError(try Codec.decodeDocument(invalid))
        }
        let wrongOrdinal = try changedCandidate(data) { $0["gestureIndex"] = 1 }
        XCTAssertThrowsError(try Codec.decodeDocument(wrongOrdinal))
        let missingEvent = try changedReview(data) { review in
            var segments = try XCTUnwrap(review["segments"] as? [[String: Any]])
            segments[0]["movementEventIndex"] = 999
            review["segments"] = segments
        }
        XCTAssertThrowsError(try Codec.decodeDocument(missingEvent))
    }

    func testProjectionIdentityOrderAndCoordinateMismatchFail() throws {
        let data = try encoded(fixture())
        for key in ["id", "direction", "timingDomain", "coordinateSpace"] {
            let invalid = try changed(data) { json in
                var projection = try XCTUnwrap(json["projection"] as? [String: Any])
                var records = try XCTUnwrap(projection["records"] as? [[String: Any]])
                records[0][key] = key == "id" ? "other" : key == "direction" ? "backward"
                    : key == "timingDomain" ? "beats" : "platterRevolutions"
                projection["records"] = records
                json["projection"] = projection
            }
            XCTAssertThrowsError(try Codec.decodeDocument(invalid))
        }
        let repeated = try changedCandidate(data) { candidate in
            var boundaries = try XCTUnwrap(candidate["boundaries"] as? [[String: Any]])
            boundaries[1]["id"] = boundaries[0]["id"]
            candidate["boundaries"] = boundaries
        }
        XCTAssertThrowsError(try Codec.decodeDocument(repeated))
    }

    func testCounterAndMissingProposalCannotCorruptFutureEdits() throws {
        let data = try encoded(fixture())
        for count in [-1, 1, Int.max] {
            let invalid = try changedCandidate(data) { $0["addedBoundaryCount"] = count }
            XCTAssertThrowsError(try Codec.decodeDocument(invalid))
        }
        let lostProposal = try changedCandidate(data) { candidate in
            var boundaries = try XCTUnwrap(candidate["boundaries"] as? [[String: Any]])
            boundaries[0].removeValue(forKey: "proposal")
            candidate["boundaries"] = boundaries
        }
        XCTAssertThrowsError(try Codec.decodeDocument(lostProposal))
    }

    func testAutomaticBoundaryCannotOccupyItsCandidatesAllocationNamespace() throws {
        let f = try fixture(), data = try encoded(f)
        let originalID = try XCTUnwrap(f.review.candidates.first?.id)
        let forged = try changedCandidate(data) { candidate in
            var boundaries = try XCTUnwrap(candidate["boundaries"] as? [[String: Any]])
            boundaries[0]["id"] = "\(originalID)-added-000"
            candidate["boundaries"] = boundaries
        }
        XCTAssertThrowsError(try Codec.decodeDocument(forged))

        // Neither a candidate ID nor an unrelated historical automatic ID
        // containing "-added-" occupies this candidate's allocation prefix.
        let historicalID = "historical-added-gesture"
        let required = try XCTUnwrap(f.review.requiredIntrinsicComparisonLimitations[originalID]).map(\.rawValue)
        let valid = try changed(data) { json in
            var review = try XCTUnwrap(json["review"] as? [String: Any])
            var candidates = try XCTUnwrap(review["candidates"] as? [[String: Any]])
            candidates[0]["id"] = historicalID
            var boundaries = try XCTUnwrap(candidates[0]["boundaries"] as? [[String: Any]])
            boundaries[0]["id"] = "legacy-added-000"
            candidates[0]["boundaries"] = boundaries
            review["candidates"] = candidates
            json["review"] = review
            var projection = try XCTUnwrap(json["projection"] as? [String: Any])
            var records = try XCTUnwrap(projection["records"] as? [[String: Any]])
            records[0]["id"] = historicalID
            projection["records"] = records
            json["projection"] = projection
            json["performedLimitations"] = [historicalID: required]
        }
        let restored = try Codec.decodeDocument(valid)
        XCTAssertEqual(restored.review.candidates[0].boundaries[0].id, "legacy-added-000")
        var continued = restored.review
        let next = try XCTUnwrap(continued.addBoundary(toCandidate: historicalID,
            span: .init(startTime: 1.0, endTime: 1.1), kind: .hold, evidenceQuality: .clear, correction: corrected()))
        XCTAssertEqual(next, "\(historicalID)-added-000")
        let boundaries = continued.candidates[0].boundaries
        XCTAssertEqual(Set(boundaries.map(\.id)).count, boundaries.count)
        let reencoded = try Codec.encode(sourceBinding: f.binding, review: continued,
            projection: ReferenceTearCanonicalProjectionBuilder.project(continued),
            performedLimitations: continued.requiredIntrinsicComparisonLimitations)
        XCTAssertEqual(try Codec.decodeDocument(reencoded).review, continued)
    }

    func testChangedAutomaticBoundaryCannotLoseItsCorrectionHistory() throws {
        let f = try fixture()
        var review = f.review
        let id = try XCTUnwrap(review.candidates.first?.id)
        let boundaryID = try XCTUnwrap(review.candidates.first?.boundaries.first?.id)
        XCTAssertTrue(review.moveBoundary(inCandidate: id, boundaryID: boundaryID,
            to: .init(startTime: 0.21, endTime: 0.34), correction: corrected()))
        let valid = try Codec.encode(sourceBinding: f.binding, review: review,
            projection: ReferenceTearCanonicalProjectionBuilder.project(review),
            performedLimitations: review.requiredIntrinsicComparisonLimitations)
        XCTAssertEqual(try Codec.decodeDocument(valid).review.candidates[0].boundaries[0].corrections.count, 1)
        let stripped = try changedCandidate(valid) { candidate in
            var boundaries = try XCTUnwrap(candidate["boundaries"] as? [[String: Any]])
            boundaries[0]["corrections"] = []
            candidate["boundaries"] = boundaries
        }
        XCTAssertThrowsError(try Codec.decodeDocument(stripped))
    }

    func testInvalidProjectionBoundsThrowWithoutConstructingAnInvalidRange() throws {
        let data = try encoded(fixture())
        let invalid = try changed(data) { json in
            var projection = try XCTUnwrap(json["projection"] as? [String: Any])
            projection["timeRange"] = ["lowerBound": 2, "upperBound": 1]
            json["projection"] = projection
        }
        XCTAssertThrowsError(try Codec.decodeDocument(invalid))
    }

    func testForeignOrSelectionDependentLimitationsAreRejected() throws {
        let f = try fixture(), id = try XCTUnwrap(f.projection.records.first?.id)
        XCTAssertThrowsError(try Codec.encode(sourceBinding: f.binding, review: f.review, projection: f.projection,
                                              performedLimitations: ["other": [.interpolatedCurve]]))
        XCTAssertThrowsError(try Codec.encode(sourceBinding: f.binding, review: f.review, projection: f.projection,
                                              performedLimitations: [id: [.unobservedInterGestureInterval]]))
        XCTAssertThrowsError(try Codec.encode(sourceBinding: f.binding, review: f.review, projection: f.projection,
                                              performedLimitations: [id: [.missingTarget]]))
    }

    func testRequiredReviewFlagsCannotBeOmittedFromAStoredCompanion() throws {
        let f = try fixture()
        let id = try XCTUnwrap(f.review.candidates.first?.id)
        let boundaryID = try XCTUnwrap(f.review.candidates.first?.boundaries.first?.id)
        let required: [CanonicalTearComparison.UnavailableReason] = [
            .unknownEvidence, .ambiguousEvidence, .correctedTiming, .interpolatedCurve
        ]
        for reason in required {
            var review = f.review
            switch reason {
            case .unknownEvidence:
                XCTAssertTrue(review.classifyCandidate(id: id, as: .unknown, correction: corrected()))
            case .ambiguousEvidence:
                XCTAssertTrue(review.setBoundaryEvidenceQuality(inCandidate: id, boundaryID: boundaryID,
                    to: .ambiguous, correction: corrected()))
            case .correctedTiming:
                XCTAssertTrue(review.moveBoundary(inCandidate: id, boundaryID: boundaryID,
                    to: .init(startTime: 0.21, endTime: 0.34), correction: corrected()))
            default: break
            }
            let limits = review.requiredIntrinsicComparisonLimitations
            XCTAssertTrue(limits[id]?.contains(reason) == true)
            let valid = try Codec.encode(sourceBinding: f.binding, review: review,
                projection: ReferenceTearCanonicalProjectionBuilder.project(review), performedLimitations: limits)
            XCTAssertEqual(try Codec.decodeDocument(valid).performedLimitations, limits)
            let omitted = try changed(valid) { json in
                var changedLimits = limits
                changedLimits[id] = limits[id]?.filter { $0 != reason }
                json["performedLimitations"] = changedLimits.mapValues { $0.map(\.rawValue) }
            }
            XCTAssertThrowsError(try Codec.decode(omitted, expectedSource: f.binding)) {
                guard let error = $0 as? Codec.Error, case .invalidSnapshot = error else {
                    return XCTFail("expected missing evidence qualification to fail snapshot integrity")
                }
            }
        }
    }

    func testInterruptedReviewRequiresUnknownFlagWithoutChangingStoredProjection() throws {
        let f = try fixture(), data = try encoded(f)
        let interrupted = try changedReview(data) { review in
            var intervals = try XCTUnwrap(review["platterEvidenceIntervals"] as? [[String: Any]])
            intervals.append(["startTime": 0.1, "endTime": 0.15, "kind": "packetGap", "stage": "decoder"])
            review["platterEvidenceIntervals"] = intervals
        }
        XCTAssertThrowsError(try Codec.decodeDocument(interrupted))
        let qualified = try changed(interrupted) { json in
            json["performedLimitations"] = [f.review.candidates[0].id: ["interpolatedCurve", "unknownEvidence"]]
        }
        let restored = try Codec.decodeDocument(qualified)
        XCTAssertEqual(restored.projection, f.projection)
        XCTAssertTrue(restored.review.hasInterruptedEvidence(in: f.review.candidates[0].span))
    }

    func testNonfiniteCompanionValueFailsInsteadOfBeingClampedOrDropped() throws {
        let f = try fixture()
        var review = f.review
        review.setNotes("nonfinite date is not serializable", correction: corrected(.nan))
        XCTAssertThrowsError(try Codec.encode(sourceBinding: f.binding, review: review, projection: f.projection,
                                    performedLimitations: review.requiredIntrinsicComparisonLimitations))
        XCTAssertTrue(review.noteCorrections[0].correctedAt.timeIntervalSinceReferenceDate.isNaN)
        XCTAssertEqual(review.rawMovementEvents, f.review.rawMovementEvents)
    }
}

final class SecondaryCameraTests: XCTestCase {

    func testTimeoutRejectsLateMediaCommitAndDuplicateCompletion() throws {
        var results: [SecondaryCameraEvidence?] = []
        let gate = SecondaryCameraFinishGate { results.append($0) }
        var failed = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .failed)
        failed.detail = "Timed out"
        XCTAssertTrue(gate.complete(failed))
        var replaced = false
        XCTAssertThrowsError(try gate.commitIfPending { replaced = true })
        XCTAssertFalse(replaced)
        XCTAssertFalse(gate.complete(nil))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]?.status, .failed)
    }

    func testConcurrentFinalizationOnlyPublishesOneResult() {
        let lock = NSLock()
        var count = 0
        let gate = SecondaryCameraFinishGate { _ in lock.lock(); count += 1; lock.unlock() }
        DispatchQueue.concurrentPerform(iterations: 100) { _ in gate.complete(nil) }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(gate.isFinished)
    }

    func testLateStartEarlyEndAndFrameGapsArePartialCoverage() {
        var evidence = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .captured)
        evidence.firstFrameSeconds = 0.03; evidence.lastFrameSeconds = 0.97
        XCTAssertFalse(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: 1))
        evidence.firstFrameSeconds = 0.4
        XCTAssertTrue(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: 1))
        evidence.firstFrameSeconds = 0.03; evidence.lastFrameSeconds = 0.6
        XCTAssertTrue(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: 1))
        evidence.lastFrameSeconds = 0.97; evidence.maximumFrameGapSeconds = 0.3
        XCTAssertTrue(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: 1))
    }

    /// F6: readiness is the second camera's own frame freshness. A primary
    /// sample presented well before the second camera's latest frame (a
    /// delayed primary callback) must not reject a live second angle.
    func testReadinessUsesSecondCameraFreshnessNotPrimaryPresentationTime() {
        XCTAssertTrue(SecondaryCameraRecorder.isFreshForTake(sessionRunning: true,
            lastFrameArrivalHostTime: 500, now: 500.05))
        XCTAssertFalse(SecondaryCameraRecorder.isFreshForTake(sessionRunning: false,
            lastFrameArrivalHostTime: 500, now: 500.05), "A stopped session is not recording.")
        XCTAssertFalse(SecondaryCameraRecorder.isFreshForTake(sessionRunning: true,
            lastFrameArrivalHostTime: 498.9, now: 500), "A frozen preview is not fresh.")
        XCTAssertFalse(SecondaryCameraRecorder.isFreshForTake(sessionRunning: true,
            lastFrameArrivalHostTime: 0, now: 500), "No frame has ever arrived.")
        XCTAssertFalse(SecondaryCameraRecorder.isFreshForTake(sessionRunning: true,
            lastFrameArrivalHostTime: 500.2, now: 500))
    }

    /// F6: the take-end admission bound is known when the primary movie
    /// finishes, before its duration loads, and never exceeds the primary.
    func testSecondCameraTakeEndIsEarlierOfPrimaryLimitAndObservedStop() {
        XCTAssertEqual(SecondaryCameraRecorder.takeEndHostTime(mediaStartHostTime: 100,
            maximumDurationSeconds: 40.0 / 3, observedAt: 120), 100 + 40.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(SecondaryCameraRecorder.takeEndHostTime(mediaStartHostTime: 100,
            maximumDurationSeconds: 40.0 / 3, observedAt: 105), 105, "A manual stop ends earlier.")
        for (start, maximum) in [(0.0, 13.0), (.nan, 13.0), (100.0, .nan), (100.0, 0.0)] {
            XCTAssertEqual(SecondaryCameraRecorder.takeEndHostTime(mediaStartHostTime: start,
                maximumDurationSeconds: maximum, observedAt: 105), 105)
        }
    }

    /// F6: an unknown primary interval cannot prove coverage, and frames after
    /// the primary media ended are outside the take.
    func testInvalidOrOverrunPrimaryIntervalIsNeverCompleteCoverage() {
        var evidence = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .captured)
        evidence.firstFrameSeconds = 0.03; evidence.lastFrameSeconds = 0.97; evidence.frameCount = 29
        for invalid in [Double.nan, .infinity, -1, 0] {
            XCTAssertTrue(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: invalid),
                "Duration \(invalid) cannot prove second-camera coverage.")
        }
        evidence.lastFrameSeconds = 1.5
        XCTAssertTrue(SecondaryCameraRecorder.hasIncompleteCoverage(evidence, duration: 1))
    }
    func testOptionalAbsenceAndFailedCameraHaveNoExportArtifact() throws {
        let primary = URL(fileURLWithPath: "/tmp/take.mov")
        var evidence = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .unavailable)
        XCTAssertNil(try evidence.verifiedURL(beside: primary))
        evidence.status = .failed
        XCTAssertNil(try evidence.verifiedURL(beside: primary))
        evidence.fileName = "some-other-take.mov"
        XCTAssertThrowsError(try evidence.verifiedURL(beside: primary))
    }

    func testSecondCameraRejectsWrongTakeChangedBytesAndInvalidTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("take01.mov")
        let url = SecondaryCameraEvidence.url(beside: primary)
        let data = Data("recorded angle".utf8)
        try data.write(to: url)
        var evidence = SecondaryCameraEvidence(deviceID: "phone", deviceName: "Phone", rotationDegrees: 90, status: .captured)
        evidence.fileName = url.lastPathComponent; evidence.sha256 = ReferencePackageIO.sha256Hex(data)
        evidence.frameCount = 30; evidence.firstFrameSeconds = 0.03; evidence.lastFrameSeconds = 1
        XCTAssertEqual(try evidence.verifiedURL(beside: primary), url)
        XCTAssertThrowsError(try evidence.verifiedURL(beside: root.appendingPathComponent("take02.mov")))
        evidence.firstFrameSeconds = -0.1
        XCTAssertThrowsError(try evidence.verifiedURL(beside: primary))
        evidence.firstFrameSeconds = 0.03
        try Data("changed angle".utf8).write(to: url)
        XCTAssertThrowsError(try evidence.verifiedURL(beside: primary))
    }

    @MainActor
    func testPortraitAndRotatedLandscapeFitWithoutCroppingOrMirroring() {
        let cell = CGRect(x: 1280, y: 0, width: 408, height: 720)
        for (size, sourceTransform) in [
            (CGSize(width: 1080, height: 1920), CGAffineTransform.identity),
            (CGSize(width: 1920, height: 1080), CGAffineTransform(rotationAngle: .pi / 2))
        ] {
            let transform = ReferenceFinalizedMediaReviewController.aspectFitTransform(size: size, transform: sourceTransform, in: cell)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            XCTAssertEqual(bounds.height, 720, accuracy: 0.001)
            XCTAssertEqual(bounds.width, 405, accuracy: 0.001)
            XCTAssertEqual(bounds.midX, cell.midX, accuracy: 0.001)
            XCTAssertGreaterThan(transform.a * transform.d - transform.b * transform.c, 0)
        }
    }

    func testPhoneMovieKeepsPortraitTimingAndGetsTheTakeAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("phone.mov"), wav = root.appendingPathComponent("take.wav")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 80, AVVideoHeightKey: 144])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 144])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 3..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 7), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)); audio.frameLength = 48_000
        for ch in 0..<2 { for i in 0..<48_000 { audio.floatChannelData![ch][i] = Float(sin(Double(i) * 0.1)) * 0.25 } }
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: audio) }
        let before = AVURLAsset(url: movie)
        let beforeTracks = try await before.loadTracks(withMediaType: .video)
        let beforeTrack = try XCTUnwrap(beforeTracks.first)
        let beforeRange = try await beforeTrack.load(.timeRange)
        try await SecondaryCameraRecorder.attachAudio(videoURL: movie, audioURL: wav)
        let asset = AVURLAsset(url: movie)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let audioTrack = try XCTUnwrap(audios.first)
        let size = try await video.load(.naturalSize), range = try await video.load(.timeRange)
        XCTAssertEqual(size, CGSize(width: 80, height: 144))
        XCTAssertEqual(range.start.seconds, beforeRange.start.seconds, accuracy: 0.001)
        let audioRange = try await audioTrack.load(.timeRange)
        XCTAssertEqual(audioRange.start.seconds, 0, accuracy: 0.001)
        XCTAssertGreaterThan(audioRange.duration.seconds, 0.8)
    }
}
