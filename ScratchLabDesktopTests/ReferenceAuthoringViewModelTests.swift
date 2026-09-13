// ReferenceAuthoringViewModelTests.swift
// ScratchLabDesktopTests

import XCTest
import AVFoundation
@testable import ScratchLab

/// Real-file mux regression coverage; no capture devices or playback are used.
@MainActor
final class RoutineReviewMovieMuxerTests: XCTestCase {
    func testCameraOnlyTailIsTrimmedWithoutMovingStartOrChangingWAV() async throws {
        // The reported take had 181 camera frames and 260190 WAV frames.
        let files = try await fixture(videoFrames: 181, audioFrames: 260_190)
        let originalWAV = try Data(contentsOf: files.audio)
        try await MacCaptureEngine.muxRoutineReviewMovieForTesting(videoURL: files.video, audioURL: files.audio)

        let movie = AVURLAsset(url: files.video)
        let duration = try await movie.load(.duration).seconds
        XCTAssertEqual(duration, 5.9, accuracy: 1.0 / 30)
        XCTAssertLessThanOrEqual(abs(duration - 5.9), ReferenceWitnessedTimingValidator.durationToleranceSeconds)
        XCTAssertEqual(try Data(contentsOf: files.audio), originalWAV)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first)
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertEqual(videoRange.start, .zero)
        XCTAssertEqual(audioRange.start, .zero)
        XCTAssertEqual(audioRange.duration.seconds, 5.9, accuracy: 0.001)
        let first = try firstVideoPixel(in: movie, track: video)
        XCTAssertEqual(first.time, .zero)
        XCTAssertGreaterThan(first.red, 180, "The red opening marker must survive; trimming the beginning is incorrect.")
        XCTAssertLessThan(first.blue, 60)
    }

    func testShortCameraDoesNotPadPictureOrRewriteLongerWAV() async throws {
        let files = try await fixture(videoFrames: 30, audioFrames: 52_920)
        let originalWAV = try Data(contentsOf: files.audio)
        try await MacCaptureEngine.muxRoutineReviewMovieForTesting(videoURL: files.video, audioURL: files.audio)
        let movie = AVURLAsset(url: files.video)
        let duration = try await movie.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 1.0 / 30)
        XCTAssertEqual(try Data(contentsOf: files.audio), originalWAV)
        XCTAssertGreaterThan(abs(1.2 - duration), ReferenceWitnessedTimingValidator.durationToleranceSeconds,
            "A camera that ended too early must still fail duration validation; muxing cannot repair missing picture.")
        let tracks = try await movie.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, 1, accuracy: 0.001)
    }

    func testMissingAudioTrackFailsWithoutReplacingOriginalMovie() async throws {
        let files = try await fixture(videoFrames: 30, audioFrames: 44_100)
        let originalMovie = try Data(contentsOf: files.video)
        do {
            try await MacCaptureEngine.muxRoutineReviewMovieForTesting(videoURL: files.video, audioURL: files.video)
            XCTFail("A video-only file cannot stand in for captured audio.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no audio track"))
        }
        XCTAssertEqual(try Data(contentsOf: files.video), originalMovie)
    }

    func testLateVideoOriginFailsInsteadOfShiftingOrTruncatingStart() async throws {
        let files = try await fixture(videoFrames: 30, audioFrames: 44_100, videoStart: 0.2)
        let asset = AVURLAsset(url: files.video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.start, .zero, "The bounding track range includes its empty leading edit.")
        let segments = try await track.load(.segments)
        let empty = try XCTUnwrap(segments.first(where: \.isEmpty))
        XCTAssertEqual(empty.timeMapping.target.start, .zero)
        XCTAssertEqual(empty.timeMapping.target.duration.seconds, 0.2, accuracy: 0.001)
        let media = try XCTUnwrap(segments.first(where: { !$0.isEmpty }))
        XCTAssertEqual(media.timeMapping.target.start.seconds, 0.2, accuracy: 0.001)
        let originalMovie = try Data(contentsOf: files.video)
        let originalWAV = try Data(contentsOf: files.audio)
        do {
            try await MacCaptureEngine.muxRoutineReviewMovieForTesting(videoURL: files.video, audioURL: files.audio)
            XCTFail("There is no picture at the audio origin; do not silently shift either track.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("coverage from the start"))
        }
        XCTAssertEqual(try Data(contentsOf: files.video), originalMovie)
        XCTAssertEqual(try Data(contentsOf: files.audio), originalWAV)
    }

    func testFailedExportPreservesOriginalMovieAndWAV() async throws {
        let files = try await fixture(videoFrames: 30, audioFrames: 44_100)
        let originalMovie = try Data(contentsOf: files.video)
        let originalWAV = try Data(contentsOf: files.audio)
        let directory = files.video.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        do {
            try await MacCaptureEngine.muxRoutineReviewMovieForTesting(videoURL: files.video, audioURL: files.audio)
            XCTFail("A read-only destination must fail export without deleting the camera original.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not attach onboard AHHH"))
        }
        XCTAssertEqual(try Data(contentsOf: files.video), originalMovie)
        XCTAssertEqual(try Data(contentsOf: files.audio), originalWAV)
    }

    private func fixture(videoFrames: Int, audioFrames: Int, videoStart: Double = 0) async throws
        -> (video: URL, audio: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineMux-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("take.mov")
        let audio = directory.appendingPathComponent("take.wav")
        try await Task.detached {
            try Self.writeAudio(audio, frames: audioFrames)
            try Self.writeVideo(video, frames: videoFrames, start: videoStart)
        }.value
        return (video, audio)
    }

    private nonisolated static func writeAudio(_ url: URL, frames: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<frames {
            let sample = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.25)
            channels[0][index] = sample
            channels[1][index] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private nonisolated static func writeVideo(_ url: URL, frames: Int, start: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        guard writer.canAdd(input) else { throw SessionExportError.unableToPrepareExport }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SessionExportError.unableToPrepareExport }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? SessionExportError.unableToPrepareExport }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                nil, &optionalBuffer) == kCVReturnSuccess else { throw SessionExportError.unableToPrepareExport }
            let pixelBuffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
            for row in 0..<64 {
                for column in 0..<64 {
                    let offset = row * CVPixelBufferGetBytesPerRow(pixelBuffer) + column * 4
                    base[offset] = frame < 3 ? 0 : 255
                    base[offset + 1] = 0
                    base[offset + 2] = frame < 3 ? 255 : 0
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(seconds: start, preferredTimescale: 30) + CMTime(value: Int64(frame), timescale: 30)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? SessionExportError.unableToPrepareExport
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: start, preferredTimescale: 30)
            + CMTime(value: Int64(frames), timescale: 30))
        input.markAsFinished()
        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting { completed.signal() }
        guard completed.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
    }

    private func firstVideoPixel(in asset: AVAsset, track: AVAssetTrack) throws
        -> (time: CMTime, red: UInt8, blue: UInt8) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SessionExportError.unableToPrepareExport }
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        return (CMSampleBufferGetPresentationTimeStamp(sample), base[2], base[0])
    }
}

/// Connected software evidence only: synthetic packets and valid synthetic media,
/// through the actual finalized bridge, serial owner and default archive probes.
@MainActor
final class ReferenceTearEvidencePipelineTests: XCTestCase {

    func testPhysicalRightPlatterForwardPushRisesInLiveAndFinalizedNotation() throws {
        // The fresh take at 22:51 has an increasing counter through its first
        // long stroke, now explicitly confirmed as forward. Test both wraps.
        let values = (0...100).map { (36 + $0) % 128 }
            + (1...100).map { (8 - $0 + 128) % 128 }
        let raw = values.enumerated().map { index, value in
            Raw(timestamp: Double(index) * 0.01, takeRelativeTime: Double(index) * 0.01,
                deviceName: "Rane ONE MKII", channel: 1, controller: 6,
                value: value, normalizedValue: Double(value) / 127, mappedControl: nil)
        }
        let frozen = try JSONEncoder().encode(raw)
        let final = CaptureCore.derivePlatterMotionEvidence(from: raw)
        XCTAssertEqual(final.events.map(\.direction), ["forward", "backward"])
        XCTAssertLessThan(final.events[0].startPosition, final.events[0].endPosition)
        XCTAssertGreaterThan(final.events[1].startPosition, final.events[1].endPosition)
        let live = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: Array(raw.prefix(101)), controller: 6, channel: 1)
        XCTAssertEqual(live.provisionalMovement?.direction, "forward")
        XCTAssertGreaterThan(try XCTUnwrap(live.provisionalMovement?.displacement), 0)
        let projection = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: final.events, platterEvidenceIntervals: final.intervals,
            derivation: nil, coordinates: .normalizedTakeLocal())
        XCTAssertEqual(projection.records.map(\.direction), [.forward, .backward])
        let frame = try XCTUnwrap(ScratchStrokeGeometry.CanonicalFrame(timeRange: 0...2,
            positionRange: try XCTUnwrap(projection.positionRange),
            coordinateSpace: projection.coordinateSpace, beatsPerMinute: 95))
        let geometry = ScratchStrokeGeometry.canonicalGeometry(records: projection.records,
            layer: .performance, frame: frame)
        let pixels = ScratchMotionRenderer.projectedSegments(geometry.motion,
            viewport: LaneViewport(size: CGSize(width: 600, height: 140), now: 0,
                axis: .horizontal, actionLineFraction: 0, secondsAhead: 2))
        let push = try XCTUnwrap(pixels.first)
        XCTAssertLessThan(push.b.y, push.a.y, "Forward must rise on the actual Canvas input.")
        XCTAssertEqual(try JSONEncoder().encode(raw), frozen)
    }

    func testWholeTakePlaybackAdvancesAfterSeek() async throws {
        let files = try await fixture([])
        let take = try await record(worker([files]))
        let controller = ReferenceFinalizedMediaReviewController()
        controller.load(take: take, mediaURL: files.mediaURL, beatRootURL: nil)
        for _ in 0..<100 where controller.state == .loading {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(controller.canPlay)
        let player = try XCTUnwrap(controller.videoPlayer)
        player.isMuted = true
        controller.playWholeTake()
        for _ in 0..<100 where player.currentTime().seconds < 0.2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.15)
        controller.stop()
    }

    func testLateWatchStopTimeoutStillExportsExactRawCaptureAndReview() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let owner = worker([files])
        let take = try await record(owner)
        let binding = try XCTUnwrap(take.tearEvidenceSourceBinding)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: files.sidecarData)
        let changed = try sidecar.withWatchStopDiagnostics(.init(outcome: .timedOut,
            sessionID: sidecar.sessionID, takeID: sidecar.takeID,
            commandID: "late-stop", detail: "Watch motion stop timed out.",
            resolvedAt: Date(timeIntervalSince1970: 1_788_000_005), attemptCount: 1)).encodedData()
        try changed.write(to: files.sidecarURL, options: .atomic)
        let optional = try await owner.rawCaptureExportSnapshot(config: files.config)
        let snapshot = try XCTUnwrap(optional)
        let archived = try await Task.detached { try Self.archive(snapshot.source, in: files.directory) }.value
        let document = try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archived.companions[sidecar.takeID]))
        XCTAssertEqual(document.sourceBinding.rawSidecarData, changed)
        XCTAssertEqual(document.review, take.tearReview)
        XCTAssertEqual(document.projection, take.tearProjection)
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), changed)
        let state = await owner.snapshot()
        XCTAssertEqual(state.session.takeInReview, take, "Export does not alter review or approve new evidence.")
        XCTAssertEqual(binding.rawSidecarData, files.sidecarData)
    }

    func testLateWatchStopRebindsReviewMetadataToRefreshedSidecarAndKeepsPreference() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let owner = worker([files])
        let take = try await record(owner)
        let marked = await owner.markPreferredRepetition(1)
        XCTAssertNil(marked.errorMessage)
        let saved = await owner.saveDraft(reviewNotes: "Second repetition, before the Watch replied")
        XCTAssertNil(saved.errorMessage)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: files.sidecarData)
        let changed = try sidecar.withWatchStopDiagnostics(.init(outcome: .timedOut,
            sessionID: sidecar.sessionID, takeID: sidecar.takeID,
            commandID: "late-stop", detail: "Watch motion stop timed out.",
            resolvedAt: Date(timeIntervalSince1970: 1_788_000_005), attemptCount: 1)).encodedData()
        try changed.write(to: files.sidecarURL, options: .atomic)
        let optional = try await owner.rawCaptureExportSnapshot(config: files.config)
        let snapshot = try XCTUnwrap(optional)
        let archived = try await Task.detached { try Self.archive(snapshot.source, in: files.directory) }.value
        let review = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archived.reviews[sidecar.takeID]))
        let tear = try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archived.companions[sidecar.takeID]))
        XCTAssertEqual(review.sourceBinding.rawSidecarData, changed, "Late Watch additions rebind, never strand, the review.")
        XCTAssertEqual(review.sourceBinding, tear.sourceBinding)
        XCTAssertEqual(review.preferredRepetition?.repetitionNumber, 2)
        XCTAssertEqual(review.reviewNotes, "Second repetition, before the Watch replied")
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), changed)
        XCTAssertEqual(take.tearEvidenceSourceBinding?.rawSidecarData, files.sidecarData)
    }

    func testWatchStopExportRefreshRejectsOtherIdentityAndUnknownFieldChanges() async throws {
        let files = try await fixture([])
        let binding = try ReferenceTearEvidenceCodec.makeSourceBinding(
            rawSidecarData: files.sidecarData, fileName: files.sidecarURL.lastPathComponent)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: files.sidecarData)
        let changed = try sidecar.withWatchStopDiagnostics(.init(outcome: .timedOut,
            sessionID: sidecar.sessionID, takeID: sidecar.takeID, commandID: "late-stop")).encodedData()
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual(try ReferenceTearEvidenceCodec.exportBinding(from: binding,
            currentSidecarData: changed).rawSidecarData, changed)
        for field in ["sessionID", "unknownFutureEvidenceField", "auditTrail", "existingAuditField", "watchStopDiagnostics"] {
            var invalid = valid
            switch field {
            case "auditTrail": invalid[field] = []
            case "existingAuditField":
                var audit = try XCTUnwrap(invalid["auditTrail"] as? [[String: Any]])
                XCTAssertFalse(sidecar.auditTrail.isEmpty)
                audit[0]["unknownFutureEvidenceField"] = "changed"
                invalid["auditTrail"] = audit
            case "watchStopDiagnostics":
                var stop = try XCTUnwrap(invalid[field] as? [String: Any])
                stop["takeID"] = "another-take"
                invalid[field] = stop
            default: invalid[field] = "changed"
            }
            let data = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
            XCTAssertThrowsError(try ReferenceTearEvidenceCodec.exportBinding(from: binding,
                currentSidecarData: data), field)
        }
    }

    func testLateWatchLinkExportsExactCaptureAndImmutableReview() async throws {
        let initial = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var previous = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: initial.sidecarData)
        previous.watchCommandID = "start-this-take"
        let original = try previous.encodedData()
        try original.write(to: initial.sidecarURL, options: .atomic)
        let files = Fixture(directory: initial.directory, mediaURL: initial.mediaURL,
            sidecarURL: initial.sidecarURL, sidecarData: original, config: initial.config, raw: initial.raw)
        let owner = worker([files])
        let take = try await record(owner)
        let binding = try XCTUnwrap(take.tearEvidenceSourceBinding)
        let sample = WatchMotionSample(elapsedTime: 0, attitudeRoll: 0, attitudePitch: 0, attitudeYaw: 0,
            quaternionX: 0, quaternionY: 0, quaternionZ: 0, quaternionW: 1,
            gravityX: 0, gravityY: 0, gravityZ: 1, userAccelerationX: 0, userAccelerationY: 0,
            userAccelerationZ: 0, rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0)
        let capture = WatchMotionCaptureSession(sessionID: previous.sessionID, takeID: previous.takeID,
            commandID: previous.watchCommandID, requestedAt: previous.startedAt, acknowledgedAt: previous.startedAt,
            syncState: .acknowledged, sourceDeviceName: "Synthetic Watch", sampleRateHz: 100,
            startedAt: previous.startedAt, endedAt: previous.startedAt.addingTimeInterval(1),
            deviceRecordedAtStart: previous.startedAt, deviceRecordedAtEnd: previous.startedAt.addingTimeInterval(1),
            appVersion: "test", timingMetadata: nil, samples: Array(repeating: sample, count: 10))
        let motionData = try WatchMotionCaptureCodec.encoder.encode(capture)
        let name = "late-watch-\(UUID()).json"
        let relayDirectory = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first).appendingPathComponent("ScratchLab/RelayedWatchCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: relayDirectory, withIntermediateDirectories: true)
        let motionURL = relayDirectory.appendingPathComponent(name)
        try motionData.write(to: motionURL)
        defer { try? FileManager.default.removeItem(at: motionURL) }
        let linked = previous.linkingWatchCapture(id: capture.id, fileName: name)
        let current = try linked.encodedData()
        try current.write(to: files.sidecarURL, options: .atomic)
        let optionalSnapshot = try await owner.rawCaptureExportSnapshot(config: files.config)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        let archived = try await Task.detached { try Self.archive(snapshot.source, in: files.directory) }.value
        let document = try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archived.companions[previous.takeID]))
        XCTAssertEqual(document.sourceBinding.rawSidecarData, current)
        XCTAssertEqual(document.review, take.tearReview)
        XCTAssertEqual(document.projection, take.tearProjection)
        XCTAssertThrowsError(try ReferenceTearEvidenceCodec.exportBinding(from: binding, currentSidecarData: current))
        var wrong = try XCTUnwrap(JSONSerialization.jsonObject(with: motionData) as? [String: Any])
        for field in ["id", "sessionID", "takeID", "commandID"] {
            var invalid = wrong
            invalid[field] = field == "id" ? UUID().uuidString : "other"
            XCTAssertThrowsError(try ReferenceTearEvidenceCodec.exportBinding(from: binding,
                currentSidecarData: current, linkedWatchData: JSONSerialization.data(withJSONObject: invalid)), field)
        }
        wrong["samples"] = []
        XCTAssertThrowsError(try ReferenceTearEvidenceCodec.exportBinding(from: binding,
            currentSidecarData: current, linkedWatchData: JSONSerialization.data(withJSONObject: wrong)))
        var mutated = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        mutated["unknownFutureEvidenceField"] = "changed"
        XCTAssertThrowsError(try ReferenceTearEvidenceCodec.exportBinding(from: binding,
            currentSidecarData: JSONSerialization.data(withJSONObject: mutated), linkedWatchData: motionData))
        let state = await owner.snapshot()
        XCTAssertEqual(state.session.takeInReview, take)
    }

    func testFinalizedVideoAndWAVPlayTogetherWithoutOptionalBeatAssetsAndStopCancelsSeek() async throws {
        let files = try await fixture([])
        let take = try await record(worker([files]))
        let controller = ReferenceFinalizedMediaReviewController()
        controller.load(take: take, mediaURL: files.mediaURL, beatRootURL: nil)
        for _ in 0..<100 where controller.state == .loading {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(controller.canPlay)
        XCTAssertNotNil(controller.beatBindingIssue)
        let player = try XCTUnwrap(controller.videoPlayer)
        let asset = try XCTUnwrap(player.currentItem?.asset)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1, "Exactly one finalized WAV audio track; no duplicate camera audio.")
        XCTAssertEqual(videoTracks.count, 1)
        player.isMuted = true
        controller.playWholeTake()
        controller.stop() // Cancel before an asynchronous seek can restart playback.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(player.rate, 0)
    }
    private typealias Raw = CaptureCore.RawMixerMIDIEvent
    private struct Fixture: Sendable {
        let directory: URL
        let mediaURL: URL
        let sidecarURL: URL
        let sidecarData: Data
        let config: CaptureSessionConfig
        let raw: [Raw]
    }
    private struct Archived: Sendable {
        let companions: [String: Data]
        let boundSidecarDataByTakeID: [String: Data]
        let metadata: SessionExportMetadataDocument
        let notationByTakeID: [String: SessionExportNotationDocument]
        let replay: SessionExportReplayDocument
        let reviews: [String: Data]
    }
    private nonisolated static var calibration: CrossfaderCalibration {
        CrossfaderCalibration(address: CrossfaderMIDIAddress(deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII", channel: 15, controller: 8),
            fullLeftRawValue: 0, centerRawValue: 52, fullRightRawValue: 104,
            openEnd: .left, activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_000_000))
    }
    // Eighty observed one-step increments clear the existing .75 confidence
    // gate via the real decoder (.7 + 80/1000); no confidence is injected.
    private nonisolated static func packets(_ steps: Int, count: Int = 80, start: Double = 0.1,
        duration: Double = 0.3, phase: Int = 20) -> [Raw] {
        (0...count).map { index in
            let value = ((phase + index * steps) % 128 + 128) % 128
            let time = ((start + Double(index) * duration / Double(count)) * 1_000_000_000).rounded() / 1_000_000_000
            return Raw(timestamp: time, takeRelativeTime: time, deviceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: value,
                normalizedValue: Double(value) / 127, mappedControl: nil)
        }
    }
    private nonisolated static func tear(holds: Int, direction: Int = 1,
        durations: [Double]? = nil, holdDuration: Double = 0.2, runPacketCount: Int = 80) -> [Raw] {
        var result: [Raw] = []
        var start = 0.1
        var phase = 20
        for index in 0...holds {
            let duration = durations?[index] ?? 0.3
            let run = packets(direction, count: runPacketCount, start: start, duration: duration, phase: phase)
            result.append(contentsOf: result.isEmpty ? run : Array(run.dropFirst()))
            start += duration
            phase += runPacketCount * direction
            if index < holds {
                result.append(contentsOf: packets(0, count: max(3, Int(ceil(holdDuration / 0.02))),
                    start: start, duration: holdDuration, phase: phase).dropFirst())
                start += holdDuration
            }
        }
        return result
    }
    private nonisolated static func withFader(_ platter: [Raw], closed: [ClosedRange<Double>] = [],
        alwaysClosed: Bool = false, includeSourceIdentity: Bool = true) throws -> [Raw] {
        let end = (platter.map(\.takeRelativeTime).max() ?? 0) + 0.1
        let fader = try (0...Int(ceil(end * 1_000))).map { index -> Raw in
            let time = Double(index) / 1_000
            let value = alwaysClosed || closed.contains { $0.contains(time) } ? 104 : 0
            let position = try XCTUnwrap(calibration.normalized(rawValue: value))
            return Raw(timestamp: time, takeRelativeTime: time,
                deviceIdentifier: includeSourceIdentity ? calibration.address.deviceIdentifier : nil,
                deviceName: "Rane ONE MKII", channel: 15, controller: 8, value: value, normalizedValue: Double(value) / 127,
                mappedControl: "crossfader", calibratedPosition: position, calibrationID: calibration.id)
        }
        // Only chronological fixtures use this merge. Clock-regression fixtures
        // retain their original receive order and deliberately omit this helper.
        return (platter + fader).enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset
                : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
    }
    private func fixture(_ raw: [Raw], directory: URL? = nil,
        sessionID: String = "pipeline-session", number: Int = 1, notes: String = "synthetic evidence",
        scratchType: CaptureSessionScratchType = .tear) async throws -> Fixture {
        let folder = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceTearPipeline-\(UUID())", isDirectory: true)
        if directory == nil { addTeardownBlock { try? FileManager.default.removeItem(at: folder) } }
        return try await Task.detached {
            try Self.writeFixture(raw, directory: folder, sessionID: sessionID, number: number, notes: notes, scratchType: scratchType)
        }.value
    }
    private nonisolated static func writeFixture(_ raw: [Raw], directory: URL, sessionID: String,
        number: Int, notes: String, scratchType: CaptureSessionScratchType) throws -> Fixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: number)
        let baseName = CaptureCore.LocalRecordingNaming.baseName(sessionID: sessionID, takeNumber: number, roleLabel: "routine")
        let mediaURL = directory.appendingPathComponent(baseName).appendingPathExtension("mov")
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: mediaURL)
        let frameCount = max(30, Int(ceil(((raw.map(\.takeRelativeTime).max() ?? 0) + 0.1) * 30)))
        let duration = Double(frameCount) / 30
        try writeMedia(mediaURL: mediaURL, videoFrames: frameCount)
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let config = CaptureSessionConfig(performerName: "Synthetic Pipeline", bpm: 120, scratchType: scratchType,
            drillMode: .fullCapture, captureMode: .timedClick, takeDurationSeconds: duration,
            takeCount: 1, handedness: .right, notes: notes, sessionID: sessionID, createdAt: date, updatedAt: date)
        let decoded = MacCaptureEngine.resolvedControllerMovementEvents(
            selectedMIDISourceName: "Rane ONE MKII", capturedMidi: raw)
        let snapshot = MacCaptureEngine.RoutineNotationFusionEngine().snapshot(
            audioSnapshot: ScratchAudioNotationSnapshot(audioEvents: [], confidence: nil),
            motionEvents: decoded, detectedLabel: nil, labelSource: "unknown", labelConfidence: nil,
            capturedAt: date).withMixerMidiEvents(raw)
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(sessionID: sessionID,
            sessionConfig: config, takeIdentity: identity,
            files: CaptureCore.LocalRecordingFiles(baseName: baseName, mediaURL: mediaURL, sidecarURL: sidecarURL),
            recordingRole: "routine_capture", platform: "macOS", appSurface: "mac_desktop",
            sourceDeviceName: "Synthetic Pipeline", startedAt: date)
            .finalized(endedAt: date.addingTimeInterval(duration), mediaFileName: mediaURL.lastPathComponent,
                captureErrorDescription: nil)
            .withDetectedNotation(snapshot, recordedAt: date.addingTimeInterval(duration))
        let data = try sidecar.encodedData()
        try data.write(to: sidecarURL, options: .atomic)
        return Fixture(directory: directory, mediaURL: mediaURL, sidecarURL: sidecarURL,
            sidecarData: data, config: config, raw: raw)
    }
    private nonisolated static func writeMedia(mediaURL: URL, videoFrames: Int) throws {
        let sampleRate = 44_100.0
        let frames = AVAudioFrameCount(Double(videoFrames) / 30 * sampleRate)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / sampleRate) * 0.25) }
        let audio = try AVAudioFile(forWriting: mediaURL.deletingPathExtension().appendingPathExtension("wav"),
            settings: format.settings)
        try audio.write(from: buffer)
        let writer = try AVAssetWriter(outputURL: mediaURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        guard writer.canAdd(input) else { throw SessionExportError.unableToPrepareExport }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SessionExportError.unableToPrepareExport }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<videoFrames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? SessionExportError.unableToPrepareExport }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                nil, &optionalBuffer) == kCVReturnSuccess else { throw SessionExportError.unableToPrepareExport }
            let pixelBuffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            memset(base, Int32(40 + frame % 100), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? SessionExportError.unableToPrepareExport
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(videoFrames), timescale: 30))
        input.markAsFinished()
        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting { completed.signal() }
        guard completed.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
    }
    private final class RecordingSequence: @unchecked Sendable {
        let fixtures: [Fixture]
        private let lock = NSLock()
        private var index = 0
        private var finalized: URL?
        let bindIdentity: Bool
        init(_ fixtures: [Fixture], bindIdentity: Bool = false) { self.fixtures = fixtures; self.bindIdentity = bindIdentity }
        var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return finalized }
        func stop() -> Result<ReferenceRecordedTakeArtifacts, ReferenceAuthoringError> {
            lock.lock()
            defer { lock.unlock() }
            guard fixtures.indices.contains(index) else { return .failure(.recordingFailed("No synthetic take remains.")) }
            let fixture = fixtures[index]
            let identity = bindIdentity ? CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: fixture.config.sessionID, takeNumber: 1) : nil
            let result = ReferenceAuthoringCaptureBridge.buildArtifacts(mediaURL: fixture.mediaURL, expectedIdentity: identity)
            if case .success = result { finalized = fixture.mediaURL; index += 1 }
            return result
        }
    }
    func testSecondCameraSurvivesDraftReopenAndRawArchiveAndRejectsChangedMedia() async throws {
        let first = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let secondURL = SecondaryCameraEvidence.url(beside: first.mediaURL)
        try FileManager.default.copyItem(at: first.mediaURL, to: secondURL)
        let original = try Data(contentsOf: secondURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: first.sidecarData)
        var camera = SecondaryCameraEvidence(deviceID: "fixture-phone", deviceName: "Portrait Phone", rotationDegrees: 90, status: .captured)
        camera.fileName = secondURL.lastPathComponent; camera.sha256 = ReferencePackageIO.sha256Hex(original)
        camera.frameCount = 30; camera.firstFrameSeconds = 0.03; camera.lastFrameSeconds = 1
        // Reproduce the hardware ordering: Watch Stop refreshes the active
        // sidecar from disk while the second-camera/movie mux is finishing.
        // That disk copy has no second camera. The finalization-owned result
        // must survive into the draft and the real archive.
        sidecar = sidecar.withWatchStopDiagnostics(.init(outcome: .timedOut,
            sessionID: sidecar.sessionID, takeID: sidecar.takeID,
            detail: "Synthetic late Watch Stop", requestedAt: Date(),
            resolvedAt: Date(), attemptCount: 1, motionTransferState: .notApplicable))
        XCTAssertNil(sidecar.secondaryCamera)
        sidecar = sidecar.finalized(mediaFileName: first.mediaURL.lastPathComponent,
            captureErrorDescription: nil, secondaryCamera: camera)
        XCTAssertEqual(sidecar.watchStopDiagnostics?.outcome, .timedOut)
        let data = try sidecar.encodedData(); try data.write(to: first.sidecarURL)
        let files = Fixture(directory: first.directory, mediaURL: first.mediaURL, sidecarURL: first.sidecarURL,
            sidecarData: data, config: first.config, raw: first.raw)
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let take = try await record(owner)
        let draft = try ReferenceDraftStore(directory: root).load(id: take.id)
        XCTAssertTrue(draft.artifacts.contains { $0.url == secondURL && $0.sha256 == camera.sha256 })
        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let reopened = await fresh.reopenDraft(id: take.id)
        XCTAssertNil(reopened.errorMessage)
        let markPreferredRepetitionUpdate1 = await fresh.markPreferredRepetition(0)
        XCTAssertNil(markPreferredRepetitionUpdate1.errorMessage)
        let optionalSnapshot = try await fresh.rawCaptureExportSnapshot(config: files.config)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        let archive = try await Task.detached { try Self.archive(snapshot.source, in: files.directory) }.value
        let id = try XCTUnwrap(take.tearEvidenceSourceBinding).capturedTakeID
        XCTAssertEqual(archive.boundSidecarDataByTakeID[id], data)
        XCTAssertEqual(try Data(contentsOf: secondURL), original)
        let review = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews[id]))
        XCTAssertEqual(review.preferredRepetition?.repetitionNumber, 1)
        XCTAssertTrue(review.originalMedia.contains(.init(fileName: secondURL.lastPathComponent,
            sha256: ReferencePackageIO.sha256Hex(original))), "The optional second camera is bound by hash.")
        try Data("changed".utf8).write(to: secondURL)
        XCTAssertThrowsError(try ReferenceDraftStore(directory: root).load(id: take.id))
    }

    func testBoundaryPreviewSeeksRecordedVideoWithOneAudioTrackAndRestContext() async throws {
        let strokes = (0..<10).flatMap { index in
            Self.packets(index.isMultiple(of: 2) ? 1 : -1, start: 0.1 + Double(index), duration: 0.8)
        }
        let files = try await fixture(Self.withFader(strokes))
        let owner = worker([files])
        let take = try await record(owner)
        let originalMovie = try Data(contentsOf: files.mediaURL)
        let controller = ReferenceFinalizedMediaReviewController()
        controller.load(take: take, mediaURL: files.mediaURL, beatRootURL: nil)
        let boundary = try XCTUnwrap(take.evidence.boundaries.repetitions.first { $0.index == 1 })
        controller.previewBoundary(boundary, take: take)
        XCTAssertEqual(controller.state, .loading, "An early click must not cancel media loading.")
        let deadline = Date().addingTimeInterval(10)
        while controller.state == .loading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.canPlay)
        let player = try XCTUnwrap(controller.videoPlayer)
        player.isMuted = true
        let asset = try XCTUnwrap(player.currentItem?.asset)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "Whole-take and inline review share the one WAV-backed player.")
        let start = boundary.startSeconds(metadata: take.evidence.metadata)
        let end = boundary.endSeconds(metadata: take.evidence.metadata)
        controller.previewBoundary(boundary, take: take)
        try await waitForPlayer(player, at: start)
        XCTAssertEqual(player.rate, 0)
        controller.previewBoundary(boundary, take: take, atEnd: true)
        try await waitForPlayer(player, at: end - 1 / 30)
        XCTAssertEqual(player.rate, 0)
        controller.play(repetition: boundary, take: take, contextBeats: 4)
        let playingDeadline = Date().addingTimeInterval(5)
        while controller.state != .playing(repetition: boundary.index), Date() < playingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .playing(repetition: boundary.index))
        XCTAssertEqual(player.currentItem?.forwardPlaybackEndTime.seconds ?? -1,
            min(controller.durationSeconds, end + 4 * 60 / Double(take.evidence.metadata.bpm)), accuracy: 0.001)
        controller.stop()
        // A rapid changed edge supersedes the old seek and keeps playback paused.
        controller.previewBoundary(boundary, take: take)
        controller.previewBoundary(boundary, take: take, atEnd: true)
        try await waitForPlayer(player, at: end - 1 / 30)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL), originalMovie)
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), files.sidecarData)
    }

    private func waitForPlayer(_ player: AVPlayer, at seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(5)
        while abs(player.currentTime().seconds - seconds) > 0.01, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(player.currentTime().seconds, seconds, accuracy: 0.01)
    }

    func testPreferredRepetitionAndNotesSurviveRestartAndRealArchiveWithoutApproval() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let wavURL = files.mediaURL.deletingPathExtension().appendingPathExtension("wav")
        let originalMovie = try Data(contentsOf: files.mediaURL)
        let originalWAV = try Data(contentsOf: wavURL)
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let take = try await record(owner)
        let binding = try XCTUnwrap(take.tearEvidenceSourceBinding)
        XCTAssertEqual(take.evidence.boundaries.repetitions.count, 4)

        let plainOptional = try await owner.rawCaptureExportSnapshot(config: files.config)
        let plain = try XCTUnwrap(plainOptional)
        let plainArchive = try await Task.detached { try Self.archive(plain.source, in: files.directory) }.value
        XCTAssertTrue(plainArchive.reviews.isEmpty, "No choice and no notes keeps the existing archive shape.")

        for index in 0..<4 {
            let update = await owner.markPreferredRepetition(index)
            XCTAssertNil(update.errorMessage)
            XCTAssertEqual(update.state.session.takeInReview?.evidence.boundaries.selectedRepetitionIndex, index)
            let saved = try ReferenceDraftStore(directory: root).load(id: take.id)
            XCTAssertEqual(saved.evidence.boundaries.selectedRepetitionIndex, index)
            XCTAssertEqual(saved.preferenceMark?.markedBy, "Synthetic Reviewer")
        }
        let refused = await owner.markPreferredRepetition(4)
        XCTAssertNotNil(refused.errorMessage)
        XCTAssertEqual(refused.state.session.takeInReview?.evidence.boundaries.selectedRepetitionIndex, 3)
        let cleared = await owner.clearPreferredRepetition()
        XCTAssertNil(cleared.state.session.takeInReview?.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertNil(try ReferenceDraftStore(directory: root).load(id: take.id).preferenceMark)
        let markPreferredRepetitionUpdate2 = await owner.markPreferredRepetition(2)
        XCTAssertNil(markPreferredRepetitionUpdate2.errorMessage)
        let saveDraftUpdate3 = await owner.saveDraft(reviewNotes: "Third scratch is CXL's pick")
        XCTAssertNil(saveDraftUpdate3.errorMessage)

        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let reopened = await fresh.reopenDraft(id: take.id)
        XCTAssertNil(reopened.errorMessage)
        let restored = try XCTUnwrap(reopened.state.session.takeInReview)
        XCTAssertEqual(restored.evidence.boundaries.selectedRepetitionIndex, 2)
        let mark = try XCTUnwrap(restored.preferenceMark)
        XCTAssertEqual(mark.markedBy, "Synthetic Reviewer")
        XCTAssertEqual(reopened.state.savedReviewNotes, "Third scratch is CXL's pick")
        XCTAssertEqual(restored.evidence.metadata.lifecycleState, .draft)

        let optional = try await fresh.rawCaptureExportSnapshot(config: files.config)
        let source = try XCTUnwrap(optional)
        let archive = try await Task.detached { try Self.archive(source.source, in: files.directory) }.value
        let document = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews[binding.capturedTakeID]))
        XCTAssertEqual(document.sourceBinding.capturedSessionID, binding.capturedSessionID)
        XCTAssertEqual(document.sourceBinding.capturedTakeID, binding.capturedTakeID)
        XCTAssertEqual(document.sourceBinding.rawSidecarData, files.sidecarData)
        XCTAssertEqual(document.referenceTakeID, take.id)
        XCTAssertEqual(document.recordedRepetitions.map(\.repetitionNumber), [1, 2, 3, 4])
        XCTAssertEqual(document.recordedRepetitions.map(\.repetitionIndex), [0, 1, 2, 3])
        XCTAssertEqual(document.preferredRepetition?.repetitionNumber, 3)
        XCTAssertEqual(document.preferredRepetition?.repetitionIndex, 2)
        XCTAssertEqual(document.preferredRepetition, document.recordedRepetitions[2])
        XCTAssertEqual(document.preferredRepetition?.startBeat, restored.evidence.boundaries.repetitions[2].startBeat)
        XCTAssertEqual(document.preferenceMark, mark)
        XCTAssertEqual(document.reviewNotes, "Third scratch is CXL's pick")
        XCTAssertEqual(document.lifecycleStateAtExport, .draft)
        XCTAssertEqual(Set(document.originalMedia), [
            .init(fileName: files.mediaURL.lastPathComponent, sha256: ReferencePackageIO.sha256Hex(originalMovie)),
            .init(fileName: wavURL.lastPathComponent, sha256: ReferencePackageIO.sha256Hex(originalWAV))
        ])
        XCTAssertEqual(archive.boundSidecarDataByTakeID[binding.capturedTakeID], files.sidecarData)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL), originalMovie)
        XCTAssertEqual(try Data(contentsOf: wavURL), originalWAV)
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), files.sidecarData)
        let after = await fresh.snapshot()
        XCTAssertEqual(after.session.takeInReview?.evidence.metadata.lifecycleState, .draft)
        XCTAssertEqual(after.session.takeInReview?.evidence.boundaries.repetitions.count, 4)
        XCTAssertFalse(after.session.takes.contains {
            $0.evidence.metadata.lifecycleState.isPlayableByLearner || $0.evidence.metadata.reviewDecision != nil
        }, "Exporting a recommendation neither approves nor makes a take servable.")
    }

    func testDraftSavedBeforePreferencesReopensAndExportsOlderShape() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let take = try await record(owner)
        let markPreferredRepetitionUpdate4 = await owner.markPreferredRepetition(1)
        XCTAssertNil(markPreferredRepetitionUpdate4.errorMessage)
        let draftURL = ReferenceDraftStore(directory: root).fileURL(for: take.id)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: draftURL)) as? [String: Any])
        let payloadData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["payload"] as? String)))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertNotNil(payload.removeValue(forKey: "preferenceMark"), "Rewrite exactly as a pre-preference build saved it.")
        let legacyPayload = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        envelope["payload"] = legacyPayload.base64EncodedString()
        envelope["sha256"] = ReferencePackageIO.sha256Hex(legacyPayload)
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: draftURL)

        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let reopened = await fresh.reopenDraft(id: take.id)
        XCTAssertNil(reopened.errorMessage)
        let restored = try XCTUnwrap(reopened.state.session.takeInReview)
        XCTAssertEqual(restored.evidence.boundaries.selectedRepetitionIndex, 1)
        XCTAssertNil(restored.preferenceMark, "An older draft has no reviewer identity or time to invent.")
        let optional = try await fresh.rawCaptureExportSnapshot(config: files.config)
        let source = try XCTUnwrap(optional)
        let archive = try await Task.detached { try Self.archive(source.source, in: files.directory) }.value
        let document = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews.values.first))
        XCTAssertEqual(document.preferredRepetition?.repetitionNumber, 2)
        XCTAssertNil(document.preferenceMark)

        let clearPreferredRepetitionUpdate5 = await fresh.clearPreferredRepetition()

        XCTAssertNil(clearPreferredRepetitionUpdate5.errorMessage)
        let clearedOptional = try await fresh.rawCaptureExportSnapshot(config: files.config)
        let cleared = try XCTUnwrap(clearedOptional)
        let clearedArchive = try await Task.detached { try Self.archive(cleared.source, in: files.directory) }.value
        XCTAssertTrue(clearedArchive.reviews.isEmpty)
        XCTAssertEqual(clearedArchive.companions.count, 1)
    }

    func testMovementCheckRefusesNumberedPreferenceButExportsNotes() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        _ = await owner.configure(technique: .tear,
            pattern: ReferencePatternIdentity(id: "movement", name: "Movement", phraseBars: 1),
            bpm: 120, startingDirection: .forward, faderVariant: .faderOpenThroughout,
            handedness: .right, notes: "Review later", capturePurpose: .movementCheck)
        let recorded = try await record(owner)
        XCTAssertTrue(recorded.evidence.boundaries.repetitions.isEmpty)
        for index in 0..<4 {
            let refused = await owner.markPreferredRepetition(index)
            XCTAssertNotNil(refused.errorMessage)
            XCTAssertNil(refused.state.session.takeInReview?.evidence.boundaries.selectedRepetitionIndex)
            XCTAssertNil(refused.state.session.takeInReview?.preferenceMark)
        }
        let saveDraftUpdate6 = await owner.saveDraft(reviewNotes: "Slow movement looked clean")
        XCTAssertNil(saveDraftUpdate6.errorMessage)
        let optional = try await owner.rawCaptureExportSnapshot(config: files.config)
        let source = try XCTUnwrap(optional)
        let archive = try await Task.detached { try Self.archive(source.source, in: files.directory) }.value
        let document = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews.values.first))
        XCTAssertTrue(document.isMovementCheck)
        XCTAssertTrue(document.recordedRepetitions.isEmpty, "Movement checks never gain numbered slots.")
        XCTAssertNil(document.preferredRepetition)
        XCTAssertNil(document.preferenceMark)
        XCTAssertEqual(document.reviewNotes, "Slow movement looked clean")
    }

    func testReviewMetadataRejectsOutOfRangeWrongTakeUnmatchedInvalidAndChangedMedia() async throws {
        let first = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let second = try await fixture(Self.withFader(Self.tear(holds: 2)), directory: first.directory, number: 2)
        let root = first.directory.appendingPathComponent("drafts")
        let owner = worker([first, second], draftStore: ReferenceDraftStore(directory: root))
        let take = try await record(owner)
        let markPreferredRepetitionUpdate7 = await owner.markPreferredRepetition(3)
        XCTAssertNil(markPreferredRepetitionUpdate7.errorMessage)
        let binding = try XCTUnwrap(take.tearEvidenceSourceBinding)
        let optional = try await owner.rawCaptureExportSnapshot(config: first.config)
        let snapshot = try XCTUnwrap(optional)
        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(from: snapshot.source)
        let data = try XCTUnwrap(package.referenceReviewMetadataByTakeID[binding.capturedTakeID])
        XCTAssertNoThrow(try builder.canonicalPreview(for: package))
        let document = try ReferenceReviewMetadataCodec.decodeDocument(data)
        let last = try XCTUnwrap(document.preferredRepetition)
        XCTAssertEqual(last.repetitionNumber, 4)

        func rebuilt(preferred: ReferenceReviewMetadataDocument.Repetition?,
            source: ReferenceTearEvidenceSourceBinding? = nil) -> ReferenceReviewMetadataDocument {
            ReferenceReviewMetadataDocument(schemaVersion: document.schemaVersion,
                repetitionNumbering: document.repetitionNumbering, sourceBinding: source ?? document.sourceBinding,
                referenceTakeID: document.referenceTakeID, authoringSessionID: document.authoringSessionID,
                isMovementCheck: document.isMovementCheck, lifecycleStateAtExport: document.lifecycleStateAtExport,
                originalMedia: document.originalMedia, recordedRepetitions: document.recordedRepetitions,
                preferredRepetition: preferred, preferenceMark: document.preferenceMark, reviewNotes: document.reviewNotes)
        }
        let fifth = ReferenceReviewMetadataDocument.Repetition(repetitionIndex: 4, repetitionNumber: 5,
            startBeat: last.endBeat, endBeat: last.endBeat + 4, startSeconds: nil, endSeconds: nil)
        let numberMismatch = ReferenceReviewMetadataDocument.Repetition(repetitionIndex: 3, repetitionNumber: 3,
            startBeat: last.startBeat, endBeat: last.endBeat, startSeconds: last.startSeconds, endSeconds: last.endSeconds)
        for invalid in [rebuilt(preferred: fifth), rebuilt(preferred: numberMismatch), rebuilt(preferred: nil)] {
            XCTAssertThrowsError(try ReferenceReviewMetadataCodec.encode(invalid))
        }
        var outOfRange = take.evidence
        outOfRange.boundaries.selectedRepetitionIndex = 4
        XCTAssertThrowsError(try ReferenceReviewMetadataCodec.makeDocument(evidence: outOfRange,
            preferenceMark: nil, reviewNotes: "", sourceBinding: binding, originalMedia: document.originalMedia))

        let secondBinding = try ReferenceTearEvidenceCodec.makeSourceBinding(
            rawSidecarData: second.sidecarData, fileName: second.sidecarURL.lastPathComponent)
        let wrongTake = try ReferenceReviewMetadataCodec.encode(rebuilt(preferred: last, source: secondBinding))
        XCTAssertThrowsError(try ReferenceReviewMetadataCodec.decode(wrongTake, expectedSource: binding))
        var mismatched = package
        mismatched.referenceReviewMetadataByTakeID[binding.capturedTakeID] = wrongTake
        Self.assertExportFailure(.referenceReviewMetadataSourceMismatch) { _ = try builder.canonicalPreview(for: mismatched) }
        var unmatched = package
        unmatched.referenceReviewMetadataByTakeID["not-in-this-archive"] = data
        Self.assertExportFailure(.unmatchedReferenceReviewMetadata) { _ = try builder.canonicalPreview(for: unmatched) }
        var invalid = package
        invalid.referenceReviewMetadataByTakeID[binding.capturedTakeID] = Data("{}".utf8)
        Self.assertExportFailure(.referenceReviewMetadataInvalid) { _ = try builder.canonicalPreview(for: invalid) }

        let wavURL = first.mediaURL.deletingPathExtension().appendingPathExtension("wav")
        let originalWAV = try Data(contentsOf: wavURL)
        try (originalWAV + Data([0])).write(to: wavURL)
        Self.assertExportFailure(.referenceReviewMetadataSourceMismatch) { _ = try builder.canonicalPreview(for: package) }
        try originalWAV.write(to: wavURL)
        XCTAssertNoThrow(try builder.canonicalPreview(for: package))
    }

    private nonisolated static func assertExportFailure(_ reason: SessionExportValidationReason,
        file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? SessionExportValidationFailure)?.reason, reason, "\(error)", file: file, line: line)
        }
    }

    func testEveryCaptureTechniqueSurvivesFinalizationDraftReopenAndRawArchive() async throws {
        // This single integration case writes, reopens and exports all 23 techniques.
        executionTimeAllowance = 600
        for technique in ReferenceTechnique.authorableSet {
            let files = try await fixture(Self.withFader(Self.tear(holds: 1)), scratchType: technique.scratchType)
            let root = files.directory.appendingPathComponent("drafts")
            let owner = worker([files], draftStore: ReferenceDraftStore(directory: root), technique: technique)
            let take = try await record(owner)
            XCTAssertEqual(take.evidence.metadata.technique, technique)
            XCTAssertEqual(take.evidence.metadata.lifecycleState, .draft)
            let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
            let reopened = await fresh.reopenDraft(id: take.id)
            XCTAssertNil(reopened.errorMessage, technique.displayName)
            XCTAssertEqual(reopened.state.session.selectedTechnique, technique)
            XCTAssertEqual(reopened.state.session.takeInReview?.evidence.metadata.technique, technique)
            let optionalSnapshot = try await fresh.rawCaptureExportSnapshot(config: files.config)
            let snapshot = try XCTUnwrap(optionalSnapshot)
            let archived = try await Task.detached { try Self.archive(snapshot.source, in: files.directory) }.value
            XCTAssertEqual(archived.metadata.session.scratchTypeID, technique.id)
            let binding = try XCTUnwrap(take.tearEvidenceSourceBinding)
            XCTAssertEqual(archived.boundSidecarDataByTakeID[binding.capturedTakeID], files.sidecarData)
            XCTAssertEqual(try Data(contentsOf: files.sidecarURL), files.sidecarData)
        }
    }

    func testSavedDraftCanBeApprovedAndExportedAfterRestartWithExactEvidence() async throws {
        // Reversals distinguish performed strokes from steady platter rotation
        // in the real capture fusion path.
        let strokes = (0..<10).flatMap { index in
            Self.packets(index.isMultiple(of: 2) ? 1 : -1, start: 0.1 + Double(index), duration: 0.8)
        }
        let unbound = try Self.withFader(strokes)
        var packets = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unbound)) as? [[String: Any]])
        for index in packets.indices { packets[index]["deviceIdentifier"] = "Rane ONE MKII" }
        let bound = try JSONDecoder().decode([Raw].self, from: JSONSerialization.data(withJSONObject: packets))
        let files = try await fixture(bound)
        let root = files.directory.appendingPathComponent("drafts")
        let beatRoot = files.directory.appendingPathComponent("beat_assets")
        let beat = try ReferenceBeatAssetStore.prepare(mode: .boomBapTrainer, bpm: 120, loopBeats: 4, rootURL: beatRoot)
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root), preparedBeat: beat)
        var configured = await owner.snapshot().session
        configured.bindBeatSpec(beat.binding)
        let intent = try configured.prepareCaptureIntentForRecording()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.sidecarData) as? [String: Any])
        var config = try XCTUnwrap(object["sessionConfig"] as? [String: Any])
        config["referenceCaptureIntent"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent))
        object["sessionConfig"] = config
        object["captureTiming"] = ["clickStartHostTime": UInt64(1_000),
            "recordingStartHostTime": UInt64(1_000) + AVAudioTime.hostTime(forSeconds: 2),
            "recordingStartOffsetSeconds": 2] as [String: Any]
        object["watchCommandID"] = "saved-draft-start"
        object["watchSyncState"] = "acknowledged"
        let unlinked = try decoder.decode(CaptureCore.LocalRecordingSidecar.self,
            from: JSONSerialization.data(withJSONObject: object))
        try unlinked.encodedData().write(to: files.sidecarURL)
        let recorded = try await record(owner)
        XCTAssertEqual(recorded.evidence.metadata.captureIntent, intent)
        XCTAssertFalse(recorded.evidence.watchEvidence.isLinked)
        // The exact acknowledged Watch transfer lands after the draft was
        // saved, while the authoring host is no longer reviewing it.
        let samples = (0..<100).map { index in
            WatchMotionSample(elapsedTime: Double(index) / 10, attitudeRoll: 0, attitudePitch: 0, attitudeYaw: 0,
                quaternionX: 0, quaternionY: 0, quaternionZ: 0, quaternionW: 1,
                gravityX: 0, gravityY: 0, gravityZ: 1, userAccelerationX: 0, userAccelerationY: 0,
                userAccelerationZ: 0, rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0)
        }
        let capture = WatchMotionCaptureSession(sessionID: unlinked.sessionID, takeID: unlinked.takeID,
            commandID: unlinked.watchCommandID, requestedAt: unlinked.startedAt, acknowledgedAt: unlinked.startedAt,
            syncState: .acknowledged, sourceDeviceName: "Synthetic Watch", sampleRateHz: 10,
            startedAt: unlinked.startedAt, endedAt: unlinked.startedAt.addingTimeInterval(10),
            deviceRecordedAtStart: unlinked.startedAt, deviceRecordedAtEnd: unlinked.startedAt.addingTimeInterval(10),
            appVersion: "test", timingMetadata: nil, samples: samples)
        let motionData = try WatchMotionCaptureCodec.encoder.encode(capture)
        let name = "saved-draft-watch-\(UUID()).json"
        let relay = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first).appendingPathComponent("ScratchLab/RelayedWatchCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        let motionURL = relay.appendingPathComponent(name)
        try motionData.write(to: motionURL)
        defer { try? FileManager.default.removeItem(at: motionURL) }
        let raw = try unlinked.linkingWatchCapture(id: capture.id, fileName: name).encodedData()
        try raw.write(to: files.sidecarURL)
        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let reopened = await fresh.reopenDraft(id: recorded.id)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.state.session.takeInReview?.evidence.watchEvidence.isLinked == true)
        XCTAssertEqual(reopened.state.session.takeInReview?.evidence.metadata.lifecycleState, .draft)
        let beforeSelection = await fresh.approveCanonical(notes: "No selection must reject")
        XCTAssertNotNil(beforeSelection.errorMessage)
        _ = await fresh.selectRepetitionForApproval(0)
        let model = ReferenceAuthoringViewModel(worker: fresh, initialState: await fresh.snapshot())
        model.reviewNotes = "Reviewed later; synthetic evidence only"
        model.mediaReview.load(take: try XCTUnwrap(model.reviewedTake), mediaURL: files.mediaURL, beatRootURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while model.mediaReview.state == .loading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.approvalBlockReason)
        let source = await model.rawCaptureExportSource(config: nil, approvingCanonical: true)
        let archiveSource = try XCTUnwrap(source, model.rawCaptureExportError ?? "Approve and save failed")
        let approvedArchive = try await Task.detached { try Self.archive(archiveSource, in: files.directory) }.value
        let take = try XCTUnwrap(model.reviewedTake)
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertEqual(take.evidence.metadata.reviewDecision?.notes, "Reviewed later; synthetic evidence only")
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isPreparingRawCaptureExport)
        let reviewDocument = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(approvedArchive.reviews[unlinked.takeID]))
        XCTAssertEqual(reviewDocument.lifecycleStateAtExport, .approvedCanonical)
        XCTAssertEqual(reviewDocument.preferredRepetition?.repetitionNumber, 1)
        XCTAssertEqual(try ReferenceDraftStore(directory: root).load(id: take.id).evidence.metadata.lifecycleState, .approvedCanonical)
        // Dismissing a save panel cannot undo approval. A normal Save Capture
        // retry uses the same source; another approval request must be refused.
        let duplicate = await model.rawCaptureExportSource(config: nil, approvingCanonical: true)
        XCTAssertNil(duplicate)
        let retry = await model.rawCaptureExportSource(config: nil)
        XCTAssertNotNil(retry)
        XCTAssertEqual(model.reviewedTake?.evidence.metadata.lifecycleState, .approvedCanonical)
        let checked = try await fresh.verifiedTakeForExport()
        let destination = files.directory.appendingPathComponent("approved")
        let package = try await Task.detached {
            try ReferenceApprovedPackageCoordinator.export(take: checked, finalizedMediaURL: files.mediaURL,
                parentDirectory: destination)
        }.value
        XCTAssertEqual(ReferencePackageIO.verify(packageURL: package), [])
        let manifest = try ReferencePackageIO.readManifest(atPackageURL: package)
        XCTAssertEqual(manifest.metadata.captureIntent, intent)
        XCTAssertEqual(manifest.approval.notes, "Reviewed later; synthetic evidence only")
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), raw)
        // Reopening an already approved draft preserves its decision but still checks files.
        let third = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let retained = await third.reopenDraft(id: take.id)
        XCTAssertNil(retained.errorMessage)
        XCTAssertEqual(retained.state.session.takes.last?.evidence.metadata.reviewDecision,
            take.evidence.metadata.reviewDecision)
        try Data("changed Watch recording".utf8).write(to: motionURL)
        let refused = await third.reopenDraft(id: take.id)
        XCTAssertNotNil(refused.errorMessage)
    }

    func testSavedMovementCheckReopensForReviewButCannotBecomeCanonical() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        _ = await owner.configure(technique: .tear,
            pattern: ReferencePatternIdentity(id: "movement", name: "Movement", phraseBars: 1),
            bpm: 120, startingDirection: .forward, faderVariant: .faderOpenThroughout,
            handedness: .right, notes: "Review later", capturePurpose: .movementCheck)
        let recorded = try await record(owner)
        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let reopened = await fresh.reopenDraft(id: recorded.id)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.state.savedDrafts.first?.status, "Movement check")
        XCTAssertTrue(reopened.state.session.takeInReview?.evidence.boundaries.repetitions.isEmpty == true)
        let refused = await fresh.approveCanonical(notes: "Must remain a movement check")
        XCTAssertNotNil(refused.errorMessage)
        XCTAssertEqual(refused.state.session.takeInReview?.evidence.metadata.lifecycleState, .draft)
    }

    func testSessionExportKeepsEarlierDraftNotesAndPreferencesAfterRetake() async throws {
        let first = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let second = try await fixture(Self.withFader(Self.tear(holds: 2)), directory: first.directory, number: 2)
        let store = ReferenceDraftStore(directory: first.directory.appendingPathComponent("drafts"))
        let owner = worker([first, second], draftStore: store)
        let firstTake = try await record(owner)
        let marked = await owner.markPreferredRepetition(2)
        XCTAssertNil(marked.errorMessage)
        let firstSaved = await owner.saveDraft(reviewNotes: "First take: third repetition has the clearest pause")
        XCTAssertNil(firstSaved.errorMessage)
        let continued = await owner.retake()
        XCTAssertNil(continued.errorMessage)
        let secondTake = try await record(owner)
        let secondSaved = await owner.saveDraft(reviewNotes: "Second take: keep all four for comparison")
        XCTAssertNil(secondSaved.errorMessage)

        let pending = try await owner.rawCaptureExportSnapshot(config: second.config)
        let snapshot = try XCTUnwrap(pending)
        let archive = try await Task.detached { try Self.archive(snapshot.source, in: first.directory) }.value
        XCTAssertEqual(Set(archive.reviews.keys), ["take-001", "take-002"])
        let firstReview = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews["take-001"]))
        let secondReview = try ReferenceReviewMetadataCodec.decodeDocument(XCTUnwrap(archive.reviews["take-002"]))
        XCTAssertEqual(firstReview.referenceTakeID, firstTake.id)
        XCTAssertEqual(firstReview.reviewNotes, "First take: third repetition has the clearest pause")
        XCTAssertEqual(firstReview.preferredRepetition?.repetitionNumber, 3)
        XCTAssertEqual(firstReview.preferenceMark, try store.load(id: firstTake.id).preferenceMark)
        XCTAssertEqual(secondReview.referenceTakeID, secondTake.id)
        XCTAssertEqual(secondReview.reviewNotes, "Second take: keep all four for comparison")
        XCTAssertNil(secondReview.preferredRepetition)
        XCTAssertEqual(firstReview.lifecycleStateAtExport, .draft)
        XCTAssertEqual(secondReview.lifecycleStateAtExport, .draft)
        XCTAssertEqual(try Data(contentsOf: first.sidecarURL), first.sidecarData)
        XCTAssertEqual(try Data(contentsOf: second.sidecarURL), second.sidecarData)
    }

    func testSavedDraftSurvivesNewWorkerAndLaterTakesWithExactReview() async throws {
        let first = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let second = try await fixture(Self.withFader(Self.tear(holds: 2)), directory: first.directory, number: 2)
        let root = first.directory.appendingPathComponent("drafts")
        let owner = worker([first, second], draftStore: ReferenceDraftStore(directory: root))
        let original = try await record(owner)
        let candidate = try XCTUnwrap(original.tearReview.candidates.first)
        _ = await owner.classifyTearCandidate(candidate.id, as: .unknown, notes: "Review this with the performer")
        _ = await owner.selectRepetitionForApproval(2)
        _ = await owner.adjustRepetitionBoundary(repetitionIndex: 2, startBeat: 12.1, endBeat: 15.9)
        let saved = await owner.saveDraft(reviewNotes: "Deferred approval notes")
        XCTAssertNil(saved.errorMessage)
        let expected = try XCTUnwrap(saved.state.session.takeInReview)
        XCTAssertEqual(saved.state.savedDrafts.count, 1)
        _ = await owner.retake()
        let staleNotes = await owner.saveDraft(reviewNotes: "Delayed edit for the old take", expectedTakeID: original.id)
        XCTAssertEqual(staleNotes.state.savedReviewNotes, "")
        _ = try await record(owner)
        let fresh = worker([second], draftStore: ReferenceDraftStore(directory: root))
        let listed = await fresh.refreshSavedDrafts()
        XCTAssertEqual(listed.state.savedDrafts.count, 2)
        let reopened = await fresh.reopenDraft(id: original.id)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.state.finalizedMediaURL, first.mediaURL)
        XCTAssertTrue(reopened.state.reviewingSavedDraft)
        let actual = try XCTUnwrap(reopened.state.session.takeInReview)
        XCTAssertEqual(actual.evidence, expected.evidence)
        XCTAssertEqual(actual.tearReview, expected.tearReview)
        XCTAssertEqual(actual.tearProjection, expected.tearProjection)
        XCTAssertEqual(actual.tearPerformedLimitations, expected.tearPerformedLimitations)
        XCTAssertEqual(reopened.state.savedReviewNotes, "Deferred approval notes")
        XCTAssertEqual(actual.evidence.metadata.lifecycleState, .draft)
        let pendingSource = try await fresh.rawCaptureExportSnapshot(config: second.config)
        let source = try XCTUnwrap(pendingSource)
        let archive = try await Task.detached { try Self.archive(source.source, in: first.directory) }.value
        let document = try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archive.companions["take-001"]))
        XCTAssertEqual(document.review, expected.tearReview)
        XCTAssertEqual(try Data(contentsOf: first.sidecarURL), first.sidecarData)
        let rejectedStart = await fresh.startRecording()
        XCTAssertNotNil(rejectedStart.errorMessage)
        let returned = await fresh.prepareNewScratchSetup(afterTakeID: original.id)
        XCTAssertNil(returned.errorMessage)
        XCTAssertFalse(returned.state.reviewingSavedDraft)
        XCTAssertEqual(returned.state.session.phase, .configuring)
        XCTAssertEqual(returned.state.savedDrafts.count, 2)
        XCTAssertNotEqual(returned.state.session.authoringSessionID, expected.evidence.metadata.authoringSessionID)
    }

    func testSavedDraftRejectsChangedMediaAndSidecarWithoutReplacingCurrentReview() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let root = files.directory.appendingPathComponent("drafts")
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let take = try await record(owner)
        let fresh = worker([files], draftStore: ReferenceDraftStore(directory: root))
        let before = await fresh.snapshot()
        let audio = files.mediaURL.deletingPathExtension().appendingPathExtension("wav")
        let bytes = try Data(contentsOf: audio)
        try Data("changed".utf8).write(to: audio)
        let changed = await fresh.reopenDraft(id: take.id)
        XCTAssertTrue(changed.errorMessage?.contains("changed after saving") == true)
        XCTAssertEqual(changed.state.session, before.session)
        try bytes.write(to: audio)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.sidecarData) as? [String: Any])
        object["unexpectedMetadata"] = "Not a Watch update"
        try JSONSerialization.data(withJSONObject: object).write(to: files.sidecarURL)
        let sidecar = await fresh.reopenDraft(id: take.id)
        XCTAssertNotNil(sidecar.errorMessage)
        XCTAssertEqual(sidecar.state.session, before.session)
        try files.sidecarData.write(to: files.sidecarURL)
        let restored = await fresh.reopenDraft(id: take.id)
        XCTAssertNil(restored.errorMessage)
        try FileManager.default.removeItem(at: audio)
        let approval = await fresh.approveCanonical(notes: "Must reject missing audio")
        XCTAssertNotNil(approval.errorMessage)
        XCTAssertEqual(approval.state.session.takeInReview?.evidence.metadata.lifecycleState, .draft)
    }

    func testSavedDraftWriteFailureKeepsFinalizedTakeAndBlocksContinuation() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let occupied = files.directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: occupied)
        let owner = worker([files], draftStore: ReferenceDraftStore(directory: occupied))
        _ = await owner.startRecording()
        let finished = await owner.stopRecording()
        XCTAssertNotNil(finished.state.session.takeInReview)
        XCTAssertNotNil(finished.state.draftSaveError)
        XCTAssertNotNil(finished.errorMessage)
        let continued = await owner.retake()
        XCTAssertNotNil(continued.errorMessage)
        XCTAssertEqual(continued.state.session.phase, finished.state.session.phase)
        let rejected = await owner.rejectTake(notes: "Cannot lose a review on a failed save")
        XCTAssertNotNil(rejected.errorMessage)
        XCTAssertEqual(rejected.state.session.phase, finished.state.session.phase)
        XCTAssertEqual(try Data(contentsOf: files.sidecarURL), files.sidecarData)
        try FileManager.default.removeItem(at: occupied)
        let retry = await owner.saveDraft(reviewNotes: "Retried successfully")
        XCTAssertNil(retry.errorMessage)
        XCTAssertEqual(retry.state.savedDrafts.count, 1)
        let rejectedSaved = await owner.rejectTake(notes: "Rejected after saving was restored")
        XCTAssertNil(rejectedSaved.errorMessage)
        XCTAssertEqual(rejectedSaved.state.savedDrafts.first?.status, "Rejected")
        XCTAssertEqual(rejectedSaved.state.savedReviewNotes, "")
        let stored = try ReferenceDraftStore(directory: occupied).load(id: XCTUnwrap(finished.state.session.takeInReview?.id))
        XCTAssertEqual(stored.evidence.metadata.lifecycleState, .rejected)
        XCTAssertEqual(stored.reviewNotes, "Rejected after saving was restored")
    }

    func testSavedDraftCorruptionIsReportedAndDoesNotOverwriteValidDrafts() async throws {
        let files = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let root = files.directory.appendingPathComponent("drafts")
        let store = ReferenceDraftStore(directory: root)
        let owner = worker([files], draftStore: store)
        let take = try await record(owner)
        let draftURL = store.fileURL(for: take.id)
        let original = try Data(contentsOf: draftURL)
        let corruptURL = root.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: corruptURL)
        let freshStore = ReferenceDraftStore(directory: root)
        XCTAssertThrowsError(try freshStore.refresh())
        XCTAssertEqual(freshStore.summaries.count, 1)
        XCTAssertEqual(try freshStore.load(id: take.id).evidence, take.evidence)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        envelope["sha256"] = "wrong"
        try JSONSerialization.data(withJSONObject: envelope).write(to: draftURL)
        XCTAssertThrowsError(try ReferenceDraftStore(directory: root).load(id: take.id))
        try original.write(to: draftURL)
    }

    private func worker(_ fixtures: [Fixture], draftStore: ReferenceDraftStore? = nil, preparedBeat: ReferencePreparedBeat? = nil, technique: ReferenceTechnique = .tear) -> ReferenceAuthoringWorker {
        let sequence = RecordingSequence(fixtures, bindIdentity: preparedBeat != nil)
        let calibration = Self.calibration
        var session = ReferenceAuthoringSession(authoringSessionID: "pipeline-authoring", operatorName: "Synthetic Reviewer")
        session.selectTechnique(technique)
        session.selectPattern(ReferencePatternIdentity(id: "pipeline", name: "Pipeline", phraseBars: 1), bpm: 120)
        session.declareVariant(startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .right)
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) }, stopRecording: { sequence.stop() },
            currentPreflightSnapshot: {
                ReferencePreflightSnapshot(controllerName: "Rane ONE MKII", controllerIdentifier: "Rane ONE MKII",
                    observedCrossfaderAddress: calibration.address, latestCrossfaderRawValue: 0, calibration: calibration,
                    crossfaderEventCount: 40, platterEventCount: 80, platterIsMoving: true, audioInputPeakLevel: 0.5,
                    audioDeviceName: "Synthetic Audio", watchIsReachable: true, watchMotionIsStreaming: true,
                    cameraDeviceName: "Synthetic Camera", cameraIsActive: true, crossfaderSecondsSinceLastMessage: 0.01)
            }, latestCalibrationObservation: { nil })
        return ReferenceAuthoringWorker(session: session,
            driver: ReferenceAuthoringWorkerDriver(hooks: hooks, lastFinalizedRecordingURLProvider: { sequence.lastURL },
                prepareBeatHandler: { _, _, _ in preparedBeat }),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: fixtures[0].directory.appendingPathComponent("calibration")),
            draftStore: draftStore)
    }
    private func record(_ worker: ReferenceAuthoringWorker) async throws -> ReferenceAuthoringTake {
        let started = await worker.startRecording()
        XCTAssertNil(started.errorMessage)
        let stopped = await worker.stopRecording()
        XCTAssertNil(stopped.errorMessage)
        return try XCTUnwrap(stopped.state.session.takeInReview)
    }
    private nonisolated static func archive(_ source: SessionExportSource, in directory: URL) throws -> Archived {
        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(from: source)
        let output = directory.appendingPathComponent("archive-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try builder.createArchive(from: package, in: output)
        let unpacked = output.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: result.archiveURL, to: unpacked)
        let roots = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        let root = try XCTUnwrap(roots.first)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifests/session_manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let takes = try XCTUnwrap(manifest["takes"] as? [[String: Any]])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(SessionExportMetadataDocument.self,
            from: Data(contentsOf: root.appendingPathComponent("manifests/session_metadata.json")))
        let replay = try decoder.decode(SessionExportReplayDocument.self,
            from: Data(contentsOf: root.appendingPathComponent("manifests/session_replay.json")))
        var companions: [String: Data] = [:]
        var reviews: [String: Data] = [:]
        var boundSidecars: [String: Data] = [:]
        var notation: [String: SessionExportNotationDocument] = [:]
        for take in takes {
            let files = try XCTUnwrap(take["files"] as? [String: String])
            let artifacts = try XCTUnwrap(take["artifacts"] as? [String: [String: Any]])
            if let cameraPath = files["camB"] {
                let camera = try Data(contentsOf: root.appendingPathComponent(cameraPath))
                let record = try XCTUnwrap(artifacts["camB"])
                XCTAssertEqual(record["sha256"] as? String, ReferencePackageIO.sha256Hex(camera))
                XCTAssertNotNil(files["camB_metadata"])
            }
            let notationPath = try XCTUnwrap(files["notation"])
            let notationDocument = try decoder.decode(SessionExportNotationDocument.self,
                from: Data(contentsOf: root.appendingPathComponent(notationPath)))
            notation[notationDocument.takeID] = notationDocument
            if let reviewPath = files["reference_review_metadata"] {
                let record = try XCTUnwrap(artifacts["reference_review_metadata"])
                XCTAssertEqual(record["path"] as? String, reviewPath)
                let data = try Data(contentsOf: root.appendingPathComponent(reviewPath))
                XCTAssertEqual(record["bytes"] as? Int, data.count)
                XCTAssertEqual(record["sha256"] as? String, ReferencePackageIO.sha256Hex(data))
                let review = try ReferenceReviewMetadataCodec.decodeDocument(data)
                XCTAssertNil(reviews.updateValue(data, forKey: review.sourceBinding.capturedTakeID))
            } else {
                XCTAssertNil(artifacts["reference_review_metadata"])
            }
            guard let path = files["reference_tear_evidence"] else {
                XCTAssertNil(artifacts["reference_tear_evidence"])
                continue
            }
            let artifact = try XCTUnwrap(artifacts["reference_tear_evidence"])
            XCTAssertEqual(artifact["path"] as? String, path)
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            XCTAssertEqual(artifact["bytes"] as? Int, data.count)
            XCTAssertEqual(artifact["sha256"] as? String, ReferencePackageIO.sha256Hex(data))
            let document = try ReferenceTearEvidenceCodec.decodeDocument(data)
            XCTAssertNil(companions.updateValue(data, forKey: document.sourceBinding.capturedTakeID))
            // Original sidecar bytes live inside the declared companion. The
            // established archive does not add a second raw-sidecar file.
            boundSidecars[document.sourceBinding.capturedTakeID] = document.sourceBinding.rawSidecarData
        }
        return Archived(companions: companions, boundSidecarDataByTakeID: boundSidecars,
            metadata: metadata, notationByTakeID: notation, replay: replay, reviews: reviews)
    }
    private func geometry(_ take: ReferenceAuthoringTake) throws -> ScratchStrokeGeometry.CanonicalGeometry {
        let projection = take.tearProjection
        let frame = try XCTUnwrap(ReferenceAuthoringViewModel.canonicalFrame(for: projection, bpm: 120))
        return ScratchStrokeGeometry.canonicalGeometry(records: projection.records, layer: .performance, frame: frame)
    }
    @discardableResult
    private func roundTrip(_ fixture: Fixture, worker suppliedWorker: ReferenceAuthoringWorker? = nil,
        targetHolds: Int = 1, direction: String = "forward", rhythm: String = "equal",
        expectUnplacedClockEvidence: Bool = false) async throws -> ReferenceAuthoringTake {
        let owner = suppliedWorker ?? worker([fixture])
        let before: ReferenceAuthoringTake
        if suppliedWorker == nil { before = try await record(owner) }
        else {
            let state = await owner.snapshot()
            before = try XCTUnwrap(state.session.takeInReview)
        }
        let binding = try XCTUnwrap(before.tearEvidenceSourceBinding)
        XCTAssertEqual(binding.rawSidecarData, fixture.sidecarData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: binding.rawSidecarData)
        XCTAssertEqual(sidecar.detectedNotation?.mixerMidiEvents, fixture.raw)
        XCTAssertEqual(before.tearReview.rawMovementEvents, sidecar.detectedNotation?.recordMovementEvents)
        let beforeGeometry: ScratchStrokeGeometry.CanonicalGeometry?
        if expectUnplacedClockEvidence {
            XCTAssertFalse(before.tearReview.rawMovementEvents.isEmpty)
            XCTAssertTrue(before.tearReview.reasons.contains(.clockDiscontinuity))
            XCTAssertTrue(before.tearReview.candidates.isEmpty)
            XCTAssertTrue(before.tearProjection.records.isEmpty)
            XCTAssertNil(before.tearProjection.timeRange)
            XCTAssertNil(ReferenceAuthoringViewModel.canonicalFrame(for: before.tearProjection, bpm: 120))
            beforeGeometry = nil
        } else {
            beforeGeometry = try geometry(before)
        }
        let viewModel = ReferenceAuthoringViewModel(worker: owner, initialState: await owner.snapshot())
        #if DEBUG
        viewModel.selectTearComparisonTarget("scratchlab.tear.\(targetHolds).\(direction).\(rhythm).v1")
        viewModel.selectTearComparisonStart(viewModel.tearComparisonCandidates.first?.id)
        viewModel.compareSelectedTear()
        let comparison: CanonicalTearComparison.Result?
        if expectUnplacedClockEvidence {
            XCTAssertTrue(viewModel.tearComparisonCandidates.isEmpty)
            XCTAssertNil(viewModel.tearComparisonStartID)
            XCTAssertNil(viewModel.tearComparisonOriginSeconds)
            XCTAssertNotNil(viewModel.tearComparisonBlockReason)
            XCTAssertNil(viewModel.tearComparisonResult)
            comparison = nil
        } else {
            let result = try XCTUnwrap(viewModel.tearComparisonResult)
            XCTAssertEqual(result.dimensions.first { $0.axis == .faderTiming }?.assessment, .notRequested)
            comparison = result
        }
        #endif
        // A real serial-owner note correction participates in every connected fixture.
        let noted = await owner.setTearReviewNotes("Synthetic round-trip review")
        XCTAssertNil(noted.errorMessage)
        let exportedTake = try XCTUnwrap(noted.state.session.takeInReview)
        let optionalSnapshot = try await owner.rawCaptureExportSnapshot(config: fixture.config)
        let snapshot = try XCTUnwrap(optionalSnapshot)
        XCTAssertTrue(snapshot.excludedReferenceTakeIDs.isEmpty)
        let archived = try await Task.detached { try Self.archive(snapshot.source, in: fixture.directory) }.value
        let bytes = try XCTUnwrap(archived.companions[binding.capturedTakeID])
        XCTAssertEqual(archived.boundSidecarDataByTakeID[binding.capturedTakeID], fixture.sidecarData)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), fixture.sidecarData)
        let repeated = try ReferenceTearEvidenceCodec.encode(sourceBinding: binding,
            review: exportedTake.tearReview, projection: exportedTake.tearProjection,
            performedLimitations: exportedTake.tearPerformedLimitations)
        XCTAssertEqual(bytes, repeated)
        let restored = await viewModel.restoreTearEvidence(bytes)
        guard case .restored = restored else { XCTFail("The archive's declared companion did not restore."); return before }
        let after = try XCTUnwrap(viewModel.reviewedTake)
        XCTAssertEqual(after.evidence, exportedTake.evidence)
        XCTAssertEqual(after.latestValidation, exportedTake.latestValidation)
        XCTAssertEqual(after.tearReview, exportedTake.tearReview)
        XCTAssertEqual(after.tearProjection, exportedTake.tearProjection)
        XCTAssertNotNil(after.restoredTearProjection)
        if expectUnplacedClockEvidence {
            XCTAssertTrue(after.tearReview.candidates.isEmpty)
            XCTAssertTrue(after.tearProjection.records.isEmpty)
            XCTAssertNil(ReferenceAuthoringViewModel.canonicalFrame(for: after.tearProjection, bpm: 120))
        } else {
            XCTAssertEqual(try geometry(after), beforeGeometry)
        }
        XCTAssertEqual(viewModel.reviewTearProjection, after.restoredTearProjection)
        XCTAssertEqual(after.evidence.metadata.lifecycleState, .draft)
        XCTAssertNil(after.evidence.boundaries.selectedRepetitionIndex)
        #if DEBUG
        XCTAssertNil(viewModel.tearComparisonTargetID)
        viewModel.selectTearComparisonTarget("scratchlab.tear.\(targetHolds).\(direction).\(rhythm).v1")
        viewModel.selectTearComparisonStart(viewModel.tearComparisonCandidates.first?.id)
        viewModel.compareSelectedTear()
        XCTAssertEqual(viewModel.tearComparisonResult, comparison)
        if expectUnplacedClockEvidence {
            XCTAssertNotNil(viewModel.tearComparisonBlockReason)
            XCTAssertNil(viewModel.tearComparisonStartID)
            XCTAssertNil(viewModel.tearComparisonOriginSeconds)
        }
        #endif
        return after
    }

    func testOneTwoThreeHoldsInBothDirectionsSurviveTheRealArchive() async throws {
        for direction in [1, -1] {
            for count in 1...3 {
                let fixture = try await fixture(Self.withFader(Self.tear(holds: count, direction: direction)))
                let take = try await roundTrip(fixture, targetHolds: count, direction: direction == 1 ? "forward" : "backward")
                XCTAssertEqual(take.tearReview.candidates.count, 1)
                XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, count)
                XCTAssertEqual(take.tearReview.rawMovementEvents.count, count + 1)
                for movement in take.tearReview.rawMovementEvents {
                    XCTAssertEqual(movement.confidence, 0.78, accuracy: 1e-9)
                    XCTAssertEqual(movement.source, "controller")
                }
                let record = try XCTUnwrap(take.tearProjection.records.first)
                XCTAssertEqual(record.evidence.provenance, .measured)
                XCTAssertEqual(record.direction.rawValue, direction == 1 ? "forward" : "backward")
                XCTAssertEqual(record.internalHolds.count, count)
                XCTAssertEqual(record.subdivisions.count, count + 1)
                XCTAssertTrue(record.internalHolds.allSatisfy { $0.evidence.provenance == .inferred })
                XCTAssertEqual(take.tearReview.stationaryIntervals.count, count)
                XCTAssertTrue(try geometry(take).missingMotion.isEmpty)
            }
        }
    }
    func testBabyTurnaroundDoesNotBecomeATearHoldAfterArchiveRestore() async throws {
        let raw = Self.packets(1) + Self.packets(-1, start: 0.4, phase: 100).dropFirst()
        let take = try await roundTrip(fixture(Self.withFader(raw)))
        XCTAssertEqual(take.tearReview.candidates.map(\.direction), [.forward, .backward])
        XCTAssertEqual(take.tearReview.reversals.count, 1)
        XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 0)
        XCTAssertTrue(take.tearProjection.records.allSatisfy { $0.internalHolds.isEmpty })
    }
    func testUnequalMovingDurationsAndLongObservedHoldRetainInferredEvidence() async throws {
        let take = try await roundTrip(fixture(Self.withFader(Self.tear(holds: 1,
            durations: [0.2, 0.4], holdDuration: 1))), rhythm: "unequal")
        let record = try XCTUnwrap(take.tearProjection.records.first)
        XCTAssertEqual(record.subdivisions.count, 2)
        let firstSubdivision = try XCTUnwrap(record.subdivisions.first)
        let secondSubdivision = try XCTUnwrap(record.subdivisions.dropFirst().first)
        XCTAssertEqual(firstSubdivision.span.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(secondSubdivision.span.duration, 0.4, accuracy: 1e-9)
        let movingDuration = record.subdivisions.reduce(0) { $0 + $1.span.duration }
        XCTAssertEqual(firstSubdivision.span.duration / movingDuration, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(take.tearReview.stationaryIntervals.first?.span.duration ?? 0, 1, accuracy: 1e-9)
        XCTAssertFalse(take.tearReview.platterEvidenceIntervals.contains { $0.kind == .packetGap })
        XCTAssertEqual(record.internalHolds.first?.evidence.provenance, .inferred)
    }
    func testJitterAndPacketSilenceNeverRoundTripAsHolds() async throws {
        let jitter = Self.packets(1) + Self.packets(-1, count: 2, start: 0.4, duration: 0.02, phase: 100).dropFirst()
            + Self.packets(1, start: 0.42, phase: 98).dropFirst()
        let gap = Self.packets(1) + Self.packets(1, start: 1, phase: 100)
        for (raw, kind) in [(jitter, CaptureCore.PlatterEvidenceInterval.Kind.discardedMotion), (gap, .packetGap)] {
            let take = try await roundTrip(fixture(Self.withFader(raw)))
            XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 0)
            XCTAssertTrue(take.tearReview.platterEvidenceIntervals.contains { $0.kind == kind })
            XCTAssertTrue(take.tearReview.segments.contains { $0.state == .unknown })
        }
    }
    func testReversalBesideObservedStillnessRemainsAReversal() async throws {
        let raw = Self.packets(1) + Self.packets(0, count: 10, start: 0.4, duration: 0.2, phase: 100).dropFirst()
            + Self.packets(-1, start: 0.6, phase: 100).dropFirst()
        let take = try await roundTrip(fixture(Self.withFader(raw)))
        XCTAssertEqual(take.tearReview.candidates.map(\.direction), [.forward, .backward])
        XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 0)
        XCTAssertEqual(take.tearReview.reversals.count, 1)
        XCTAssertTrue(take.tearReview.platterEvidenceIntervals.contains { $0.kind == .observedStillness })
    }
    func testClockRegressionKeepsReceiveOrderAndUnknownTiming() async throws {
        let raw = Self.packets(1, start: 1) + Self.packets(1, start: 0.5, phase: 100)
        let take = try await roundTrip(fixture(raw), expectUnplacedClockEvidence: true)
        XCTAssertTrue(take.tearReview.platterEvidenceIntervals.contains { $0.kind == .clockDiscontinuity })
        XCTAssertTrue(take.tearReview.reasons.contains(.clockDiscontinuity))
        XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 0)
    }

    func testLowConfidenceThirtyStepHoldProposalRemainsUnavailableAfterArchiveRestore() async throws {
        let fixture = try await fixture(Self.withFader(Self.tear(holds: 1, runPacketCount: 30)))
        let owner = worker([fixture])
        _ = try await record(owner)
        let take = try await roundTrip(fixture, worker: owner)
        let candidate = try XCTUnwrap(take.tearReview.candidates.first)
        XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 1)
        XCTAssertEqual(take.tearReview.rawMovementEvents.count, 2)
        for movement in take.tearReview.rawMovementEvents {
            XCTAssertEqual(movement.confidence, 0.73, accuracy: 1e-9)
            XCTAssertEqual(movement.source, "controller")
        }
        XCTAssertEqual(try XCTUnwrap(candidate.proposedConfidence), 0.73, accuracy: 1e-9)
        XCTAssertTrue(take.tearProjection.reasons.contains(.lowMovementConfidence))
        let record = try XCTUnwrap(take.tearProjection.records.first)
        XCTAssertEqual(record.evidence.provenance, .unknown)
        XCTAssertTrue(record.internalHolds.isEmpty)
        let geometry = try geometry(take)
        XCTAssertTrue(geometry.motion.segments.isEmpty)
        XCTAssertFalse(geometry.missingMotion.isEmpty)
        #if DEBUG
        let viewModel = ReferenceAuthoringViewModel(worker: owner, initialState: await owner.snapshot())
        viewModel.selectTearComparisonTarget("scratchlab.tear.1.forward.equal.v1")
        viewModel.selectTearComparisonStart(candidate.id)
        viewModel.compareSelectedTear()
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        for axis in [CanonicalTearComparison.Axis.directionOrder, .holdCount, .holdTiming, .subdivisionRatios, .motionShape] {
            let dimension = try XCTUnwrap(result.dimensions.first { $0.axis == axis })
            XCTAssertEqual(dimension.assessment, .unavailable)
            XCTAssertNil(dimension.scorePercentage)
        }
        #endif
    }
    func testOpenAndClosedFaderKeepMotionIndependentOfAudibility() async throws {
        for closed in [false, true] {
            let take = try await roundTrip(fixture(Self.withFader(Self.tear(holds: 1), alwaysClosed: closed)))
            XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 1)
            let geometry = try geometry(take)
            XCTAssertFalse(geometry.motion.segments.isEmpty)
            XCTAssertTrue(geometry.motion.segments.allSatisfy { $0.evidenceStyle == (closed ? .closed : .open) })
            XCTAssertTrue(geometry.motion.segments.contains { $0.kind == .hold })
            XCTAssertTrue(geometry.faderEdges.isEmpty)
            if closed { XCTAssertTrue(take.tearProjection.reasons.contains(.ghostMovementPresent)) }
        }
    }
    func testClicksAtHoldAndGestureEdgesRetainIndependentTimes() async throws {
        // The production projector places a completed cut at its landing time.
        // Witnessed preroll makes the first landing exactly the gesture start.
        let raw = try Self.withFader(Self.tear(holds: 1), closed: [0.06...0.099, 0.45...0.489, 0.86...0.899])
        let take = try await roundTrip(fixture(raw))
        XCTAssertEqual(take.tearReview.totalCountedTearHoldCount, 1)
        XCTAssertFalse(take.tearReview.faderClicks.isEmpty)
        let geometry = try geometry(take)
        XCTAssertTrue(geometry.faderEdges.contains { abs($0.time - 0.1) < 1e-9 })
        XCTAssertTrue(geometry.faderEdges.contains { abs($0.time - 0.49) < 1e-9 })
        XCTAssertTrue(geometry.faderEdges.contains { abs($0.time - 0.9) < 1e-9 })
        XCTAssertEqual(geometry.faderEdges.map(\.time), geometry.faderEdges.map(\.time).sorted())
    }
    func testFaderWithoutSourceIdentityCannotBorrowSavedCalibration() async throws {
        let raw = try Self.withFader(Self.tear(holds: 1), includeSourceIdentity: false)
        let take = try await roundTrip(fixture(raw))
        XCTAssertTrue(take.tearReview.faderIntervals.isEmpty)
        XCTAssertTrue(take.tearReview.faderClicks.isEmpty)
        XCTAssertTrue(try geometry(take).motion.segments.allSatisfy { $0.evidenceStyle == .unknownFader })
    }

    func testMissingFaderRemainsUnavailableThroughTheWholeRoute() async throws {
        let take = try await roundTrip(fixture(Self.tear(holds: 1)))
        XCTAssertTrue(take.tearReview.faderIntervals.isEmpty)
        XCTAssertTrue(take.tearProjection.records.allSatisfy { $0.faderTransitions.isEmpty && $0.faderIntervals.isEmpty })
        XCTAssertTrue(try geometry(take).motion.segments.allSatisfy { $0.evidenceStyle == .unknownFader })
    }

    func testCorrectionsTombstonesAndFractionalDatesSurviveAndContinueEditing() async throws {
        let fixture = try await fixture(Self.withFader(Self.tear(holds: 2)))
        let owner = worker([fixture])
        let original = try await record(owner)
        let candidate = try XCTUnwrap(original.tearReview.candidates.first)
        let hold = try XCTUnwrap(candidate.boundaries.first { $0.origin == .automatic && $0.countsAsTearHold })
        let originalBoundaryIDs = Set(candidate.boundaries.map(\.id))
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)
        let moved = await owner.moveTearBoundary(candidateID: candidate.id, boundaryID: hold.id,
            startTime: hold.span.startTime + 0.01, endTime: hold.span.endTime - 0.01,
            notes: "Inspect the observed stop", now: date)
        XCTAssertNil(moved.errorMessage)
        let added = await owner.addTearBoundary(candidateID: candidate.id, startTime: 0.15, endTime: 0.18,
            kind: .faderClick, evidenceQuality: .clear, notes: "Operator annotation", now: date.addingTimeInterval(0.125))
        XCTAssertNil(added.errorMessage)
        let addedCandidate = try XCTUnwrap(added.state.session.takeInReview?.tearReview.candidate(id: candidate.id))
        let newBoundaries = addedCandidate.boundaries.filter { $0.origin == .operatorAdded && !originalBoundaryIDs.contains($0.id) }
        XCTAssertEqual(newBoundaries.count, 1)
        let addedBoundary = try XCTUnwrap(newBoundaries.first)
        let removed = await owner.setTearBoundaryRemoved(candidateID: candidate.id, boundaryID: addedBoundary.id,
            removed: true, notes: "Keep the tombstone", now: date.addingTimeInterval(0.25))
        XCTAssertNil(removed.errorMessage)
        let restored = try await roundTrip(fixture, worker: owner, targetHolds: 2)
        let boundaries = try XCTUnwrap(restored.tearReview.candidate(id: candidate.id)).boundaries
        let restoredHold = try XCTUnwrap(boundaries.first { $0.id == hold.id })
        let restoredAnnotation = try XCTUnwrap(boundaries.first { $0.id == addedBoundary.id })
        XCTAssertEqual(restoredHold.proposal, hold.proposal)
        XCTAssertEqual(restoredHold.origin, .automatic)
        XCTAssertEqual(restoredHold.corrections.count, 1)
        XCTAssertEqual(restoredHold.corrections.first?.correctedAt, date)
        XCTAssertEqual(restoredAnnotation.origin, .operatorAdded)
        XCTAssertNil(restoredAnnotation.proposal)
        XCTAssertEqual(restoredAnnotation.corrections.count, 2)
        XCTAssertEqual(restoredAnnotation.corrections.map(\.correctedAt),
            [date.addingTimeInterval(0.125), date.addingTimeInterval(0.25)])
        XCTAssertTrue(restoredAnnotation.isRemoved)
        XCTAssertEqual(restored.tearReview.rawMovementEvents, original.tearReview.rawMovementEvents)
        let noted = await owner.setTearReviewNotes("Notes after restore")
        XCTAssertEqual(noted.state.session.takeInReview?.restoredTearProjection, restored.restoredTearProjection)
        XCTAssertEqual(noted.state.session.takeInReview?.restoredTearPerformedLimitations, restored.restoredTearPerformedLimitations)
        let continued = await owner.addTearBoundary(candidateID: candidate.id, startTime: 0.2, endTime: 0.22,
            kind: .faderClick, evidenceQuality: .clear, notes: "Continue the same review")
        let continuedTake = try XCTUnwrap(continued.state.session.takeInReview)
        XCTAssertNil(continued.errorMessage)
        XCTAssertNil(continuedTake.restoredTearProjection)
        XCTAssertNil(continuedTake.restoredTearPerformedLimitations)
        XCTAssertEqual(continuedTake.tearProjection,
            ReferenceTearCanonicalProjectionBuilder.project(continuedTake.tearReview))
        let continuedBoundaries = try XCTUnwrap(continuedTake.tearReview.candidate(id: candidate.id)).boundaries
        let restoredIDs = Set(boundaries.map(\.id))
        let laterAnnotations = continuedBoundaries.filter { $0.origin == .operatorAdded && !restoredIDs.contains($0.id) }
        XCTAssertEqual(laterAnnotations.count, 1)
        let laterAnnotation = try XCTUnwrap(laterAnnotations.first)
        XCTAssertNotEqual(laterAnnotation.id, addedBoundary.id)
        XCTAssertEqual(continuedBoundaries.first { $0.id == addedBoundary.id }, restoredAnnotation)
        XCTAssertEqual(Set(continuedBoundaries.map(\.id)).count, continuedBoundaries.count)
        XCTAssertEqual(continuedTake.evidence, original.evidence)
        XCTAssertEqual(continuedTake.latestValidation, original.latestValidation)
    }

    func testManualUnknownAndAmbiguousReviewCannotLoseRequiredFlagsOnRestore() async throws {
        let fixture = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let owner = worker([fixture])
        let original = try await record(owner)
        let candidate = try XCTUnwrap(original.tearReview.candidates.first)
        let boundary = try XCTUnwrap(candidate.boundaries.first)
        _ = await owner.classifyTearCandidate(candidate.id, as: .unknown, notes: "Unknown reading")
        _ = await owner.setTearBoundaryEvidenceQuality(candidateID: candidate.id, boundaryID: boundary.id,
            quality: .ambiguous, notes: "Uncertain stop")
        let restored = try await roundTrip(fixture, worker: owner)
        XCTAssertEqual(restored.tearReview.candidates.first?.effectiveClassification, .unknown)
        XCTAssertTrue(restored.tearPerformedLimitations[candidate.id]?.contains(.unknownEvidence) == true)
        XCTAssertTrue(restored.tearPerformedLimitations[candidate.id]?.contains(.ambiguousEvidence) == true)
        let binding = try XCTUnwrap(restored.tearEvidenceSourceBinding)
        let valid = try ReferenceTearEvidenceCodec.encode(sourceBinding: binding, review: restored.tearReview,
            projection: restored.tearProjection, performedLimitations: restored.tearPerformedLimitations)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["performedLimitations"] = [:] as [String: Any]
        let omitted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let before = await owner.snapshot()
        let rejected = await owner.restoreTearEvidence(omitted)
        XCTAssertNil(rejected.result)
        XCTAssertNotNil(rejected.update.errorMessage)
        XCTAssertEqual(rejected.update.state, before)
        #if DEBUG
        let viewModel = ReferenceAuthoringViewModel(worker: owner, initialState: before)
        viewModel.selectTearComparisonTarget("scratchlab.tear.1.forward.equal.v1")
        viewModel.selectTearComparisonStart(candidate.id)
        viewModel.compareSelectedTear()
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(result.dimensions.first { $0.axis == .directionOrder }?.assessment, .unavailable)
        #endif
    }

    func testRestoredSingleCandidateDoesNotInheritAnotherSelectedGap() async throws {
        let raw = Self.tear(holds: 1) + Self.packets(1, start: 1.3, phase: 180)
        let fixture = try await fixture(Self.withFader(raw))
        let owner = worker([fixture])
        let before = try await record(owner)
        XCTAssertEqual(before.tearReview.candidates.count, 2)
        let firstID = try XCTUnwrap(before.tearReview.candidates.first).id
        let secondID = try XCTUnwrap(before.tearReview.candidates.dropFirst().first).id
        XCTAssertFalse(before.tearPerformedLimitations[firstID]?.contains(.unknownEvidence) == true)
        let restored = try await roundTrip(fixture, worker: owner)
        XCTAssertEqual(restored.tearPerformedLimitations[firstID], before.tearPerformedLimitations[firstID])
        #if DEBUG
        let viewModel = ReferenceAuthoringViewModel(worker: owner, initialState: await owner.snapshot())
        viewModel.selectTearComparisonTarget("scratchlab.tear.1.forward.equal.v1")
        viewModel.selectTearComparisonStart(firstID)
        viewModel.compareSelectedTear()
        let single = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(single.dimensions.first { $0.axis == .directionOrder }?.assessment, .withinTolerance)
        let restoredSecond = try XCTUnwrap(restored.tearReview.candidate(id: secondID))
        viewModel.selectTearComparisonEnd(restoredSecond.id)
        viewModel.compareSelectedTear()
        let phrase = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertTrue(phrase.dimensions.flatMap(\.unavailableReasons).contains(.unknownEvidence))
        XCTAssertTrue(phrase.dimensions.flatMap(\.unavailableReasons).contains(.unobservedInterGestureInterval))
        viewModel.selectTearComparisonStart(firstID)
        viewModel.compareSelectedTear()
        XCTAssertEqual(viewModel.tearComparisonResult, single)
        #endif
    }

    func testExportSnapshotUsesCapturedFolderSessionAndMetadataGroup() async throws {
        let first = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let otherGroup = try await fixture(Self.withFader(Self.tear(holds: 1)), directory: first.directory,
            number: 2, notes: "another valid group")
        let third = try await fixture(Self.withFader(Self.tear(holds: 1)), directory: first.directory, number: 3)
        let otherFolder = try await fixture(Self.withFader(Self.tear(holds: 1)), sessionID: "another-captured-session")
        let owner = worker([first, otherGroup, third, otherFolder])
        let firstTake = try await record(owner)
        _ = await owner.retake()
        let excludedTake = try await record(owner)
        _ = await owner.retake()
        let thirdTake = try await record(owner)
        let pending = try await owner.rawCaptureExportSnapshot(config: third.config)
        let snapshot = try XCTUnwrap(pending)
        XCTAssertEqual(snapshot.excludedReferenceTakeIDs, [excludedTake.id])
        let archived = try await Task.detached { try Self.archive(snapshot.source, in: first.directory) }.value
        XCTAssertEqual(Set(archived.companions.keys), Set(["take-001", "take-003"]))
        XCTAssertEqual(try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archived.companions["take-001"])).referenceTakeID, firstTake.id)
        XCTAssertEqual(try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(archived.companions["take-003"])).referenceTakeID, thirdTake.id)
        _ = await owner.retake()
        let finalTake = try await record(owner)
        let pendingOther = try await owner.rawCaptureExportSnapshot(config: otherFolder.config)
        let otherSnapshot = try XCTUnwrap(pendingOther)
        XCTAssertEqual(otherSnapshot.excludedReferenceTakeIDs, [firstTake.id, excludedTake.id, thirdTake.id])
        let otherArchive = try await Task.detached { try Self.archive(otherSnapshot.source, in: otherFolder.directory) }.value
        XCTAssertEqual(otherArchive.companions.count, 1)
        let finalDocument = try ReferenceTearEvidenceCodec.decodeDocument(XCTUnwrap(otherArchive.companions["take-001"]))
        XCTAssertEqual(finalDocument.referenceTakeID, finalTake.id)
        let state = await owner.snapshot()
        XCTAssertEqual(state.session.takes.count, 4)
        XCTAssertEqual(try XCTUnwrap(state.session.takes.first).evidence, firstTake.evidence)
    }

    func testLateSourceGroupingRewriteRejectsCompanionWithoutRebinding() async throws {
        let fixture = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let owner = worker([fixture])
        let before = try await record(owner)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixture.sidecarData) as? [String: Any])
        var config = try XCTUnwrap(object["sessionConfig"] as? [String: Any])
        config["notes"] = "Late grouping metadata change"
        object["sessionConfig"] = config
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try changed.write(to: fixture.sidecarURL, options: .atomic)
        do {
            _ = try await owner.rawCaptureExportSnapshot(config: fixture.config)
            XCTFail("A changed seed may not silently exclude its requested companion.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let model = ReferenceAuthoringViewModel(worker: owner, initialState: await owner.snapshot())
        let rejected = await model.rawCaptureExportSource(config: fixture.config)
        XCTAssertNil(rejected)
        XCTAssertNotNil(model.rawCaptureExportError)
        XCTAssertFalse(model.isPreparingRawCaptureExport)
        let state = await owner.snapshot()
        XCTAssertEqual(state.session.takeInReview, before)
        XCTAssertEqual(before.tearEvidenceSourceBinding?.rawSidecarData, fixture.sidecarData)
        // Existing exports with no requested companion still use the current raw source.
        let source = SessionExportSource.localRecordingSession(lastRecordingURL: fixture.mediaURL,
            sessionName: "Legacy raw export", config: nil)
        let archived = try await Task.detached { try Self.archive(source, in: fixture.directory) }.value
        XCTAssertTrue(archived.companions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), changed)
    }

    func testMissingMalformedUnsupportedAndOtherTakeCompanionsPreserveCurrentOwner() async throws {
        let fixture = try await fixture(Self.withFader(Self.tear(holds: 1)))
        let second = try await self.fixture(Self.withFader(Self.tear(holds: 2)), directory: fixture.directory, number: 2)
        let owner = worker([fixture, second])
        let firstTake = try await record(owner)
        let firstBytes = try ReferenceTearEvidenceCodec.encode(sourceBinding: XCTUnwrap(firstTake.tearEvidenceSourceBinding),
            review: firstTake.tearReview, projection: firstTake.tearProjection,
            performedLimitations: firstTake.tearPerformedLimitations)
        _ = await owner.retake()
        let current = try await record(owner)
        let legacy = await owner.restoreTearEvidence(nil)
        XCTAssertEqual(legacy.result, .notAnalysed)
        XCTAssertEqual(legacy.update.state.session.takeInReview, current)
        var unsupported = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        unsupported["schemaVersion"] = "scratchlab_reference_tear_evidence_v999"
        for data in [Data("{".utf8), try JSONSerialization.data(withJSONObject: unsupported), firstBytes] {
            let rejected = await owner.restoreTearEvidence(data)
            XCTAssertNil(rejected.result)
            XCTAssertNotNil(rejected.update.errorMessage)
            XCTAssertEqual(rejected.update.state.session.takeInReview, current)
        }
        _ = await owner.retake()
        let wrongPhase = await owner.restoreTearEvidence(firstBytes)
        XCTAssertNil(wrongPhase.result)
        XCTAssertNotNil(wrongPhase.update.errorMessage)
    }

    func testLegacyBabyChirpAndTransformerPacketShapesKeepDecodeAndRenderParity() async throws {
        let baby = Self.packets(1) + Self.packets(-1, start: 0.4, phase: 100).dropFirst()
        let cases: [(CaptureSessionScratchType, [Raw])] = [(.babyScratch, try Self.withFader(baby)),
            (.chirp, try Self.withFader(baby, closed: [0.36...0.439])),
            (.transform, try Self.withFader(Self.packets(1, duration: 0.6), closed: [0.2...0.249, 0.4...0.449, 0.6...0.649]))]
        for (scratchType, raw) in cases {
            let fixture = try await fixture(raw, scratchType: scratchType)
            let owner = worker([fixture])
            let before = try await record(owner)
            let source = SessionExportSource.localRecordingSession(lastRecordingURL: fixture.mediaURL,
                sessionName: "Legacy diagnostic", config: fixture.config)
            let archive = try await Task.detached { try Self.archive(source, in: fixture.directory) }.value
            XCTAssertTrue(archive.companions.isEmpty)
            XCTAssertEqual(archive.metadata.session.scratchTypeID, fixture.config.normalizedScratchTypeID)
            XCTAssertEqual(archive.metadata.session.scratchTypeName, fixture.config.normalizedScratchTypeName)
            XCTAssertEqual(archive.metadata.session.sessionName, "Legacy diagnostic")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sourceSidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: fixture.sidecarData)
            let sourceNotation = try XCTUnwrap(sourceSidecar.detectedNotation)
            let notation = try XCTUnwrap(archive.notationByTakeID[sourceSidecar.takeID])
            XCTAssertEqual(notation.scratchType, scratchType.rawValue)
            XCTAssertEqual(notation.recordMovementEvents, sourceNotation.recordMovementEvents.map(SessionExportRecordMovementEvent.init(from:)))
            XCTAssertEqual(notation.faderEvents, sourceNotation.faderEvents.map {
                SessionExportFaderEvent(startTime: $0.startTime, endTime: $0.endTime,
                    eventKind: $0.eventKind.rawValue, control: $0.control, fromValue: $0.fromValue,
                    toValue: $0.toValue, source: $0.source, confidence: $0.confidence)
            })
            XCTAssertEqual(notation.mixerMidiEvents, sourceNotation.mixerMidiEvents.map {
                SessionExportMixerMidiEvent(takeRelativeTime: $0.takeRelativeTime, deviceName: $0.deviceName,
                    channel: $0.channel, controller: $0.controller, value: $0.value,
                    normalizedValue: $0.normalizedValue, mappedControl: $0.mappedControl)
            })
            XCTAssertEqual(archive.replay.sessionID, sourceSidecar.sessionID)
            let timeline = try XCTUnwrap(archive.replay.takes.first?.timeline)
            XCTAssertEqual(timeline, SessionReplayTimeline.build(from: sourceNotation, takeDuration: timeline.takeDurationSeconds))
            let legacy = await owner.restoreTearEvidence(nil)
            XCTAssertEqual(legacy.result, .notAnalysed)
            let after = try XCTUnwrap(legacy.update.state.session.takeInReview)
            XCTAssertEqual(after, before)
            XCTAssertEqual(try geometry(after), try geometry(before))
            XCTAssertEqual(after.tearReview.totalCountedTearHoldCount, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), fixture.sidecarData)
        }
    }
}

@MainActor
final class ReferenceAuthoringViewModelTests: XCTestCase {

    func testMovementCheckSkipsBeatPreparationPersistsPurposeAndHasNoInventedRepetitions() async throws {
        let calls = LockedBox<[String]>([])
        let configuration = LockedBox<ReferenceAuthoringBridgeTakeConfiguration?>(nil)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { calls.update { $0.append("start") }; return .success(()) },
            stopRecording: { calls.update { $0.append("stop") }; return .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        let driver = ReferenceAuthoringWorkerDriver(hooks: hooks,
            pendingConfigurationHandler: { value in configuration.update { $0 = value } },
            prepareBeatHandler: { _, _, _ in
                calls.update { $0.append("beat") }
                throw ReferenceBeatAssetError.invalid("A movement check must never prepare a beat")
            })
        let worker = makeWorker(session: readySession(), hooks: hooks, driver: driver)
        let configured = await worker.configure(technique: .tear,
            pattern: ReferencePatternIdentity(id: "movement", name: "One movement", phraseBars: 1),
            bpm: 60, startingDirection: .forward, faderVariant: .faderOpenThroughout,
            handedness: .right, notes: "Unpaced", capturePurpose: .movementCheck)
        XCTAssertNil(configured.errorMessage)
        let started = await worker.startRecording()
        XCTAssertNil(started.errorMessage)
        XCTAssertEqual(started.state.session.phase, .recording)
        XCTAssertEqual(calls.read(), ["start"])
        let capture = try XCTUnwrap(configuration.read())
        XCTAssertTrue(capture.isMovementCheck)
        XCTAssertNil(capture.preparedBeat)
        XCTAssertNil(capture.plannedRecordingDurationSeconds)
        let config = capture.recordingSessionConfig(existing: nil, now: Date())
        XCTAssertEqual(config.captureMode, .movementCheck)
        XCTAssertEqual(config.beatEngineMode, .silent)
        XCTAssertEqual(config.countInBeats, 0)
        XCTAssertFalse(config.clickEnabled)
        XCTAssertFalse(config.beatEnabled)
        XCTAssertEqual(config.timingPrintedToRecording, .notPrinted)
        XCTAssertNil(RoutineCaptureDefaults.plannedTakeDurationSeconds(for: config))
        XCTAssertEqual(RoutineCaptureDefaults.stopReasonForBoundReached(for: config), .mediaLimit)
        let reopened = try JSONDecoder().decode(CaptureSessionConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(reopened, config)
        XCTAssertEqual(reopened.referenceCaptureIntent?.capturePurpose, .movementCheck)
        XCTAssertEqual(reopened.referenceCaptureIntent?.plan,
            ReferenceCapturePlan(countInBars: 0, repetitionCount: 0, tailBars: 0))
        XCTAssertNil(reopened.referenceCaptureIntent?.beatSpec)
        XCTAssertEqual(ReferenceCaptureIntentValidator.issues(intent: reopened.referenceCaptureIntent,
            requireBeatSpec: false), [])
        let stopped = await worker.stopRecording()
        XCTAssertNil(stopped.errorMessage)
        XCTAssertEqual(calls.read(), ["start", "stop"])
        let take = try XCTUnwrap(stopped.state.session.takeInReview)
        XCTAssertEqual(take.evidence.metadata.repetitionCount, 0)
        XCTAssertEqual(take.evidence.metadata.countInBars, 0)
        XCTAssertEqual(take.evidence.metadata.tailBars, 0)
        XCTAssertEqual(take.evidence.boundaries.repetitions, [])
        XCTAssertNil(take.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertEqual(take.evidence.metadata.captureIntent, reopened.referenceCaptureIntent)
        XCTAssertTrue(stopped.state.session.approvalBlockReason()?.contains("Movement checks") == true)
        var reviewed = stopped.state.session
        XCTAssertThrowsError(try reviewed.approveTakeInReview(notes: "Cannot make a check canonical"))
        XCTAssertNotEqual(reviewed.takeInReview?.evidence.metadata.lifecycleState, .approvedCanonical)
    }

    func testLegacyIntentWithoutPurposeRetainsCanonicalMeaning() throws {
        var session = readySession()
        let intent = try session.prepareCaptureIntentForRecording()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
        json.removeValue(forKey: "purpose")
        let legacy = try JSONDecoder().decode(ReferenceCaptureIntent.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.purpose)
        XCTAssertEqual(legacy.capturePurpose, .canonicalReference)
        XCTAssertFalse(legacy.isMovementCheck)
        XCTAssertEqual(legacy.plan.repetitionCount, 4)
        XCTAssertEqual(ReferenceCaptureIntentValidator.issues(intent: legacy, requireBeatSpec: false), [])
        XCTAssertEqual(try JSONDecoder().decode(ReferenceCaptureIntent.self,
            from: JSONEncoder().encode(legacy)), legacy)
        XCTAssertEqual(CaptureSessionCaptureMode.standardCaptureModes, [.calibrationNoClick, .timedClick])
    }

    func testUnappliedTechniqueAndEveryOtherCaptureSettingPreventStaleTakeStart() async {
        let changes: [(String, (ReferenceAuthoringViewModel) -> Void)] = [
            ("technique", { $0.selectedTechnique = .chirp }),
            ("pattern ID", { $0.patternID += "-changed" }),
            ("pattern name", { $0.patternName += " changed" }),
            ("phrase length", { $0.phraseBars += 1 }),
            ("BPM", { $0.bpm = 60 }),
            ("backing", { $0.beatEngineMode = .battleLoop }),
            ("purpose", { $0.capturePurpose = .movementCheck }),
            ("direction", { $0.startingDirectionRawValue = "changed" }),
            ("fader", { $0.faderVariantRawValue = ReferenceFaderVariant.crossfader.rawValue }),
            ("handedness", { $0.handednessRawValue = CaptureSessionHandedness.left.rawValue }),
            ("notes", { $0.notes = "changed" })
        ]
        for (name, change) in changes {
            let starts = LockedBox(0)
            let hooks = ReferenceAuthoringRecordingHooks(
                startRecording: { starts.update { $0 += 1 }; return .success(()) },
                stopRecording: { .success(self.goodArtifacts()) },
                currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
            let worker = makeWorker(session: readySession(), hooks: hooks)
            let model = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
            change(model)
            model.startRecording()
            XCTAssertEqual(model.visibleMessage, "Apply Authoring Setup after changing the capture settings.", name)
            XCTAssertFalse(model.isWorking, name)
            XCTAssertEqual(starts.read(), 0, name)
            XCTAssertEqual(model.session.selectedTechnique, .babyScratch, name)
        }
    }

    @MainActor private final class BeatPreviewSpy: PracticeBeatPlaybackEngine {
        var modes: [BeatEngineMode] = []
        var playing = false
        var shouldFail = false
        func start(mode: BeatEngineMode, bpm: Int) throws {
            if shouldFail { throw ScratchLabBeatEngineError.unableToStartAudio }
            modes.append(mode)
            playing = true
        }
        func stop() { playing = false }
        func hardResetBeatPlayback() { stop() }
    }

    func testSelectedBackingSurvivesWorkerBridgeAndSessionPersistence() async throws {
        let configuration = LockedBox<ReferenceAuthoringBridgeTakeConfiguration?>(nil)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) }, stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = readySession()
        session.selectBeatEngineMode(.minimalFunk)
        let worker = ReferenceAuthoringWorker(session: session,
            driver: ReferenceAuthoringWorkerDriver(hooks: hooks,
                pendingConfigurationHandler: { value in configuration.update { $0 = value } }),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory))
        let started = await worker.startRecording()
        XCTAssertNil(started.errorMessage)
        let chosen = try XCTUnwrap(configuration.read())
        XCTAssertEqual(chosen.beatEngineMode, .minimalFunk)
        let config = chosen.recordingSessionConfig(existing: nil, now: Date())
        let restored = try JSONDecoder().decode(CaptureSessionConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.beatEngineMode, .minimalFunk)
        XCTAssertTrue(restored.beatEnabled)
        XCTAssertEqual(restored.swingAmount, BeatEngineMode.minimalFunk.defaultSwingAmount)
        XCTAssertEqual(restored.bpm, 95)
        var frozen = started.state.session
        frozen.selectBeatEngineMode(.battleLoop)
        XCTAssertEqual(frozen.selectedBeatEngineMode, .minimalFunk, "A later form edit must not rewrite an in-flight take's backing.")
    }

    func testBackingPreviewStopsOnSelectionChangeCaptureAndViewExit() async {
        let spy = BeatPreviewSpy()
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        let worker = makeWorker(session: readySession(), hooks: hooks)
        let model = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot(), beatPreviewEngine: spy)
        model.toggleBeatPreview()
        XCTAssertTrue(spy.playing)
        XCTAssertEqual(spy.modes, [.boomBapTrainer])
        model.bpm = 90
        XCTAssertFalse(spy.playing)
        XCTAssertFalse(model.isPreviewingBeat)
        model.toggleBeatPreview()
        model.startRecording() // Unapplied tempo is refused, but preview must still stop.
        XCTAssertFalse(spy.playing)
        XCTAssertTrue(model.visibleMessage?.contains("Apply Authoring Setup") == true)
        model.toggleBeatPreview()
        model.cancelTransientWorkForViewDisappearance()
        XCTAssertFalse(spy.playing)
        spy.shouldFail = true
        model.toggleBeatPreview()
        XCTAssertFalse(model.isPreviewingBeat)
        XCTAssertTrue(model.visibleMessage?.contains("Could not play") == true)
    }

    func testRecordedAudioIsPlayableWithoutBeatBindingAndNewLoadClearsOldMedia() async throws {
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        let stopped = await worker.stopRecording()
        let take = try XCTUnwrap(stopped.state.session.takeInReview)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mediaURL = folder.appendingPathComponent("recorded.mov")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 24_000)
        do {
            let file = try AVAudioFile(forWriting: mediaURL.deletingPathExtension().appendingPathExtension("wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        let controller = ReferenceFinalizedMediaReviewController()
        controller.load(take: take, mediaURL: mediaURL, beatRootURL: nil)
        let loaded = await waitUntil { controller.state != .loading }
        XCTAssertTrue(loaded)
        XCTAssertEqual(controller.state, .missingVideo)
        XCTAssertTrue(controller.canPlay)
        XCTAssertNotNil(controller.beatBindingIssue, "Playback must not silently satisfy beat approval.")
        XCTAssertNil(controller.boundBeatID)
        let model = ReferenceAuthoringViewModel(worker: worker, initialState: stopped.state)
        model.mediaReview.load(take: take, mediaURL: mediaURL, beatRootURL: nil)
        _ = await waitUntil { model.mediaReview.state != .loading }
        model.approveCanonical()
        XCTAssertTrue(model.visibleMessage?.contains("BeatSpec") == true)
        XCTAssertNotEqual(model.reviewedTake?.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertTrue(model.canEditReviewedTake)
        XCTAssertTrue(model.approvalBlockReasons.contains { $0.contains("BeatSpec") })
        let refusedCombined = await model.rawCaptureExportSource(config: nil, approvingCanonical: true)
        XCTAssertNil(refusedCombined)
        XCTAssertTrue(model.rawCaptureExportError?.contains("BeatSpec") == true)
        XCTAssertNotEqual(model.reviewedTake?.evidence.metadata.lifecycleState, .approvedCanonical)
        model.retake()
        let retained = await waitUntil { model.session.phase == .readyToRecord && !model.isWorking }
        XCTAssertTrue(retained)
        XCTAssertEqual(model.reviewedTake?.id, take.id)
        XCTAssertFalse(model.canEditReviewedTake)
        XCTAssertTrue(model.approvalBlockReasons.contains("This session is not reviewing a take."))
        controller.load(take: take, mediaURL: folder.appendingPathComponent("missing.mov"), beatRootURL: nil)
        XCTAssertEqual(controller.state, .missingAudio)
        XCTAssertFalse(controller.canPlay)
        XCTAssertNil(controller.videoPlayer)
        XCTAssertNil(controller.beatBindingIssue)
    }

    func testReviewRangesCannotSeekBeyondTheMeasuredTake() {
        XCTAssertEqual(ReferenceFinalizedMediaReviewController.playableRange(start: 0, end: 20, duration: 10.5), 0...10.5)
        XCTAssertEqual(ReferenceFinalizedMediaReviewController.playableRange(start: 5, end: 9, duration: 10.5), 5...9)
        XCTAssertEqual(ReferenceFinalizedMediaReviewController.playableRange(start: -0.00001, end: 2.526, duration: 10.5), 0...2.526)
        XCTAssertNil(ReferenceFinalizedMediaReviewController.playableRange(start: -2, end: -1, duration: 10.5))
        for start in [10.5, .infinity, .nan] {
            XCTAssertNil(ReferenceFinalizedMediaReviewController.playableRange(start: start, end: 20, duration: 10.5))
        }
        XCTAssertNil(ReferenceFinalizedMediaReviewController.playableRange(start: 5, end: 4, duration: 10.5))
    }

    func testReturningToCameraSetupKeepsTheReviewedTakeAndPreference() async throws {
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.markPreferredRepetition(1)
        let state = await worker.snapshot()
        let model = ReferenceAuthoringViewModel(worker: worker, initialState: state)
        model.showCameraSetup()
        XCTAssertEqual(model.navigationRequest?.destination, .setup)
        XCTAssertEqual(model.session, state.session)
        XCTAssertEqual(model.reviewedTake?.evidence.boundaries.selectedRepetitionIndex, 1)
        XCTAssertTrue(model.visibleMessage?.contains("next recording") == true)
    }
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&storage)
        }
    }

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "synthetic-controller",
            deviceName: "Synthetic Controller",
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

    func testWorkflowStatusDistinguishesSetupProgressFromPersistentPhase() {
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: false,
                isApplyingSetup: false
            ),
            "Setup required"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: false,
                isApplyingSetup: true
            ),
            "Applying setup…"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Setup applied — calibrate crossfader"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .calibrating,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Calibrating"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .readyToRecord,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Ready to record"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .recording,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Recording"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .reviewing(takeIndex: 0),
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Reviewing"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .complete,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Approved draft"
        )
    }

    func testApplySetupBehindInFlightPreflightRefreshClearsBusyPresentationAndPollingContinues() async {
        let firstRefreshEntered = expectation(description: "first preflight refresh entered")
        let releaseFirstRefresh = DispatchSemaphore(value: 0)
        let refreshCount = LockedBox(0)
        let address = calibration.address
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: {
                refreshCount.update { $0 += 1 }
                let count = refreshCount.read()
                if count == 1 {
                    firstRefreshEntered.fulfill()
                    _ = releaseFirstRefresh.wait(timeout: .now() + 2)
                }
                return ReferencePreflightSnapshot(
                    controllerName: "Synthetic Controller",
                    controllerIdentifier: "synthetic-controller",
                    observedCrossfaderAddress: address,
                    latestCrossfaderRawValue: 32,
                    calibration: nil,
                    crossfaderEventCount: count,
                    platterEventCount: 20_440,
                    platterIsMoving: true,
                    audioInputPeakLevel: 0.1794,
                    audioDeviceName: "Synthetic Audio",
                    watchIsReachable: false,
                    watchMotionIsStreaming: false,
                    cameraDeviceName: "Synthetic Camera",
                    cameraIsActive: true
                )
            },
            latestCalibrationObservation: { nil }
        )
        var initialSession = ReferenceAuthoringSession(
            authoringSessionID: "synthetic-configuring-session",
            operatorName: "Karl"
        )
        initialSession.selectTechnique(.babyScratch)
        let worker = makeWorker(session: initialSession, hooks: hooks)
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )
        viewModel.selectedTechnique = .babyScratch
        viewModel.patternID = "baby-scratch-hardware-smoke"
        viewModel.patternName = "Baby Scratch Hardware Smoke"
        viewModel.bpm = 95
        viewModel.startingDirectionRawValue = ReferenceStartingPlatterDirection.forward.rawValue
        viewModel.faderVariantRawValue = ReferenceFaderVariant.crossfader.rawValue
        viewModel.handednessRawValue = CaptureSessionHandedness.right.rawValue

        viewModel.startPreflightPolling(intervalNanoseconds: 5_000_000)
        await fulfillment(of: [firstRefreshEntered], timeout: 2)
        viewModel.applySetup()

        XCTAssertTrue(viewModel.isWorking)
        XCTAssertEqual(viewModel.workflowStatusText, "Applying setup…")

        releaseFirstRefresh.signal()
        let setupCompleted = await waitUntil {
            !viewModel.isWorking
                && viewModel.session.configurationIsComplete
                && viewModel.session.latestPreflight != nil
        }
        let refreshesAtSetupCompletion = refreshCount.read()
        let pollingContinued = await waitUntil {
            refreshCount.read() > refreshesAtSetupCompletion
        }
        viewModel.cancelPreflightPolling()

        XCTAssertTrue(setupCompleted)
        XCTAssertTrue(pollingContinued)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertTrue(viewModel.session.configurationIsComplete)
        XCTAssertEqual(viewModel.session.phase, .configuring)
        XCTAssertEqual(viewModel.visibleMessage, "Authoring setup applied.")
        XCTAssertEqual(viewModel.workflowStatusText, "Setup applied — calibrate crossfader")
        XCTAssertNotNil(viewModel.session.latestPreflight)
        XCTAssertGreaterThan(refreshCount.read(), 1)
    }

    func testRecordingAndFinalizationRunOffMainAndReturnSnapshotsToMainActor() async {
        let threadFlags = LockedBox<[Bool]>([])
        let artifacts = goodArtifacts()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                threadFlags.update { $0.append(Thread.isMainThread) }
                return .success(())
            },
            stopRecording: {
                threadFlags.update { $0.append(Thread.isMainThread) }
                return .success(artifacts)
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)

        let start = await worker.startRecording()
        XCTAssertNil(start.errorMessage)
        let stop = await worker.stopRecording()
        XCTAssertNil(stop.errorMessage)
        XCTAssertEqual(threadFlags.read(), [false, false])

        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )
        await viewModel.refreshPreflightOnce()
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNotNil(viewModel.state.session.latestPreflight)
        XCTAssertEqual(viewModel.state.session.phase, .reviewing(takeIndex: 0))
    }

    func testPreflightAndCalibrationPollingCanBeCancelled() async throws {
        let preflightCount = LockedBox(0)
        let calibrationCount = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: {
                preflightCount.update { $0 += 1 }
                return self.passingSnapshot()
            },
            latestCalibrationObservation: {
                var next = 0
                calibrationCount.update {
                    $0 += 1
                    next = $0
                }
                return CrossfaderCalibrationObservation(rawValue: 0, observationSequence: next)
            }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )

        viewModel.startPreflightPolling(intervalNanoseconds: 5_000_000)
        viewModel.startCalibrationPolling(intervalNanoseconds: 5_000_000)
        try await Task.sleep(nanoseconds: 40_000_000)
        viewModel.stopPolling()
        try await Task.sleep(nanoseconds: 20_000_000)
        let stablePreflightCount = preflightCount.read()
        let stableCalibrationCount = calibrationCount.read()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertGreaterThan(stablePreflightCount, 0)
        XCTAssertGreaterThan(stableCalibrationCount, 0)
        XCTAssertEqual(preflightCount.read(), stablePreflightCount)
        XCTAssertEqual(calibrationCount.read(), stableCalibrationCount)
        XCTAssertFalse(viewModel.isPreflightPolling)
        XCTAssertFalse(viewModel.isCalibrationPolling)
    }

    func testViewDisappearanceCancelsFinalizationWaitWithoutApplyingArtifacts() async {
        let stopEntered = expectation(description: "stop hook entered")
        let cancellationObserved = expectation(description: "finalization wait cancellation observed")
        let releaseStop = DispatchSemaphore(value: 0)
        let startCount = LockedBox(0)
        let stopCount = LockedBox(0)
        let cancellationCount = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                startCount.update { $0 += 1 }
                return .success(())
            },
            stopRecording: {
                stopCount.update { $0 += 1 }
                stopEntered.fulfill()
                _ = releaseStop.wait(timeout: .now() + 2)
                return .failure(.recordingFailed("Synthetic cancelled finalization wait."))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(
            hooks: hooks,
            finalizationWaitCancellationHandler: {
                cancellationCount.update { $0 += 1 }
                releaseStop.signal()
                cancellationObserved.fulfill()
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceAuthoringViewModelTests-\(UUID().uuidString)")
        let worker = ReferenceAuthoringWorker(
            session: readySession(),
            driver: driver,
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
        _ = await worker.startRecording()
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )

        viewModel.stopRecording()
        await fulfillment(of: [stopEntered], timeout: 2)
        viewModel.cancelTransientWorkForViewDisappearance()
        await fulfillment(of: [cancellationObserved], timeout: 2)
        let workerState = await worker.snapshot()

        XCTAssertEqual(startCount.read(), 1)
        XCTAssertEqual(stopCount.read(), 1)
        XCTAssertEqual(cancellationCount.read(), 1)
        XCTAssertEqual(workerState.session.phase, .recording)
        XCTAssertTrue(workerState.session.takes.isEmpty)
        XCTAssertEqual(viewModel.state.session.phase, .recording)
        XCTAssertFalse(viewModel.isWorking)
    }

    func testBridgeErrorAndInvalidStopTransitionAreSurfacedWithoutChangingPhase() async {
        let startFailureHooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .failure(.recordingFailed("Synthetic bridge failure.")) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let failingWorker = makeWorker(session: readySession(), hooks: startFailureHooks)
        let failedStart = await failingWorker.startRecording()
        XCTAssertEqual(failedStart.errorMessage, "Recording failed: Synthetic bridge failure.")
        XCTAssertEqual(failedStart.state.session.phase, .readyToRecord)

        let invalidStop = await failingWorker.stopRecording()
        XCTAssertEqual(invalidStop.errorMessage, "No recording is in progress.")
        XCTAssertEqual(invalidStop.state.session.phase, .readyToRecord)
    }

    func testAutoDetectionNeverOverwritesCXLTechniqueSelection() async {
        let artifacts = goodArtifacts(autoDetectedTechnique: .chirp)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(artifacts) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        let stopped = await worker.stopRecording()
        let take = stopped.state.session.takeInReview

        XCTAssertEqual(take?.evidence.metadata.technique, .babyScratch)
        XCTAssertEqual(take?.autoDetectedTechnique, .chirp)
        XCTAssertEqual(take?.autoDetectionDisagreesWithSelection, true)
    }

    func testApprovalRemainsUnpublishedAndLegacyDataRemainsUnavailable() async {
        let artifacts = goodArtifacts()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(artifacts) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(0)
        let approved = await worker.approveCanonical(notes: "Synthetic approval fixture only.")
        let take = approved.state.session.takes[0]

        XCTAssertNil(approved.errorMessage)
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertFalse(take.evidence.metadata.lifecycleState.isPlayableByLearner)
        XCTAssertNotEqual(take.evidence.metadata.lifecycleState, .published)

        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_900)
        )
        if case .available = registry.resolve(technique: .babyScratch) {
            XCTFail("Withdrawn legacy data must never resolve as trainable.")
        }
    }

    func testPreparingNextTakeRetainsSetupAndClearsOnlyTransientReviewState() async throws {
        let startCount = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                startCount.update { $0 += 1 }
                return .success(())
            },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(0)
        _ = await worker.approveCanonical(notes: "Retained approval")
        let approvedState = await worker.snapshot()
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: approvedState)
        viewModel.reviewNotes = "future approval input"
        viewModel.tearReviewNotes = "future correction input"
        var expected = approvedState.session
        expected.phase = .readyToRecord

        XCTAssertNil(viewModel.nextTakeBlockReason(isExportPreparing: false))
        viewModel.prepareNextTake(isExportPreparing: false)
        let prepared = await waitUntil { !viewModel.isWorking && viewModel.session.phase == .readyToRecord }

        XCTAssertTrue(prepared)
        XCTAssertEqual(viewModel.session, expected)
        XCTAssertEqual(viewModel.reviewNotes, "")
        XCTAssertEqual(viewModel.tearReviewNotes, "")
        XCTAssertEqual(startCount.read(), 1, "Next take must not start recording")
        XCTAssertEqual(
            viewModel.visibleMessage,
            "Approved take \(approvedState.session.takes[0].id) retained. Ready for the next take; press Record Draft when ready."
        )
    }

    func testPreparingNextTakeRejectsBusyOrPreparingExportWithoutLosingInputs() async {
        let preflightEntered = expectation(description: "busy preflight entered")
        let releasePreflight = DispatchSemaphore(value: 0)
        let startCount = LockedBox(0)
        let blockNextPreflight = LockedBox(false)
        let blocked = ReferencePreflightSnapshot(
            controllerName: nil,
            controllerIdentifier: nil,
            observedCrossfaderAddress: nil,
            latestCrossfaderRawValue: nil,
            calibration: nil,
            crossfaderEventCount: 0,
            platterEventCount: 0,
            platterIsMoving: false,
            audioInputPeakLevel: nil,
            audioDeviceName: nil,
            watchIsReachable: false,
            watchMotionIsStreaming: false
        )
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                startCount.update { $0 += 1 }
                return .success(())
            },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: {
                if blockNextPreflight.read() {
                    preflightEntered.fulfill()
                    _ = releasePreflight.wait(timeout: .now() + 2)
                    return blocked
                }
                return self.passingSnapshot()
            },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(0)
        _ = await worker.approveCanonical(notes: "Retained approval")
        let approvedState = await worker.snapshot()
        let initialStartCount = startCount.read()
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: approvedState)
        viewModel.reviewNotes = "keep approval input"
        viewModel.tearReviewNotes = "keep correction input"

        blockNextPreflight.update { $0 = true }
        viewModel.startRecording()
        await fulfillment(of: [preflightEntered], timeout: 2)
        XCTAssertTrue(viewModel.isWorking)
        XCTAssertEqual(viewModel.nextTakeBlockReason(isExportPreparing: false), "Wait for the current operation to finish.")
        viewModel.prepareNextTake(isExportPreparing: false)
        XCTAssertEqual(viewModel.session, approvedState.session)
        XCTAssertEqual(viewModel.reviewNotes, "keep approval input")
        XCTAssertEqual(viewModel.tearReviewNotes, "keep correction input")
        XCTAssertEqual(viewModel.visibleMessage, "Wait for the current operation to finish.")
        releasePreflight.signal()
        let busyFinished = await waitUntil { !viewModel.isWorking }
        XCTAssertTrue(busyFinished)
        XCTAssertEqual(viewModel.session.phase, .complete)
        XCTAssertEqual(viewModel.session.takes, approvedState.session.takes)
        XCTAssertEqual(viewModel.session.selectedTechnique, approvedState.session.selectedTechnique)
        XCTAssertEqual(viewModel.session.selectedPattern, approvedState.session.selectedPattern)
        XCTAssertEqual(viewModel.session.selectedBPM, approvedState.session.selectedBPM)
        XCTAssertEqual(viewModel.session.confirmedCalibration, approvedState.session.confirmedCalibration)
        XCTAssertEqual(viewModel.reviewNotes, "keep approval input")
        XCTAssertEqual(viewModel.tearReviewNotes, "keep correction input")
        XCTAssertEqual(startCount.read(), initialStartCount)
        let postBusySession = viewModel.session

        XCTAssertEqual(
            viewModel.nextTakeBlockReason(isExportPreparing: true),
            "Wait for the capture export to finish."
        )
        viewModel.prepareNextTake(isExportPreparing: true)

        XCTAssertEqual(viewModel.session, postBusySession)
        XCTAssertEqual(viewModel.reviewNotes, "keep approval input")
        XCTAssertEqual(viewModel.tearReviewNotes, "keep correction input")
        XCTAssertEqual(viewModel.visibleMessage, "Wait for the capture export to finish.")
        XCTAssertFalse(viewModel.isWorking)
    }

    func testPreparingNextTakeRejectsDuplicateAndStaleApprovedTakeRequests() async throws {
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(0)
        _ = await worker.approveCanonical(notes: "First approval")
        let firstComplete = await worker.snapshot()
        let firstApproved = try XCTUnwrap(firstComplete.session.latestRecordedTake?.id)

        let firstRequest = Task { await worker.prepareNextTake(afterApprovedTakeID: firstApproved) }
        let duplicateRequest = Task { await worker.prepareNextTake(afterApprovedTakeID: firstApproved) }
        let responses = [await firstRequest.value, await duplicateRequest.value]
        XCTAssertEqual(responses.filter { $0.errorMessage == nil }.count, 1)
        XCTAssertEqual(responses.filter { $0.errorMessage != nil }.count, 1)
        let afterDuplicate = await worker.snapshot()
        XCTAssertEqual(afterDuplicate.session.phase, .readyToRecord)
        XCTAssertEqual(afterDuplicate.session.takes.count, 1)

        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(1)
        _ = await worker.approveCanonical(notes: "Second approval")
        let secondComplete = await worker.snapshot()
        XCTAssertNotEqual(secondComplete.session.latestRecordedTake?.id, firstApproved)
        let stale = await worker.prepareNextTake(afterApprovedTakeID: firstApproved)
        XCTAssertNotNil(stale.errorMessage)
        let afterStale = await worker.snapshot()
        XCTAssertEqual(afterStale.session, secondComplete.session)
    }

    func testFourExplicitApprovalsRetainDistinctTakesAndImmutableIntent() async throws {
        let artifactIndex = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                var index = 0
                artifactIndex.update {
                    index = $0
                    $0 += 1
                }
                return .success(self.goodArtifacts(
                    suffix: "take-\(index + 1)",
                    recordedAt: Date(timeIntervalSince1970: 1_788_020_000 + Double(index))
                ))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        let tempos = [80, 80, 110, 110]
        var retained: [ReferenceAuthoringTake] = []

        for (index, bpm) in tempos.enumerated() {
            _ = await worker.configure(
                technique: .babyScratch,
                pattern: ReferencePatternIdentity(id: "quarter_notes", name: "Quarter notes", phraseBars: 1),
                bpm: bpm,
                startingDirection: index.isMultiple(of: 2) ? .forward : .backward,
                faderVariant: .faderOpenThroughout,
                handedness: .right,
                notes: "take \(index + 1)"
            )
            let started = await worker.startRecording()
            XCTAssertNil(started.errorMessage)
            let stopped = await worker.stopRecording()
            XCTAssertNil(stopped.errorMessage)
            _ = await worker.selectRepetitionForApproval(index % 4)
            let approved = await worker.approveCanonical(notes: "Approved take \(index + 1)")
            XCTAssertNil(approved.errorMessage)
            let snapshot = await worker.snapshot()
            retained.append(try XCTUnwrap(snapshot.session.latestRecordedTake))
            XCTAssertEqual(snapshot.session.takes, retained)
            if index < tempos.count - 1 {
                let prepared = await worker.prepareNextTake(afterApprovedTakeID: retained[index].id)
                XCTAssertNil(prepared.errorMessage)
            }
        }

        let session = (await worker.snapshot()).session
        XCTAssertEqual(session.phase, .complete)
        XCTAssertEqual(session.takes.map(\.evidence.metadata.bpm), [80, 80, 80, 80])
        XCTAssertEqual(session.takes.map(\.evidence.metadata.startingPlatterDirection), [.forward, .forward, .forward, .forward])
        let immutableIntent = try XCTUnwrap(session.takes.first?.evidence.metadata.captureIntent)
        XCTAssertTrue(session.takes.allSatisfy { $0.evidence.metadata.captureIntent == immutableIntent })
        XCTAssertEqual(session.takes.map(\.evidence.audio.fileName), (1...4).map { "synthetic-reference-take-\($0).wav" })
        XCTAssertEqual(Set(session.takes.map(\.id)).count, 4)
        XCTAssertEqual(Set(session.takes.map(\.evidence.metadata.takeNumber)).count, 4)
        XCTAssertEqual(artifactIndex.read(), 4)
        XCTAssertTrue(session.takes.allSatisfy {
            $0.evidence.metadata.lifecycleState == .approvedCanonical
                && !$0.evidence.metadata.lifecycleState.isPlayableByLearner
        })
    }

    func testUnapprovedContinuationRetainsCaptureHistoryAndRequestsTheSuccessfulDestination() async throws {
        for newScratch in [false, true] {
            let starts = LockedBox(0)
            let finalizedURL = FileManager.default.temporaryDirectory.appendingPathComponent("retained-\(UUID()).mov")
            let hooks = ReferenceAuthoringRecordingHooks(
                startRecording: { starts.update { $0 += 1 }; return .success(()) },
                stopRecording: { .success(self.goodArtifacts(watchEvidence: .missing(syncState: "unavailable"))) },
                currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
            )
            var session = readySession()
            session.notes = "Notes belonging to the finalized capture"
            let driver = ReferenceAuthoringWorkerDriver(hooks: hooks, lastFinalizedRecordingURLProvider: { finalizedURL })
            let worker = makeWorker(session: session, hooks: hooks, driver: driver)
            _ = await worker.startRecording()
            let finalized = await worker.stopRecording()
            let retained = try XCTUnwrap(finalized.state.session.latestRecordedTake)
            let model = ReferenceAuthoringViewModel(worker: worker, initialState: finalized.state, beatPreviewEngine: BeatPreviewSpy())
            model.notes = session.notes
            model.reviewNotes = "Transient review input"
            model.tearReviewNotes = "Transient tear input"
            XCTAssertFalse(model.canApprove)
            XCTAssertNil(model.continuationBlockReason(newScratch: newScratch))
            XCTAssertNil(model.navigationRequest)

            if newScratch { model.prepareNewScratch() } else { model.retake() }
            let finished = await waitUntil { !model.isWorking }
            XCTAssertTrue(finished)
            XCTAssertEqual(model.navigationRequest?.destination, newScratch ? .setup : .capture)
            XCTAssertEqual(model.session.takes, finalized.state.session.takes)
            XCTAssertEqual(model.reviewedTake, retained)
            XCTAssertEqual(model.lastFinalizedRecordingURL, finalizedURL)
            XCTAssertTrue(model.canExportRawCapture)
            XCTAssertEqual(model.session.confirmedCalibration, session.confirmedCalibration)
            XCTAssertEqual(model.session.latestPreflightSnapshot, finalized.state.session.latestPreflightSnapshot)
            XCTAssertEqual(model.session.takes[0].evidence.metadata.notes, session.notes)
            XCTAssertNil(model.session.takes[0].evidence.metadata.reviewDecision)
            XCTAssertEqual(model.notes, newScratch ? "" : session.notes)
            XCTAssertEqual(model.reviewNotes, "")
            XCTAssertEqual(model.tearReviewNotes, "")
            XCTAssertEqual(starts.read(), 1, "Navigation must never start another capture.")
            let request = model.navigationRequest
            if newScratch {
                model.prepareNewScratch()
                XCTAssertEqual(model.navigationRequest, request, "Refused repeated input must not request another scroll.")
            } else {
                let ready = model.session
                model.retake()
                let repeated = await waitUntil { !model.isWorking }
                XCTAssertTrue(repeated)
                XCTAssertEqual(model.session, ready, "Repeating Retake is safe with a legacy nil future intent.")
                XCTAssertEqual(model.navigationRequest?.destination, .capture)
            }
        }
    }

    func testContinuationExportAndStaleIdentityRefusalsPreserveInputsWithoutNavigation() async throws {
        for newScratch in [false, true] {
            let hooks = ReferenceAuthoringRecordingHooks(
                startRecording: { .success(()) }, stopRecording: { .success(self.goodArtifacts()) },
                currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
            )
            let worker = makeWorker(session: readySession(), hooks: hooks)
            _ = await worker.startRecording()
            let first = await worker.stopRecording()
            let firstID = try XCTUnwrap(first.state.session.latestRecordedTake?.id)
            let model = ReferenceAuthoringViewModel(worker: worker, initialState: first.state, beatPreviewEngine: BeatPreviewSpy())
            model.notes = "Keep setup input"
            model.reviewNotes = "Keep review input"
            model.tearReviewNotes = "Keep tear input"
            XCTAssertNotNil(model.continuationBlockReason(newScratch: newScratch, isExportPreparing: true))
            if newScratch { model.prepareNewScratch(isExportPreparing: true) } else { model.retake(isExportPreparing: true) }
            XCTAssertEqual(model.session, first.state.session)
            XCTAssertNil(model.navigationRequest)
            XCTAssertFalse(model.isWorking)

            // The view still offers the first take while the serial owner has
            // finalized a second one. Its captured action ID must be refused.
            _ = await worker.retake(afterTakeID: firstID)
            _ = await worker.startRecording()
            let second = await worker.stopRecording()
            XCTAssertNotEqual(second.state.session.latestRecordedTake?.id, firstID)
            if newScratch { model.prepareNewScratch() } else { model.retake() }
            let finished = await waitUntil { !model.isWorking }
            XCTAssertTrue(finished)
            XCTAssertEqual(model.session, second.state.session)
            XCTAssertNotNil(model.visibleMessage)
            XCTAssertNil(model.navigationRequest)
            XCTAssertEqual(model.notes, "Keep setup input")
            XCTAssertEqual(model.reviewNotes, "Keep review input")
            XCTAssertEqual(model.tearReviewNotes, "Keep tear input")
            let owner = await worker.snapshot()
            XCTAssertEqual(owner.session, second.state.session)
        }
    }

    func testPendingWatchOrSourceBlocksViewModelContinuationAndReject() async throws {
        let identity = ReferenceTakeSourceIdentity(sessionID: "capture", takeID: "take-001", takeNumber: 1, takeToken: "token")
        let pendingStates: [(ReferenceWatchEvidence, ReferencePerTakeSourceState?)] = [
            (.acknowledgedTransferPending, nil),
            (.linked(motionFileName: "watch.json"), .waitingForLateTransfer(identity: identity, deadline: .distantFuture)),
        ]
        for (watch, source) in pendingStates {
            let hooks = ReferenceAuthoringRecordingHooks(
                startRecording: { .success(()) },
                stopRecording: { .success(self.goodArtifacts(watchEvidence: watch, sourceState: source)) },
                currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
            )
            let worker = makeWorker(session: readySession(), hooks: hooks)
            _ = await worker.startRecording()
            let finalized = await worker.stopRecording()
            let model = ReferenceAuthoringViewModel(worker: worker, initialState: finalized.state, beatPreviewEngine: BeatPreviewSpy())
            model.reviewNotes = "Retain until transfer resolves"
            XCTAssertFalse(model.canRejectReviewedTake)
            XCTAssertNotNil(model.continuationBlockReason(newScratch: true))
            XCTAssertNotNil(model.continuationBlockReason(newScratch: false))
            model.prepareNewScratch()
            model.retake()
            model.rejectTake()
            let owner = await worker.snapshot()
            XCTAssertEqual(owner.session, finalized.state.session)
            XCTAssertEqual(model.session, finalized.state.session)
            XCTAssertEqual(model.reviewNotes, "Retain until transfer resolves")
            XCTAssertNil(model.navigationRequest)
            XCTAssertFalse(model.isWorking)
        }
    }

    func testAutomaticStopFinalizesOnceAndBusyFinalizationRefusesContinuation() async throws {
        let stopEntered = expectation(description: "automatic stop reached finalization")
        let releaseStop = DispatchSemaphore(value: 0)
        defer { releaseStop.signal() }
        let stops = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                stops.update { $0 += 1 }
                stopEntered.fulfill()
                _ = releaseStop.wait(timeout: .now() + 3)
                return .success(self.goodArtifacts())
            },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        let recording = await worker.startRecording()
        XCTAssertNil(recording.errorMessage)
        let model = ReferenceAuthoringViewModel(worker: worker, initialState: recording.state, beatPreviewEngine: BeatPreviewSpy())
        model.reviewNotes = "Preserve while busy"
        model.captureRecordingDidStop()
        model.captureRecordingDidStop()
        model.stopRecording()
        await fulfillment(of: [stopEntered], timeout: 2)
        XCTAssertTrue(model.isWorking)
        XCTAssertFalse(model.canRejectReviewedTake)
        XCTAssertNotNil(model.continuationBlockReason(newScratch: true))
        XCTAssertNotNil(model.continuationBlockReason(newScratch: false))
        model.prepareNewScratch()
        model.retake()
        XCTAssertEqual(model.session, recording.state.session)
        XCTAssertEqual(model.reviewNotes, "Preserve while busy")
        XCTAssertNil(model.navigationRequest)
        releaseStop.signal()
        let finalized = await waitUntil { !model.isWorking && model.session.takes.count == 1 }
        XCTAssertTrue(finalized)
        let retained = model.session
        model.captureRecordingDidStop()
        model.stopRecording()
        let owner = await worker.snapshot()
        XCTAssertEqual(stops.read(), 1)
        XCTAssertEqual(owner.session, retained)
        XCTAssertEqual(model.session.phase, .reviewing(takeIndex: 0))
        XCTAssertNil(model.navigationRequest)
    }

    func testStopBeforeStartPublicationIsRecoveredByActiveRecordingReconciliationExactlyOnce() async {
        let startEntered = expectation(description: "start waits before publishing its result")
        let releaseStart = DispatchSemaphore(value: 0)
        defer { releaseStart.signal() }
        let starts = LockedBox(0)
        let stops = LockedBox(0)
        let recordingHasStopped = LockedBox(false)
        let reconciliations = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                starts.update { $0 += 1 }
                startEntered.fulfill()
                _ = releaseStart.wait(timeout: .now() + 3)
                return .success(())
            },
            stopRecording: {
                stops.update { $0 += 1 }
                recordingHasStopped.update { $0 = false }
                return .success(self.goodArtifacts())
            },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(hooks: hooks, recordingHasStoppedProvider: {
            reconciliations.update { $0 += 1 }
            return recordingHasStopped.read()
        })
        let worker = makeWorker(session: readySession(), hooks: hooks, driver: driver)
        let initial = await worker.snapshot()
        let model = ReferenceAuthoringViewModel(worker: worker, initialState: initial, beatPreviewEngine: BeatPreviewSpy())
        model.startRecording()
        await fulfillment(of: [startEntered], timeout: 2)
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.session.phase, .readyToRecord)

        // The engine has already stopped this capture while the successful
        // start response is still awaiting publication on the main actor.
        recordingHasStopped.update { $0 = true }
        model.captureRecordingDidStop()
        model.captureRecordingDidStop()
        XCTAssertEqual(stops.read(), 0, "The busy UI edge must not finalize an unpublished recording.")
        XCTAssertEqual(reconciliations.read(), 0)
        releaseStart.signal()

        // No further UI edge is sent: the active-recording provider must
        // recover the completion once the start response has been applied.
        let finalized = await waitUntil { !model.isWorking && model.session.takes.count == 1 }
        XCTAssertTrue(finalized)
        XCTAssertEqual(model.session.phase, .reviewing(takeIndex: 0))
        XCTAssertEqual(reconciliations.read(), 1)
        XCTAssertEqual(starts.read(), 1)
        XCTAssertEqual(stops.read(), 1)
        let retained = model.session
        model.captureRecordingDidStop()
        model.stopRecording()
        let owner = await worker.snapshot()
        XCTAssertEqual(owner.session, retained)
        XCTAssertEqual(stops.read(), 1)
    }

    func testExact95BPMBeatIsPreparedAndRevalidatedBeforeConfigurationAndCaptureStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExactBeatWorker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = LockedBox<[String]>([])
        let configuration = LockedBox<ReferenceAuthoringBridgeTakeConfiguration?>(nil)
        let prepared = LockedBox<ReferencePreparedBeat?>(nil)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                events.update { $0.append("start") }
                guard configuration.read()?.captureIntent?.beatSpec == prepared.read()?.binding,
                      configuration.read()?.preparedBeat == prepared.read(), prepared.read() != nil else {
                    return .failure(.recordingFailed("Capture began without its exact prepared asset."))
                }
                return .success(())
            },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(hooks: hooks,
            pendingConfigurationHandler: { value in
                events.update { $0.append("configuration") }
                configuration.update { $0 = value }
            },
            prepareBeatHandler: { mode, bpm, binding in
                let beat: ReferencePreparedBeat
                if let binding {
                    events.update { $0.append("resolve") }
                    beat = try ReferenceBeatAssetStore.resolve(binding: binding, rootURL: directory)
                } else {
                    events.update { $0.append("prepare") }
                    beat = try ReferenceBeatAssetStore.prepare(mode: mode, bpm: bpm, loopBeats: 4, rootURL: directory)
                }
                prepared.update { $0 = beat }
                return beat
            })
        let worker = makeWorker(session: readySession(), hooks: hooks, driver: driver)
        let configured = await worker.configure(technique: .babyScratch,
            pattern: ReferencePatternIdentity(id: "exact-95", name: "Exact 95", phraseBars: 1), bpm: 95,
            startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .right,
            notes: "Exact asset fixture", beatEngineMode: .clickTrack)
        XCTAssertNil(configured.errorMessage)
        XCTAssertEqual(events.read(), ["prepare"])
        XCTAssertNil(configured.state.session.captureIntent)
        let binding = try XCTUnwrap(configured.state.session.selectedBeatSpec)
        XCTAssertEqual(binding.bpm, 95)
        let beat = try XCTUnwrap(prepared.read())
        XCTAssertTrue(FileManager.default.fileExists(atPath: beat.productionMasterURL.path))
        let started = await worker.startRecording()
        XCTAssertNil(started.errorMessage)
        XCTAssertEqual(events.read(), ["prepare", "resolve", "configuration", "start"])
        let configuredCapture = try XCTUnwrap(configuration.read())
        XCTAssertEqual(configuredCapture.captureIntent?.beatSpec, binding)
        XCTAssertEqual(configuredCapture.preparedBeat, beat)
        let persisted = configuredCapture.recordingSessionConfig(existing: nil, now: Date())
        let reopened = try JSONDecoder().decode(CaptureSessionConfig.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(reopened.referenceCaptureIntent?.beatSpec, binding)
        XCTAssertEqual(reopened.bpm, 95)
        let finalized = await worker.stopRecording()
        XCTAssertNil(finalized.errorMessage)
        XCTAssertEqual(finalized.state.session.latestRecordedTake?.evidence.metadata.captureIntent?.beatSpec, binding)
    }

    func testBeatPreparationFailurePreventsCaptureAndPendingConfiguration() async {
        let starts = LockedBox(0)
        let configurations = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { starts.update { $0 += 1 }; return .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(hooks: hooks,
            pendingConfigurationHandler: { _ in configurations.update { $0 += 1 } },
            prepareBeatHandler: { _, _, _ in throw ReferenceBeatAssetError.invalid("Synthetic preparation failure") })
        let worker = makeWorker(session: readySession(), hooks: hooks, driver: driver)
        let configured = await worker.configure(technique: .babyScratch,
            pattern: ReferencePatternIdentity(id: "failed-95", name: "Failed 95", phraseBars: 1), bpm: 95,
            startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .right, notes: "Retain setup")
        XCTAssertNotNil(configured.errorMessage)
        let start = await worker.startRecording()
        XCTAssertTrue(start.errorMessage?.contains("Synthetic preparation failure") == true)
        XCTAssertNotEqual(start.state.session.phase, .recording)
        XCTAssertNil(start.state.session.captureIntent)
        XCTAssertEqual(start.state.session.notes, "Retain setup")
        XCTAssertEqual(starts.read(), 0)
        XCTAssertEqual(configurations.read(), 0)
    }

    func testAssetChangedAfterSetupIsRejectedBeforeCaptureStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChangedBeatWorker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let starts = LockedBox(0)
        let configurations = LockedBox(0)
        let prepared = LockedBox<ReferencePreparedBeat?>(nil)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { starts.update { $0 += 1 }; return .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(hooks: hooks,
            pendingConfigurationHandler: { _ in configurations.update { $0 += 1 } },
            prepareBeatHandler: { mode, bpm, binding in
                if let binding { return try ReferenceBeatAssetStore.resolve(binding: binding, rootURL: directory) }
                let beat = try ReferenceBeatAssetStore.prepare(mode: mode, bpm: bpm, loopBeats: 4, rootURL: directory)
                prepared.update { $0 = beat }
                return beat
            })
        let worker = makeWorker(session: readySession(), hooks: hooks, driver: driver)
        let configured = await worker.configure(technique: .babyScratch,
            pattern: ReferencePatternIdentity(id: "changed-95", name: "Changed 95", phraseBars: 1), bpm: 95,
            startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .right, notes: "", beatEngineMode: .clickTrack)
        XCTAssertNil(configured.errorMessage)
        let beat = try XCTUnwrap(prepared.read())
        try Data("corrupted after Setup".utf8).write(to: beat.productionMasterURL)
        let start = await worker.startRecording()
        XCTAssertNotNil(start.errorMessage)
        XCTAssertNotEqual(start.state.session.phase, .recording)
        XCTAssertNil(start.state.session.captureIntent)
        XCTAssertEqual(start.state.session.selectedBeatSpec, configured.state.session.selectedBeatSpec)
        XCTAssertEqual(starts.read(), 0)
        XCTAssertEqual(configurations.read(), 0)
    }

    private func makeWorker(
        session: ReferenceAuthoringSession,
        hooks: ReferenceAuthoringRecordingHooks,
        driver: ReferenceAuthoringWorkerDriver? = nil
    ) -> ReferenceAuthoringWorker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceAuthoringViewModelTests-\(UUID().uuidString)")
        return ReferenceAuthoringWorker(
            session: session,
            driver: driver ?? ReferenceAuthoringWorkerDriver(hooks: hooks),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func readySession() -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "synthetic-session", operatorName: "Karl")
        session.selectTechnique(.babyScratch)
        session.selectPattern(
            ReferencePatternIdentity(id: "synthetic-pattern", name: "Synthetic Pattern", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord
        return session
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Synthetic Controller",
            controllerIdentifier: "synthetic-controller",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 0,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Synthetic Audio",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Synthetic Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func goodArtifacts(
        autoDetectedTechnique: ReferenceTechnique? = nil,
        watchEvidence: ReferenceWatchEvidence = .linked(motionFileName: "synthetic-watch-motion.json"),
        suffix: String? = nil,
        recordedAt: Date = Date(timeIntervalSince1970: 1_788_000_500),
        sourceState: ReferencePerTakeSourceState? = nil
    ) -> ReferenceRecordedTakeArtifacts {
        let artifactStem = suffix.map { "synthetic-reference-\($0)" } ?? "synthetic-reference"
        // This successful approval fixture must cover the complete 95 BPM
        // reference plan, not just its first 0.799 seconds.
        let samples = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.02,
                rawValue: 0,
                normalizedPosition: 1
            )
        }
        return ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "\(artifactStem).wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: ReferenceArtifactMeasurement(
                fileName: "\(artifactStem).mov",
                exists: true,
                byteCount: 750_000
            ),
            sidecar: ReferenceArtifactMeasurement(
                fileName: "\(artifactStem).json",
                exists: true,
                byteCount: 2_048
            ),
            actualMediaFileName: "\(artifactStem).mov",
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: 60,
            recordedAt: recordedAt,
            autoDetectedTechnique: autoDetectedTechnique,
            // Linked wrist motion is required evidence for a canonical
            // reference; the missing-Watch case is covered in
            // `ReferenceAuthoringSessionTests`.
            watchEvidence: watchEvidence,
            sourceState: sourceState
        )
    }

    // MARK: - Bounded, cancellable Watch-transfer wait (D1)

    private func pendingWatchHooks(
        refreshCount: LockedBox<Int>,
        landsAfter: Int
    ) -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                .success(self.goodArtifacts(watchEvidence: .acknowledgedTransferPending))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil },
            refreshWatchEvidence: {
                var seen = 0
                refreshCount.update {
                    $0 += 1
                    seen = $0
                }
                return ReferenceWatchEvidenceRefresh(
                    evidence: seen >= landsAfter
                        ? .linked(motionFileName: "synthetic-watch-motion.json")
                        : .acknowledgedTransferPending
                )
            }
        )
    }

    /// A take finalized while the transfer is pending must not be approvable,
    /// and must say why. This is the 2026-09-05 take-003 state.
    func testAPendingWatchTransferBlocksApprovalAndIsExplained() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: .max)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(viewModel.reviewedTake?.evidence.watchEvidence, .acknowledgedTransferPending)
        XCTAssertFalse(viewModel.canApprove)
        XCTAssertNotNil(viewModel.approvalBlockReason)
        viewModel.cancelWatchTransferWait()
    }

    /// The transfer landing AFTER macOS finalization must update the take in
    /// place and make it approvable, without re-recording.
    func testAMatchingTransferLandingAfterFinalizationPreservesMediaApprovalGate() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: 1)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(
            viewModel.reviewedTake?.evidence.watchEvidence.isLinked ?? false,
            "the matching transfer must attach once it lands"
        )
        XCTAssertTrue(
            viewModel.reviewedTake?.evidence.metadata.deviceInfo.watchLinked ?? false
        )
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer, "a terminal state ends the wait")
        // Still needs a repetition selection — approval has more than one gate.
        XCTAssertFalse(viewModel.canApprove)
        viewModel.selectRepetitionForApproval(1)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(viewModel.canApprove)
        XCTAssertEqual(viewModel.approvalBlockReason, "The finalized WAV is missing.")
    }

    /// Leaving the screen abandons the wait and touches nothing else.
    func testViewDisappearanceCancelsTheWatchTransferWait() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: .max)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(viewModel.isWaitingForWatchTransfer)

        viewModel.cancelTransientWorkForViewDisappearance()
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer)
        let afterCancel = refreshCount.read()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(
            refreshCount.read(),
            afterCancel,
            "a cancelled wait must stop polling"
        )
        XCTAssertEqual(
            viewModel.reviewedTake?.evidence.metadata.lifecycleState,
            .draft,
            "cancellation must not approve, publish or install anything"
        )
    }

    /// No hook at all (no finalized take to ask about) must end the wait
    /// immediately rather than spinning.
    func testAWaitWithNoWatchEvidenceSourceEndsImmediately() async throws {
        let worker = makeWorker(
            session: readySession(),
            hooks: ReferenceAuthoringRecordingHooks(
                startRecording: { .success(()) },
                stopRecording: {
                    .success(self.goodArtifacts(watchEvidence: .acknowledgedTransferPending))
                },
                currentPreflightSnapshot: { self.passingSnapshot() },
                latestCalibrationObservation: { nil },
                refreshWatchEvidence: { nil }
            )
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer)
        XCTAssertFalse(viewModel.canApprove)
    }
}

// MARK: - Tear segmentation review

/// Concurrency and presentation tests for the macOS tear-segmentation review
/// surface.
///
/// Two properties are under test here and nothing else: every correction runs
/// on the session's single owner (the serial worker) with no lost updates,
/// and no correction can approve, validate or publish a take.
@MainActor
final class ReferenceTearSegmentationViewModelTests: XCTestCase {

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "synthetic-controller",
            deviceName: "Synthetic Controller",
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

    // MARK: Fixtures

    private func movement(
        _ startTime: Double,
        _ endTime: Double,
        _ direction: String
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime,
            endTime: endTime,
            startPosition: 0,
            endPosition: 1,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: 1,
            confidence: 0.9,
            source: "controller"
        )
    }

    private func twoTearMovementEvents() -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            movement(0.00, 0.20, "backward"),
            movement(0.35, 0.55, "backward"),
            movement(0.75, 0.95, "backward"),
            movement(1.10, 1.40, "forward")
        ]
    }

    private func artifacts(
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]? = nil,
        includeFaderEvidence: Bool = true,
        additionalPlatterIntervals: [CaptureCore.PlatterEvidenceInterval] = []
    ) -> ReferenceRecordedTakeArtifacts {
        let movements = movementEvents ?? twoTearMovementEvents()
        let samples = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 0,
                normalizedPosition: 1
            )
        }
        return ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.mov",
                exists: true,
                byteCount: 750_000
            ),
            sidecar: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.json",
                exists: true,
                byteCount: 2_048
            ),
            actualMediaFileName: "synthetic-reference.mov",
            crossfaderRawSamples: includeFaderEvidence ? samples : [],
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: 4,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: nil,
            watchEvidence: .linked(motionFileName: "synthetic-watch-motion.json"),
            platterMovementEvents: movements,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(movements) + additionalPlatterIntervals
        )
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Synthetic Controller",
            controllerIdentifier: "synthetic-controller",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 0,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Synthetic Audio",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Synthetic Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func readySession() -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "synthetic-session", operatorName: "Karl")
        session.selectTechnique(.babyScratch)
        session.selectPattern(
            ReferencePatternIdentity(id: "synthetic-pattern", name: "Synthetic Pattern", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord
        return session
    }

    private func makeWorker() -> ReferenceAuthoringWorker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceTearReviewTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        return ReferenceAuthoringWorker(
            session: readySession(),
            driver: ReferenceAuthoringWorkerDriver(hooks: hooks),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tear-tests.\(UUID().uuidString)"
        )
    }

    /// A worker already holding one finalized take in review.
    private func reviewingWorker() async -> ReferenceAuthoringWorker {
        let worker = makeWorker()
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        return worker
    }

    private func makeViewModel() async -> ReferenceAuthoringViewModel {
        let worker = await reviewingWorker()
        return ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
    }

    private func tearReview(of worker: ReferenceAuthoringWorker) async -> ReferenceTearSegmentationReview {
        await worker.snapshot().session.takes.last!.tearReview
    }

    #if DEBUG
    private func comparisonViewModel(
        includeFaderEvidence: Bool = true,
        interGestureInterruption: CaptureCore.PlatterEvidenceInterval.Kind? = nil
    ) async -> ReferenceAuthoringViewModel {
        // Preserve the older review-only fixture; comparison additionally needs direction-correct curves.
        let movements = twoTearMovementEvents().enumerated().map { index, event in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: event.startTime, endTime: event.endTime,
                startPosition: index < 3 ? Double(3 - index) / 3 : 0,
                endPosition: index < 3 ? Double(2 - index) / 3 : 1, direction: event.direction,
                movementKind: event.movementKind, speed: event.speed, confidence: event.confidence,
                source: event.source
            )
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TearComparison-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let additionalIntervals = interGestureInterruption.map {
            [CaptureCore.PlatterEvidenceInterval(startTime: 0.95, endTime: 1.10, kind: $0)]
        } ?? []
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts(movementEvents: movements, includeFaderEvidence: includeFaderEvidence,
                                                    additionalPlatterIntervals: additionalIntervals)) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil }
        )
        let worker = ReferenceAuthoringWorker(
            session: readySession(), driver: ReferenceAuthoringWorkerDriver(hooks: hooks),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory)
        )
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        return ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
    }

    private func selectComparison(_ viewModel: ReferenceAuthoringViewModel, holds: Int = 2) {
        viewModel.selectTearComparisonTarget("scratchlab.tear.\(holds).backward.equal.v1")
        viewModel.selectTearComparisonStart(viewModel.tearComparisonCandidates.first?.id)
        viewModel.compareSelectedTear()
    }

    func testTearComparisonRequiresExplicitTargetPerformanceAndAlignment() async throws {
        let viewModel = await comparisonViewModel()
        XCTAssertNil(viewModel.tearComparisonTargetID)
        XCTAssertNil(viewModel.tearComparisonStartID)
        XCTAssertNil(viewModel.tearComparisonResult)
        viewModel.compareSelectedTear()
        XCTAssertNil(viewModel.tearComparisonOriginSeconds)

        viewModel.selectTearComparisonTarget("scratchlab.tear.2.backward.equal.v1")
        XCTAssertNil(viewModel.tearComparisonResult)
        viewModel.selectTearComparisonStart(viewModel.tearComparisonCandidates[0].id)
        XCTAssertNil(viewModel.tearComparisonResult, "Selecting evidence must not silently choose an alignment.")
        viewModel.compareSelectedTear()
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertTrue(viewModel.reviewTearProjection?.records.allSatisfy { $0.motionValidationIssues().isEmpty } == true)
        XCTAssertEqual(result.dimensions.map(\.axis), CanonicalTearComparison.Axis.allCases)
        XCTAssertEqual(result.dimensions.first { $0.axis == .directionOrder }?.assessment, .withinTolerance)
        let projected = try XCTUnwrap(viewModel.reviewTearProjection?.records.first)
        XCTAssertEqual(projected.internalHolds.map(\.evidence.provenance), [.inferred, .inferred])
        let count = try XCTUnwrap(result.dimensions.first { $0.axis == .holdCount })
        XCTAssertEqual(count.assessment, .unavailable, "An inferred hold count is descriptive evidence, not a measured pass.")
        XCTAssertNil(count.scorePercentage)
        XCTAssertTrue(count.unavailableReasons.contains(.inferredHoldEvidence))
        XCTAssertEqual(count.measurements.first { $0.kind == .holdCount }?.observed, 2)
        XCTAssertEqual(result.dimensions.first { $0.axis == .holdTiming }?.assessment, .unavailable)
        XCTAssertEqual(result.dimensions.first { $0.axis == .subdivisionRatios }?.assessment, .unavailable)
        XCTAssertEqual(result.dimensions.first { $0.axis == .faderTiming }?.assessment, .notRequested)
        XCTAssertTrue(result.dimensions.first { $0.axis == .motionShape }?.unavailableReasons.contains(.interpolatedCurve) == true)
        XCTAssertEqual(viewModel.tearComparisonOriginSeconds, 0)
    }

    func testTearComparisonUsesCapturedTempoAndExplicitTargetChanges() async throws {
        let viewModel = await comparisonViewModel()
        selectComparison(viewModel)
        let original = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(viewModel.reviewedTake?.evidence.metadata.bpm, 95)
        XCTAssertEqual(viewModel.tearComparisonBPM, 95)
        viewModel.bpm = 200
        XCTAssertEqual(viewModel.tearComparisonBPM, 95)
        XCTAssertEqual(viewModel.tearComparisonResult, original, "The next-take form must not retime recorded evidence.")

        viewModel.selectTearComparisonTarget("scratchlab.tear.1.forward.equal.v1")
        XCTAssertNil(viewModel.tearComparisonOriginSeconds)
        XCTAssertNil(viewModel.tearComparisonResult)
        viewModel.compareSelectedTear()
        XCTAssertEqual(viewModel.tearComparisonResult?.dimensions.first { $0.axis == .directionOrder }?.assessment, .outsideTolerance)
        XCTAssertEqual(viewModel.tearComparisonResult?.dimensions.first { $0.axis == .holdCount }?.assessment, .unavailable)
        XCTAssertNotEqual(viewModel.tearComparisonResult, original)
        XCTAssertEqual(viewModel.tearComparisonSelectedCandidates.count, 1)
    }

    func testTearComparisonKeepsTheExplicitConsecutiveRangeAndWrongDirections() async throws {
        let viewModel = await comparisonViewModel()
        viewModel.selectTearComparisonTarget("scratchlab.tear.2.forward-backward.equal.v1")
        let candidates = viewModel.tearComparisonCandidates
        viewModel.selectTearComparisonStart(candidates[0].id)
        viewModel.selectTearComparisonEnd(candidates[1].id)
        viewModel.compareSelectedTear()
        XCTAssertEqual(viewModel.tearComparisonSelectedCandidates.map(\.id), candidates.map(\.id))
        XCTAssertTrue(viewModel.tearComparisonResult?.dimensions.first { $0.axis == .directionOrder }?.measurements.contains { $0.isWithinTolerance == false } == true)

        viewModel.selectTearComparisonStart(candidates[1].id)
        XCTAssertNil(viewModel.tearComparisonResult)
        XCTAssertEqual(viewModel.tearComparisonSelectedCandidates.map(\.id), [candidates[1].id])
        viewModel.selectTearComparisonEnd(candidates[0].id)
        XCTAssertTrue(viewModel.tearComparisonSelectedCandidates.isEmpty, "A backwards range must not be silently reordered.")
        viewModel.selectTearComparisonEnd(candidates[1].id)
        viewModel.compareSelectedTear()
        XCTAssertEqual(viewModel.tearComparisonOriginSeconds, 1.10)
    }

    func testTearComparisonCorrectionClearsAlignmentAndRecomputesWithoutApproving() async throws {
        let viewModel = await comparisonViewModel()
        selectComparison(viewModel)
        let before = try XCTUnwrap(viewModel.reviewedTake)
        let candidate = try XCTUnwrap(viewModel.tearComparisonCandidates.first)
        let boundary = candidate.boundaries[1]
        viewModel.setTearBoundaryKind(inCandidate: candidate.id, boundaryID: boundary.id, to: .faderClick)
        let corrected = await waitUntil {
            viewModel.tearReview?.candidate(id: candidate.id)?.boundaries[1].kind == .faderClick
        }
        XCTAssertTrue(corrected)
        XCTAssertNil(viewModel.tearComparisonTargetID)
        XCTAssertNil(viewModel.tearComparisonStartID)
        XCTAssertNil(viewModel.tearComparisonEndID)
        XCTAssertNil(viewModel.tearComparisonResult)
        viewModel.classifyTearCandidate(candidate.id, as: .tear1)
        let classified = await waitUntil { viewModel.tearReview?.candidate(id: candidate.id)?.manualClassification == .tear1 }
        XCTAssertTrue(classified)
        selectComparison(viewModel, holds: 1)
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(result.dimensions.first { $0.axis == .directionOrder }?.assessment, .withinTolerance)
        let count = try XCTUnwrap(result.dimensions.first { $0.axis == .holdCount })
        XCTAssertEqual(count.assessment, .unavailable)
        XCTAssertNil(count.scorePercentage)
        XCTAssertEqual(count.measurements.first { $0.kind == .holdCount }?.observed, 1)
        XCTAssertEqual(viewModel.reviewTearProjection?.records.first?.internalHolds.map(\.evidence.provenance), [.inferred])
        XCTAssertEqual(viewModel.tearReview?.rawMovementEvents, before.tearReview.rawMovementEvents)
        XCTAssertEqual(viewModel.reviewedTake?.evidence, before.evidence)
        XCTAssertEqual(viewModel.reviewedTake?.latestValidation, before.latestValidation)
    }

    func testTearComparisonManualUnknownAndAmbiguousHoldRemainUnavailable() async throws {
        let viewModel = await comparisonViewModel()
        let candidate = try XCTUnwrap(viewModel.tearComparisonCandidates.first)
        viewModel.classifyTearCandidate(candidate.id, as: .unknown)
        let unknown = await waitUntil { viewModel.tearReview?.candidate(id: candidate.id)?.manualClassification == .unknown }
        XCTAssertTrue(unknown)
        selectComparison(viewModel)
        let unknownResult = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(unknownResult.dimensions.first { $0.axis == .holdCount }?.assessment, .unavailable)
        XCTAssertTrue(unknownResult.dimensions.first { $0.axis == .holdCount }?.unavailableReasons.contains(.unknownEvidence) == true)

        viewModel.classifyTearCandidate(candidate.id, as: .tear2)
        let classified = await waitUntil { viewModel.tearReview?.candidate(id: candidate.id)?.manualClassification == .tear2 }
        XCTAssertTrue(classified)
        viewModel.setTearBoundaryEvidenceQuality(inCandidate: candidate.id, boundaryID: candidate.boundaries[0].id, to: .ambiguous)
        let ambiguous = await waitUntil { viewModel.tearReview?.candidate(id: candidate.id)?.hasAmbiguousEvidence == true }
        XCTAssertTrue(ambiguous)
        selectComparison(viewModel)
        XCTAssertTrue(viewModel.tearComparisonResult?.dimensions.first { $0.axis == .holdTiming }?.unavailableReasons.contains(.ambiguousEvidence) == true)
    }

    func testTearComparisonMovedBoundaryDoesNotClaimMeasuredTiming() async throws {
        let viewModel = await comparisonViewModel()
        let candidate = try XCTUnwrap(viewModel.tearComparisonCandidates.first)
        let boundary = candidate.boundaries[0]
        viewModel.moveTearBoundary(inCandidate: candidate.id, boundaryID: boundary.id, startTime: 0.22, endTime: 0.34)
        let moved = await waitUntil { viewModel.tearReview?.candidate(id: candidate.id)?.boundaries[0].span.startTime == 0.22 }
        XCTAssertTrue(moved)
        selectComparison(viewModel)
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(result.dimensions.first { $0.axis == .directionOrder }?.assessment, .withinTolerance)
        XCTAssertEqual(result.dimensions.first { $0.axis == .holdCount }?.assessment, .unavailable)
        XCTAssertTrue(viewModel.reviewTearProjection?.records.first?.internalHolds.allSatisfy { $0.evidence.provenance == .inferred } == true)
        XCTAssertTrue(result.dimensions.first { $0.axis == .holdTiming }?.unavailableReasons.contains(.correctedTiming) == true)
        XCTAssertEqual(result.dimensions.first { $0.axis == .holdTiming }?.assessment, .unavailable)
    }

    func testTearComparisonMissingFaderDoesNotInventEvidenceOrRequestPlainTearClicks() async throws {
        let viewModel = await comparisonViewModel(includeFaderEvidence: false)
        selectComparison(viewModel)
        let result = try XCTUnwrap(viewModel.tearComparisonResult)
        XCTAssertEqual(result.dimensions.first { $0.axis == .faderTiming }?.assessment, .notRequested)
        XCTAssertTrue(result.dimensions.first { $0.axis == .evidenceQuality }?.unavailableReasons.contains(.missingFaderEvidence) == true)
        XCTAssertNotEqual(result.dimensions.first { $0.axis == .evidenceQuality }?.assessment, .withinTolerance)
    }

    func testTearComparisonRetainsPacketAndClockGapsBetweenSelectedGestures() async throws {
        for interruption in [CaptureCore.PlatterEvidenceInterval.Kind.packetGap, .clockDiscontinuity] {
            let viewModel = await comparisonViewModel(interGestureInterruption: interruption)
            viewModel.selectTearComparisonTarget("scratchlab.tear.2.forward-backward.equal.v1")
            let candidates = viewModel.tearComparisonCandidates
            XCTAssertEqual(candidates.count, 2)
            viewModel.selectTearComparisonStart(candidates[0].id)
            viewModel.selectTearComparisonEnd(candidates[1].id)
            viewModel.compareSelectedTear()
            let result = try XCTUnwrap(viewModel.tearComparisonResult)
            XCTAssertTrue(result.dimensions.first { $0.axis == .evidenceQuality }?.unavailableReasons.contains(.unknownEvidence) == true)
            XCTAssertTrue(result.dimensions.first { $0.axis == .directionOrder }?.unavailableReasons.contains(.unknownEvidence) == true)
            XCTAssertTrue(viewModel.tearReview?.platterEvidenceIntervals.contains { $0.kind == interruption } == true)
        }
    }

    func testTearComparisonTakeReplacementCannotReuseOldTargetRangeOrResult() async throws {
        let viewModel = await comparisonViewModel()
        selectComparison(viewModel)
        let previousID = try XCTUnwrap(viewModel.reviewedTake?.id)
        XCTAssertNotNil(viewModel.tearComparisonResult)
        viewModel.retake()
        let ready = await waitUntil { viewModel.session.phase == .readyToRecord && !viewModel.isWorking }
        XCTAssertTrue(ready)
        XCTAssertNil(viewModel.tearComparisonResult)
        viewModel.startRecording()
        let recording = await waitUntil {
            if case .recording = viewModel.session.phase { return !viewModel.isWorking }
            return false
        }
        XCTAssertTrue(recording)
        viewModel.stopRecording()
        let replaced = await waitUntil { viewModel.reviewedTake?.id != previousID && !viewModel.isWorking }
        XCTAssertTrue(replaced)
        XCTAssertNil(viewModel.tearComparisonTargetID)
        XCTAssertNil(viewModel.tearComparisonStartID)
        XCTAssertNil(viewModel.tearComparisonEndID)
        XCTAssertNil(viewModel.tearComparisonOriginSeconds)
        XCTAssertNil(viewModel.tearComparisonResult)
    }
    #endif

    // MARK: Advisory auto-detection

    private func take(
        technique: ReferenceTechnique,
        autoDetected: ReferenceTechnique?
    ) -> ReferenceAuthoringTake {
        let metadata = ReferenceTakeMetadata(
            referenceTakeID: "ref-take-advisory",
            authoringSessionID: "synthetic-session",
            takeNumber: 1,
            operatorName: "Karl",
            technique: technique,
            pattern: ReferencePatternIdentity(
                id: "synthetic-pattern",
                name: "Synthetic Pattern",
                phraseBars: 1
            ),
            bpm: 95,
            startingPlatterDirection: .forward,
            faderVariant: technique == .babyScratch ? .faderOpenThroughout : .crossfader,
            referenceVersion: 1,
            crossfaderCalibration: calibration,
            deviceInfo: ReferenceDeviceInfo(
                platform: "macOS",
                appVersion: "1.0.1",
                controllerName: "Synthetic Controller",
                controllerIdentifier: "synthetic-controller",
                audioDeviceName: "Synthetic Audio",
                videoDeviceName: "Synthetic Camera",
                watchLinked: true
            ),
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500)
        )
        let evidence = ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: ReferencePhraseBoundaries.nominal(for: metadata),
            audio: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.mov",
                exists: true,
                byteCount: 750_000
            ),
            sidecar: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.json",
                exists: true,
                byteCount: 2_048
            ),
            actualMediaFileName: "synthetic-reference.mov",
            crossfaderRawSamples: [],
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: twoTearMovementEvents().count,
            derivation: nil,
            watchEvidence: .linked(motionFileName: "synthetic-watch-motion.json"),
            platterMovementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents())
        )
        return ReferenceAuthoringTake(
            evidence: evidence,
            autoDetectedTechnique: autoDetected,
            latestValidation: ReferenceValidator.validate(evidence)
        )
    }

    /// The audio detector can only ever emit Baby Scratch, so on a
    /// Tear-selected take its result is a LIMIT, not a contradiction. Showing
    /// it as a mismatch reads as the operator being corrected by a detector
    /// that has no Tear vocabulary at all.
    func testAdvisoryBabyDetectionOnATearTakeIsLabelledLimitedAndIsNotADisagreement() {
        let tearTake = take(technique: .tear, autoDetected: .babyScratch)
        let statement = ReferenceAuthoringViewModel.advisoryDetectionStatement(for: tearTake)

        XCTAssertFalse(statement.isDisagreement)
        XCTAssertTrue(statement.isOutsideDetectorVocabulary)
        XCTAssertTrue(statement.text.contains("Advisory"))
        XCTAssertTrue(statement.text.contains("LIMITED"))
        XCTAssertTrue(statement.text.contains("Baby Scratch"))
        XCTAssertTrue(statement.text.contains("Tear"))
        XCTAssertTrue(statement.text.lowercased().contains("never overwrites"))

        // The operator's selection is untouched by the advisory result.
        XCTAssertEqual(tearTake.evidence.metadata.technique, .tear)
        XCTAssertEqual(tearTake.autoDetectedTechnique, .babyScratch)
        XCTAssertFalse(
            ReferenceAuthoringCaptureBridge.advisoryDetectorCanExpress(.tear),
            "The shipped detector has no Tear vocabulary."
        )
    }

    /// Inside the detector's actual vocabulary, a mismatch is still reported
    /// as a real disagreement — the limit label must not blanket-excuse it.
    func testAdvisoryDetectionStaysADisagreementInsideTheDetectorVocabulary() {
        let agreeing = ReferenceAuthoringViewModel.advisoryDetectionStatement(
            for: take(technique: .babyScratch, autoDetected: .babyScratch)
        )
        XCTAssertFalse(agreeing.isDisagreement)
        XCTAssertFalse(agreeing.isOutsideDetectorVocabulary)
        XCTAssertTrue(agreeing.text.contains("agrees"))

        let noResult = ReferenceAuthoringViewModel.advisoryDetectionStatement(
            for: take(technique: .babyScratch, autoDetected: nil)
        )
        XCTAssertFalse(noResult.isDisagreement)
        XCTAssertTrue(noResult.text.contains("no result"))
    }

    // MARK: Scalable review presentation

    /// 52 alternating-direction gestures, each its own candidate.
    private func fiftyTwoGestureReview() -> ReferenceTearSegmentationReview {
        var events: [CaptureCore.DetectedNotationRecordMovementEvent] = []
        var time = 0.0
        for index in 0..<52 {
            let forward = index.isMultiple(of: 2)
            events.append(
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: time,
                    endTime: time + 0.40,
                    startPosition: forward ? 0 : 0.15,
                    endPosition: forward ? 0.15 : 0,
                    direction: forward ? "forward" : "backward",
                    movementKind: forward ? .normalPush : .normalPull,
                    speed: 0.15 / 0.40,
                    confidence: 0.9,
                    source: "controller"
                )
            )
            time += 0.50
        }
        return ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-52",
            movementEvents: events,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(events),
            derivation: nil,
            coordinates: .normalizedTakeLocal()
        )
    }

    /// A 52-gesture take must be readable without 52 open cards — by GROUPING
    /// and lazy disclosure only. No gesture record may be dropped, merged, or
    /// collapsed into a single confident label, and the raw evidence stays.
    func testAFiftyTwoGestureReviewIsGroupedWithoutLosingAnyGestureRecord() throws {
        let review = fiftyTwoGestureReview()
        XCTAssertEqual(review.candidates.count, 52)
        XCTAssertEqual(review.rawMovementEvents.count, 52, "Raw evidence is retained verbatim.")

        let groups = ReferenceAuthoringViewModel.tearCandidateGroups(review)
        let grouped = groups.flatMap(\.candidateIDs)

        // A strict partition: every candidate filed exactly once, none lost.
        XCTAssertEqual(grouped.count, review.candidates.count)
        XCTAssertEqual(Set(grouped), Set(review.candidates.map(\.id)))
        XCTAssertEqual(Set(grouped).count, grouped.count, "No candidate may be filed twice.")
        XCTAssertEqual(groups.map(\.count).reduce(0, +), 52)
        XCTAssertTrue(groups.allSatisfy { $0.count > 0 }, "No empty group is rendered.")

        // Grouping asserts nothing about a gesture: the readings are unchanged.
        XCTAssertEqual(
            review.candidates.map(\.effectiveClassification),
            review.candidates.map(\.effectiveClassification)
        )

        // Lazy disclosure, not truncation: the default view opens only the
        // groups that need a decision, and each group still lists everything
        // it holds once opened.
        let expanded = ReferenceAuthoringViewModel.defaultExpandedTearGroupIDs(review)
        XCTAssertLessThan(expanded.count, groups.count + 1)
        let expandedCandidateCount = groups
            .filter { expanded.contains($0.id) }
            .map(\.count)
            .reduce(0, +)
        XCTAssertLessThan(
            expandedCandidateCount,
            52,
            "A fresh 52-gesture review must not open every gesture card at once."
        )
        for group in groups {
            XCTAssertEqual(
                group.candidateIDs.compactMap { review.candidate(id: $0) }.count,
                group.count,
                "Every grouped ID must still resolve to its retained candidate."
            )
        }
    }

    /// A group is a bucket of IDs, never a verdict. An unknown reading must
    /// not be filed as, or displayed as, a confident one.
    func testGroupingNeverTurnsAnUnknownReadingIntoAConfidentLabel() {
        let review = fiftyTwoGestureReview()
        let groups = ReferenceAuthoringViewModel.tearCandidateGroups(review)
        for group in groups {
            for id in group.candidateIDs {
                guard let candidate = review.candidate(id: id) else {
                    return XCTFail("Candidate \(id) was dropped by grouping.")
                }
                if candidate.effectiveClassification == .unknown
                    && !candidate.classificationDisagreesWithBoundaryCount
                    && !candidate.hasAmbiguousEvidence {
                    XCTAssertEqual(
                        group.kind,
                        .unknownReading,
                        "An unknown gesture must stay filed as unknown."
                    )
                }
            }
            XCTAssertFalse(
                group.headline.contains("tear1") || group.headline.contains("tear2"),
                "A group headline must not assert a technique reading."
            )
        }
    }

    /// The review must say which unit its platter numbers are in.
    func testTheReviewStatesItsPlatterCoordinateContract() {
        let normalized = fiftyTwoGestureReview()
        let text = ReferenceAuthoringViewModel.tearCoordinateContractText(normalized)
        XCTAssertTrue(text.contains("not calibrated revolutions"))
        XCTAssertFalse(text.contains("positions are platter revolutions"))
    }

    // MARK: Concurrency

    /// The worker is the session's single owner. Twenty corrections issued
    /// concurrently must all land, in some order, with none lost.
    func testConcurrentTearCorrectionsAreSerialisedWithNoLostUpdates() async {
        let worker = await reviewingWorker()
        let review = await tearReview(of: worker)
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = await worker.setTearBoundaryKind(
                        candidateID: candidateID,
                        boundaryID: boundaryID,
                        kind: index.isMultiple(of: 2) ? .faderClick : .hold,
                        notes: "correction-\(index)"
                    )
                }
            }
        }

        let corrected = await tearReview(of: worker)
        let boundary = corrected.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(
            boundary.corrections.count, 20,
            "a serialised owner must lose no correction under concurrent writes"
        )
        XCTAssertEqual(
            corrected.candidate(id: candidateID)!.boundaries.count, 2,
            "concurrent corrections must not duplicate or drop a boundary"
        )
        XCTAssertEqual(
            corrected.rawMovementEvents.count, 4,
            "no correction path may touch the take's raw motion evidence"
        )
    }

    /// Corrections of different kinds, interleaved, must all be recorded
    /// against the correct candidate.
    func testInterleavedCorrectionsOfDifferentKindsAllLand() async {
        let worker = await reviewingWorker()
        let review = await tearReview(of: worker)
        let tearID = review.candidates[0].id
        let plainID = review.candidates[1].id
        let boundaryID = review.candidates[0].boundaries[1].id

        async let classify = worker.classifyTearCandidate(tearID, as: .tear1, notes: "one hold")
        async let quality = worker.setTearBoundaryEvidenceQuality(
            candidateID: tearID,
            boundaryID: boundaryID,
            quality: .ambiguous,
            notes: "unclear"
        )
        async let removal = worker.setTearBoundaryRemoved(
            candidateID: tearID,
            boundaryID: boundaryID,
            removed: true,
            notes: "not a hold"
        )
        async let added = worker.addTearBoundary(
            candidateID: plainID,
            startTime: 1.20,
            endTime: 1.25,
            kind: .hold,
            evidenceQuality: .clear,
            notes: "missed pause"
        )
        _ = await (classify, quality, removal, added)

        let corrected = await tearReview(of: worker)
        let tear = corrected.candidate(id: tearID)!
        XCTAssertEqual(tear.manualClassification, .tear1)
        XCTAssertEqual(tear.countedTearHoldCount, 1)
        XCTAssertEqual(tear.boundaries.count, 2, "a struck-out boundary is retained")
        XCTAssertEqual(corrected.candidate(id: plainID)!.boundaries.count, 1)
        XCTAssertEqual(corrected.candidate(id: plainID)!.boundaries[0].origin, .operatorAdded)
    }

    // MARK: View-model state

    func testTheViewModelPublishesTheTearReviewBuiltForTheTakeOnScreen() async {
        let viewModel = await makeViewModel()
        let review = viewModel.tearReview

        XCTAssertEqual(review?.candidates.count, 2)
        XCTAssertEqual(review?.candidates.first?.proposedClassification, .tear2)
        XCTAssertEqual(review?.rawMovementEvents.count, 4)
        XCTAssertTrue(viewModel.canCorrectTearReview)
        XCTAssertNil(viewModel.tearReviewBlockReason)
    }

    func testAViewModelCorrectionIsPublishedAndApprovesNothing() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id
        let lifecycleBefore = viewModel.reviewedTake!.evidence.metadata.lifecycleState
        let approvalBefore = viewModel.approvalBlockReason

        viewModel.tearReviewNotes = "second pause is fader work"
        viewModel.classifyTearCandidate(candidateID, as: .tear1)
        let landed = await waitUntil {
            viewModel.tearReview?.candidate(id: candidateID)?.manualClassification == .tear1
        }

        XCTAssertTrue(landed, "the correction must reach published state")
        let candidate = viewModel.tearReview!.candidate(id: candidateID)!
        XCTAssertEqual(candidate.proposedClassification, .tear2, "the proposal is retained")
        XCTAssertEqual(candidate.latestClassificationCorrection?.correctedBy, "Karl")
        XCTAssertEqual(candidate.latestClassificationCorrection?.notes, "second pause is fader work")
        XCTAssertEqual(viewModel.reviewedTake?.evidence.metadata.lifecycleState, lifecycleBefore)
        XCTAssertNil(viewModel.reviewedTake?.evidence.metadata.reviewDecision)
        XCTAssertEqual(
            viewModel.approvalBlockReason, approvalBefore,
            "a tear correction must not move the approval gate in either direction"
        )
    }

    func testACorrectionIsRefusedAndExplainedOnceTheTakeLeavesReview() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id

        viewModel.retake()
        let leftReview = await waitUntil { viewModel.session.phase == .readyToRecord }
        XCTAssertTrue(leftReview)

        XCTAssertFalse(viewModel.canCorrectTearReview)
        viewModel.classifyTearCandidate(candidateID, as: .tear3)
        XCTAssertNotNil(viewModel.tearReviewBlockReason)
        XCTAssertEqual(viewModel.visibleMessage, viewModel.tearReviewBlockReason)
        XCTAssertNil(
            viewModel.reviewedTake?.tearReview.candidate(id: candidateID)?.manualClassification,
            "a refused correction changes nothing on the retained take"
        )
    }

    func testAnUnknownBoundaryIsReportedRatherThanSilentlyDropped() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id

        viewModel.setTearBoundaryKind(inCandidate: candidateID, boundaryID: "no-such-boundary", to: .faderClick)
        let reported = await waitUntil {
            viewModel.visibleMessage == ReferenceAuthoringWorker.tearCorrectionRefused
        }
        XCTAssertTrue(reported, "a correction that matched nothing must say so")
    }

    // MARK: Presentation

    func testTearReviewStatusTextAlwaysStatesThatTheReviewApprovesNothing() {
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let text = ReferenceAuthoringViewModel.tearReviewStatusText(review)
        XCTAssertTrue(text.contains("2 gestures"), text)
        XCTAssertTrue(text.contains("2 counted platter holds"), text)
        XCTAssertTrue(text.contains("approves nothing"), text)

        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearReviewStatusText(nil),
            "No take is under review."
        )
        let empty = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-002",
            movementEvents: [],
            derivation: nil
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearReviewStatusText(empty),
            "No platter motion was recorded for this take, so there is nothing to segment."
        )
    }

    func testTearCandidateHeadlineShowsBothTheProposalAndTheOperatorReading() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCandidateHeadline(review.candidates[0]),
            "Gesture 1 · backward · proposed 2-tear (confidence 0.90)"
        )

        review.classifyCandidate(
            id: candidateID,
            as: .tear1,
            correction: ReferenceTearCorrection(
                correctedBy: "Karl",
                correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
                notes: "",
                reason: "test"
            )
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCandidateHeadline(review.candidate(id: candidateID)!),
            "Gesture 1 · backward · proposed 2-tear (confidence 0.90) · operator 1-tear"
        )
    }

    func testTearBoundaryHeadlineDistinguishesHoldClickAmbiguityAndStrikeOut() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id
        let correction = ReferenceTearCorrection(
            correctedBy: "Karl",
            correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
            notes: "",
            reason: "test"
        )

        let proposed = ReferenceAuthoringViewModel.tearBoundaryHeadline(review.candidates[0].boundaries[0])
        XCTAssertTrue(proposed.contains("0.200–0.350 s"), proposed)
        XCTAssertTrue(proposed.contains("Platter hold"), proposed)
        XCTAssertTrue(proposed.contains("Proposed automatically"), proposed)

        review.setBoundaryKind(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            to: .faderClick,
            correction: correction
        )
        let click = ReferenceAuthoringViewModel.tearBoundaryHeadline(
            review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        )
        XCTAssertTrue(click.contains("Fader click"), click)
        XCTAssertTrue(click.contains("not counted"), click)

        review.setBoundaryRemoved(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            removed: true,
            correction: correction
        )
        let removed = ReferenceAuthoringViewModel.tearBoundaryHeadline(
            review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        )
        XCTAssertTrue(removed.contains("struck out (retained)"), removed)
    }

    func testTearCorrectionSummaryNamesTheOperatorAndAnUnambiguousInstant() {
        let correction = ReferenceTearCorrection(
            correctedBy: "Karl",
            correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
            notes: "second pause is fader work",
            reason: "test"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCorrectionSummary(correction),
            "Corrected by Karl at 2026-08-29T10:56:40Z — second pause is fader work"
        )
    }

    func testTearDisagreementTextAppearsOnlyWhenTheTwoAssertionsDisagree() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        XCTAssertNil(ReferenceAuthoringViewModel.tearDisagreementText(review.candidates[0]))

        review.classifyCandidate(
            id: candidateID,
            as: .tear1,
            correction: ReferenceTearCorrection(
                correctedBy: "Karl",
                correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
                notes: "",
                reason: "test"
            )
        )
        let text = ReferenceAuthoringViewModel.tearDisagreementText(review.candidate(id: candidateID)!)
        XCTAssertEqual(text, "1-tear does not match the 2 counted platter holds (2-tear).")
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

// MARK: - Calibration reuse and raw export wiring

/// The view-model wiring for the 2026-09-06 slice: adopting an already-stored
/// crossfader calibration instead of re-sweeping it, and offering the RAW
/// diagnostic export independently of canonical approval.
///
/// Synthetic throughout. Nothing is approved, published, installed or made
/// training eligible by any test here.
@MainActor
final class ReferenceAuthoringCalibrationReuseAndExportTests: XCTestCase {

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        ),
        fullLeftRawValue: 0,
        centerRawValue: 63,
        fullRightRawValue: 127,
        openEnd: .right,
        activeDeck: .rightDeck,
        calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 127,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func artifacts() -> ReferenceRecordedTakeArtifacts {
        ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: nil,
            sidecar: ReferenceArtifactMeasurement(fileName: "take.json", exists: true, byteCount: 2_048),
            actualMediaFileName: nil,
            crossfaderRawSamples: [],
            observedCrossfaderAddress: nil,
            platterMovementEventCount: 55,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: .babyScratch,
            watchEvidence: .linked(motionFileName: "watch-motion.json")
        )
    }

    private func hooks() -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
    }

    private func makeViewModel(
        store: CrossfaderCalibrationStore,
        finalizedURL: URL? = nil
    ) -> ReferenceAuthoringViewModel {
        var session = ReferenceAuthoringSession(authoringSessionID: "auth-tear", operatorName: "Karl")
        session.selectTechnique(.tear)
        session.selectPattern(
            ReferencePatternIdentity(id: "tear_1bar", name: "Tear · 1 bar", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        let worker = ReferenceAuthoringWorker(
            session: session,
            driver: ReferenceAuthoringWorkerDriver(
                hooks: hooks(),
                lastFinalizedRecordingURLProvider: { finalizedURL }
            ),
            calibrationStore: store,
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: ReferenceAuthoringViewState(session: session, latestCalibrationRawValue: nil)
        )
        viewModel.selectedTechnique = .tear
        viewModel.crossfaderOpenEndRawValue = CrossfaderOpenEnd.right.rawValue
        viewModel.activeDeckRawValue = CrossfaderActiveDeck.rightDeck.rawValue
        return viewModel
    }

    private func makeStore() throws -> CrossfaderCalibrationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefAuthReuseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CrossfaderCalibrationStore(directoryURL: directory)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func testAnExactStoredCalibrationIsAdoptedWithoutStartingASweep() async throws {
        let store = try makeStore()
        try store.save(calibration)
        let viewModel = makeViewModel(store: store)

        viewModel.adoptPersistedCalibrationIfAvailable(announce: true)
        let adopted = await waitUntil { viewModel.session.confirmedCalibration != nil }
        XCTAssertTrue(adopted, "An exact stored calibration must be reused automatically.")
        XCTAssertEqual(viewModel.session.confirmedCalibration, calibration)
        XCTAssertTrue(viewModel.isReusingPersistedCalibration)
        XCTAssertNil(viewModel.session.calibrationSweep, "Reuse must never start a sweep.")
        XCTAssertEqual(viewModel.session.phase, .readyToRecord)
        XCTAssertNotNil(viewModel.calibrationSourceSummary)
    }

    func testAStoredCalibrationForADifferentOpenEndIsNeverAdopted() async throws {
        let store = try makeStore()
        try store.save(calibration)
        let viewModel = makeViewModel(store: store)
        viewModel.crossfaderOpenEndRawValue = CrossfaderOpenEnd.left.rawValue

        viewModel.adoptPersistedCalibrationIfAvailable(announce: true)
        _ = await waitUntil { viewModel.visibleMessage != nil }
        XCTAssertNil(
            viewModel.session.confirmedCalibration,
            "A calibration measured for the other open end describes a different rig."
        )
        XCTAssertFalse(viewModel.isReusingPersistedCalibration)
    }

    func testRawExportIsBlockedBeforeATakeAndAvailableAfterFinalization() async throws {
        let store = try makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-008_take-008_routine.mov")
        let viewModel = makeViewModel(store: store, finalizedURL: url)

        XCTAssertNotNil(viewModel.rawCaptureExportBlockReason)
        XCTAssertFalse(viewModel.canExportRawCapture)

        viewModel.startRecording()
        _ = await waitUntil { viewModel.session.phase == .recording }
        viewModel.stopRecording()
        let reviewed = await waitUntil { viewModel.reviewedTake != nil && !viewModel.isWorking }
        XCTAssertTrue(reviewed)

        // No calibration, no selected repetition, failing validation — and the
        // RAW capture is still exportable.
        XCTAssertNil(viewModel.session.confirmedCalibration)
        XCTAssertNil(viewModel.reviewedTake?.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertNotNil(viewModel.approvalBlockReason)
        XCTAssertNil(viewModel.rawCaptureExportBlockReason)
        XCTAssertTrue(viewModel.canExportRawCapture)
        let source = await viewModel.rawCaptureExportSource(config: nil)
        XCTAssertNotNil(source)
        XCTAssertEqual(viewModel.lastFinalizedRecordingURL, url)
    }

    func testAdvisoryDetectionNeverOverwritesTheSelectedTearInTheViewModel() async throws {
        let store = try makeStore()
        let viewModel = makeViewModel(store: store)
        viewModel.startRecording()
        _ = await waitUntil { viewModel.session.phase == .recording }
        viewModel.stopRecording()
        _ = await waitUntil { viewModel.reviewedTake != nil }

        XCTAssertEqual(viewModel.session.selectedTechnique, .tear)
        XCTAssertEqual(viewModel.reviewedTake?.evidence.metadata.technique, .tear)
        XCTAssertEqual(viewModel.reviewedTake?.autoDetectedTechnique, .babyScratch)
    }

    func testTheRawExportDisclaimerStatesThatExportIsNotApproval() {
        let text = ReferenceAuthoringViewModel.rawCaptureExportDisclaimer.lowercased()
        XCTAssertTrue(text.contains("does not approve"))
        XCTAssertTrue(text.contains("publish"))
        XCTAssertTrue(text.contains("install"))
        XCTAssertTrue(text.contains("training"))
    }
}


@MainActor
final class ReferenceMotionReviewViewportTests: XCTestCase {
    private func metadata(offset: Double = 4) -> ReferenceTakeMetadata {
        ReferenceTakeMetadata(referenceTakeID: "motion-review", authoringSessionID: "review", takeNumber: 1,
            operatorName: "Fixture", technique: .tear,
            pattern: .init(id: "slow-tear", name: "Slow tear", phraseBars: 1), bpm: 60,
            startingPlatterDirection: .forward, faderVariant: .faderOpenThroughout,
            mediaTimeOrigin: .init(clickStartHostTime: 100, recordingStartHostTime: 200,
                recordingStartOffsetSeconds: offset), referenceVersion: 1, crossfaderCalibration: nil,
            deviceInfo: .init(platform: "fixture", appVersion: "1", controllerName: "fixture",
                controllerIdentifier: "fixture", audioDeviceName: nil, videoDeviceName: nil, watchLinked: false),
            recordedAt: Date(timeIntervalSince1970: 0))
    }

    func testFirstRepetitionMatchesMediaOriginInsteadOfIncludingCountIn() {
        let boundary = ReferenceRepetitionBoundary(index: 0, startBeat: 4, endBeat: 8)
        XCTAssertEqual(ReferenceMotionReviewViewport.range(for: boundary, metadata: metadata(), recordedEnd: 20), 0...4)
        let later = ReferenceRepetitionBoundary(index: 2, startBeat: 12, endBeat: 16)
        XCTAssertEqual(ReferenceMotionReviewViewport.range(for: later, metadata: metadata(), recordedEnd: 20), 8...12)
    }

    func testEarlyStopClipsSelectionAndRejectsUnrecordedRepetitions() {
        XCTAssertEqual(ReferenceMotionReviewViewport.range(for: .init(index: 0, startBeat: 4, endBeat: 8),
            metadata: metadata(), recordedEnd: 2.5), 0...2.5)
        XCTAssertNil(ReferenceMotionReviewViewport.range(for: .init(index: 1, startBeat: 8, endBeat: 12),
            metadata: metadata(), recordedEnd: 2.5))
        XCTAssertNil(ReferenceMotionReviewViewport.range(for: .init(index: 0, startBeat: 4, endBeat: 8),
            metadata: metadata(offset: .nan), recordedEnd: 20))
    }

    func testZoomPreservesWholeTakeDisplacementCoordinates() throws {
        let full = try XCTUnwrap(ScratchStrokeGeometry.CanonicalFrame(timeRange: 0...20,
            positionRange: -3...7, coordinateSpace: .normalizedTakeLocalDisplacement, beatsPerMinute: 60))
        let zoom = ReferenceMotionReviewViewport.frame(full, selectedRange: 8...12, zoomed: true)
        XCTAssertEqual(zoom.timeRange, 8...12)
        XCTAssertEqual(zoom.positionRange, full.positionRange)
        XCTAssertEqual(zoom.coordinateSpace, full.coordinateSpace)
        XCTAssertEqual(zoom.beatsPerMinute, full.beatsPerMinute)
        XCTAssertEqual(ReferenceMotionReviewViewport.frame(full, selectedRange: 8...12, zoomed: false), full)
        XCTAssertEqual(ReferenceMotionReviewViewport.frame(full, selectedRange: nil, zoomed: true), full)
    }

    func testHighlightUsesDisplayedTimeWindowAndClipsItsEdges() {
        XCTAssertEqual(ReferenceMotionReviewViewport.visibleFractions(8...12, in: 0...20), 0.4...0.6)
        XCTAssertEqual(ReferenceMotionReviewViewport.visibleFractions(8...12, in: 8...12), 0...1)
        XCTAssertEqual(ReferenceMotionReviewViewport.visibleFractions(0...4, in: 2...10), 0...0.25)
        XCTAssertNil(ReferenceMotionReviewViewport.visibleFractions(0...4, in: 8...12))
    }
}
