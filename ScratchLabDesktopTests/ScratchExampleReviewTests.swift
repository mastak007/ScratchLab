import XCTest
import AVFoundation
@testable import ScratchLab

final class ScratchExampleReviewTests: XCTestCase {
    func testVerifiedCopyPreservesOriginalFilenameAndExactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original take.wav")
        let copy = directory.appendingPathComponent("review-copy.wav")
        try Data("abc".utf8).write(to: source)
        let receipt = try ScratchExampleMediaImporter.copyVerifiedSynchronously(source: source, destination: copy)
        XCTAssertEqual(receipt.originalFilename, "original take.wav")
        XCTAssertEqual(receipt.originalSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(receipt.originalSHA256, receipt.copiedSHA256)
        XCTAssertEqual(receipt.byteCount, 3)
        XCTAssertEqual(receipt.reviewURL, copy)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
    }

    func testSourceMutationRejectsAndRemovesPreparedCopy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changing.wav")
        let copy = directory.appendingPathComponent("review.wav")
        try Data("abc".utf8).write(to: source)
        XCTAssertThrowsError(try ScratchExampleMediaImporter.copyVerifiedSynchronously(source: source, destination: copy) {
            // Same byte count: size-only comparison must not pass.
            try Data("xyz".utf8).write(to: source, options: .atomic)
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("source changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("xyz".utf8), "The importer never rolls back the source")
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let copy = directory.appendingPathComponent("already-exists.wav")
        try Data("source".utf8).write(to: source)
        try Data("keep".utf8).write(to: copy)
        XCTAssertThrowsError(try ScratchExampleMediaImporter.copyVerifiedSynchronously(source: source, destination: copy))
        XCTAssertEqual(try Data(contentsOf: copy), Data("keep".utf8))
    }

    func testCancelledImportLeavesNoCopy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let copy = directory.appendingPathComponent("copy.wav")
        try Data("source".utf8).write(to: source)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScratchExampleMediaImporter.copyVerifiedSynchronously(source: source, destination: copy)
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testCleanupWaitsForBothMediaReadersAndWriters() async throws {
        let directory = try temporaryDirectory()
        let writerGate = ReviewWorkGate(), readerGate = ReviewWorkGate()
        let writerStarted = expectation(description: "writer is pending")
        let readerStarted = expectation(description: "reader is pending")
        let cleanupStarted = expectation(description: "cleanup task is scheduled")
        let readerFinished = directory.appendingPathComponent("reader-finished")
        let writerFinished = directory.appendingPathComponent("writer-finished")
        let writer = Task<Void, Never> {
            writerStarted.fulfill()
            await writerGate.wait()
            do { try Data("written".utf8).write(to: writerFinished) }
            catch { XCTFail("Directory removed while writer was pending: \(error)") }
        }
        let reader = Task<Void, Never> {
            readerStarted.fulfill()
            await readerGate.wait()
            XCTAssertTrue(FileManager.default.fileExists(atPath: writerFinished.path))
            do { try Data("read".utf8).write(to: readerFinished) }
            catch { XCTFail("Directory removed while reader was pending: \(error)") }
        }
        await fulfillment(of: [writerStarted, readerStarted], timeout: 2)
        let cleanup = Task {
            cleanupStarted.fulfill()
            try await ScratchExampleMediaImporter.removeDirectory(directory, after: [writer, reader])
        }
        await fulfillment(of: [cleanupStarted], timeout: 2)
        await writerGate.open()
        await writer.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await readerGate.open()
        try await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAudioFileCannotReplaceVideoAndCorruptMediaCannotBecomePlayable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("audio.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData?[0][index] = 0 }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let details = try await ScratchExampleMediaImporter.validateMedia(at: audio, video: false)
        XCTAssertTrue(details.hasAudio)
        XCTAssertGreaterThan(details.duration, 0)
        do {
            _ = try await ScratchExampleMediaImporter.validateMedia(at: audio, video: true)
            XCTFail("Audio-only file must not become the take video")
        } catch {}
        let corrupt = directory.appendingPathComponent("corrupt.mov")
        try Data("not media".utf8).write(to: corrupt)
        do {
            _ = try await ScratchExampleMediaImporter.validateMedia(at: corrupt, video: true)
            XCTFail("Corrupt media must fail before replacing the usable player")
        } catch {}
    }

    func testExportRetainsOriginalIdentityAndReferenceSnapshot() throws {
        let original = ScratchExampleImportedMedia(originalFilename: "Karl-take003.wav", originalSHA256: "original-digest",
                                                   copiedSHA256: "original-digest", byteCount: 123,
                                                   reviewURL: URL(fileURLWithPath: "/tmp/review-copy.wav"))
        let context = ScratchExampleAdvisoryExport.ReferenceContext(catalogueID: "catalogue-v1", sourceManifestSHA256: "manifest-digest",
                                                                    exampleID: "baby-take01", angleID: "angle_3", audioVariant: "noBeat")
        let report = OfflineScratchAdvisoryReport(schema: "scratchlab_offline_advisory_v1", generatedAt: Date(timeIntervalSince1970: 1),
                                                 windows: [], issues: [], sources: [], limitations: ["advisory"])
        let data = try JSONEncoder().encode(ScratchExampleAdvisoryExport(reference: context, importedMedia: [original], advisory: report))
        let restored = try JSONDecoder().decode(ScratchExampleAdvisoryExport.self, from: data)
        XCTAssertEqual(restored.schema, "scratchlab_example_advisory_review_v1")
        XCTAssertEqual(restored.reference, context)
        XCTAssertEqual(restored.importedMedia, [original])
        XCTAssertEqual(restored.advisory, report)
    }

    @MainActor
    func testEveryReferenceCameraCarriesItsMatchingScratchOnlyPCM() async throws {
        try await assertReferenceCameraPlayback(audioVariant: "noBeat")
    }

    @MainActor
    func testEveryReferenceCameraCarriesItsMatchingWithBeatPCM() async throws {
        try await assertReferenceCameraPlayback(audioVariant: "withBeat")
    }

    @MainActor
    func testEveryReferenceCameraCarriesItsMatchingBeatOnlyPCM() async throws {
        try await assertReferenceCameraPlayback(audioVariant: "beatOnly")
    }

    @MainActor
    func testReferencePlaybackRejectsMissingCorruptAndNonAudioSources() async throws {
        let library = try await ScratchExampleLibrary.loadBundled()
        let example = try XCTUnwrap(library.manifest.examples.first { $0.classLabel == "baby" })
        let angle = try XCTUnwrap(example.angles.first)
        let video = try await library.verifiedURL(assetID: angle.videoAssetID)
        // The bundled raw camera file has no audio. Passing it instead of its
        // separately recorded WAV must fail rather than produce silent video.
        let rawAudioTracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .audio)
        XCTAssertTrue(rawAudioTracks.isEmpty)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("corrupt.wav")
        try Data("not playable audio".utf8).write(to: corrupt)
        for invalid in [directory.appendingPathComponent("missing.wav"), corrupt, video] {
            do {
                _ = try await ScratchExampleReferencePlayback.makePlayerItem(videoURL: video, audioURL: invalid)
                XCTFail("Accepted audio source without a usable audio track: \(invalid.lastPathComponent)")
            } catch is CancellationError {
                XCTFail("A bad audio source is not a cancelled request")
            } catch { /* Expected an explicit media error, not a silent player. */ }
        }
    }

    @MainActor
    func testCancelledReferencePreparationDoesNotCreateAPlayerItem() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScratchExampleReferencePlayback.makePlayerItem(
                videoURL: URL(fileURLWithPath: "/not-opened-video.mp4"),
                audioURL: URL(fileURLWithPath: "/not-opened-audio.wav")
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation before media loading") }
        catch is CancellationError {} catch { XCTFail("Unexpected error instead of cancellation: \(error)") }
    }

    /// Three callers cover all 91 bundled camera selections in each of the
    /// three variants (273 compositions). The WAV is decoded independently
    /// once per example; every resulting composition is actually decoded and
    /// compared with that selected source. No speaker/device playback occurs.
    @MainActor
    private func assertReferenceCameraPlayback(audioVariant: String) async throws {
        let library = try await ScratchExampleLibrary.loadBundled()
        XCTAssertEqual(library.manifest.examples.count, 23, "The required bundled corpus must be present; do not silently skip it")
        var verifiedCameras = 0
        for example in library.manifest.examples {
            let audioID = try XCTUnwrap(example.audioAssetIDs[audioVariant])
            let audioURL = try await library.verifiedURL(assetID: audioID)
            let sourceAudio = AVURLAsset(url: audioURL)
            let audioTracks = try await sourceAudio.loadTracks(withMediaType: .audio)
            let originalAudioTrack = try XCTUnwrap(audioTracks.first)
            let originalAudioRange = try await originalAudioTrack.load(.timeRange)
            let audioAssetDuration = try await sourceAudio.load(.duration)
            let expectedPCM = try decodeFirstTwoSecondsOfPCM(asset: sourceAudio, audioTracks: audioTracks)
            XCTAssertGreaterThan(expectedPCM.count, 1_000, "\(example.id)/\(audioVariant): decoded WAV samples are required")
            XCTAssertGreaterThan(expectedPCM.map { abs($0) }.max() ?? 0, 0.0001,
                                 "\(example.id)/\(audioVariant): the selected WAV must contain audible signal")
            for angle in example.angles {
                let context = "\(example.id)/\(angle.id)/\(audioVariant)"
                let videoURL = try await library.verifiedURL(assetID: angle.videoAssetID)
                let sourceVideo = AVURLAsset(url: videoURL)
                let sourceVideoTracks = try await sourceVideo.loadTracks(withMediaType: .video)
                let originalVideoTrack = try XCTUnwrap(sourceVideoTracks.first, context)
                let originalVideoRange = try await originalVideoTrack.load(.timeRange)
                let videoAssetDuration = try await sourceVideo.load(.duration)
                let transform = try await originalVideoTrack.load(.preferredTransform)
                let item = try await ScratchExampleReferencePlayback.makePlayerItem(videoURL: videoURL, audioURL: audioURL)
                let composition = try XCTUnwrap(item.asset as? AVComposition, context)
                let composedAudioTracks = try await composition.loadTracks(withMediaType: .audio)
                let composedVideoTracks = try await composition.loadTracks(withMediaType: .video)
                XCTAssertEqual(composedAudioTracks.count, 1, "\(context): exactly the selected WAV, with no embedded camera audio mixed in")
                XCTAssertEqual(composedVideoTracks.count, 1, context)
                let composedAudio = try XCTUnwrap(composedAudioTracks.first as? AVCompositionTrack, context)
                let composedVideo = try XCTUnwrap(composedVideoTracks.first as? AVCompositionTrack, context)
                try await assertCompositionSegment(composedAudio, sourceURL: audioURL, sourceRange: originalAudioRange, assetDuration: audioAssetDuration, context: context)
                try await assertCompositionSegment(composedVideo, sourceURL: videoURL, sourceRange: originalVideoRange, assetDuration: videoAssetDuration, context: context)
                let composedTransform = try await composedVideo.load(.preferredTransform)
                XCTAssertEqual(composedTransform, transform, "\(context): preserve source orientation")
                let duration = try await composition.load(.duration)
                XCTAssertEqual(duration.seconds, max(videoAssetDuration.seconds, audioAssetDuration.seconds),
                               accuracy: 0.000001, "\(context): retain the longer source tail")
                let playable = try await composition.load(.isPlayable)
                XCTAssertTrue(playable, context)
                let actualPCM = try decodeFirstTwoSecondsOfPCM(asset: composition, audioTracks: composedAudioTracks)
                XCTAssertEqual(actualPCM.count, expectedPCM.count, context)
                if actualPCM.count == expectedPCM.count {
                    let maximumDifference = zip(actualPCM, expectedPCM).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
                    XCTAssertLessThanOrEqual(maximumDifference, 0.000001,
                                             "\(context): decoded player audio must match the selected WAV, including timing and gain")
                }
                XCTAssertGreaterThan(actualPCM.map { abs($0) }.max() ?? 0, 0.0001, "\(context): composition must decode non-silent PCM")
                verifiedCameras += 1
            }
        }
        XCTAssertEqual(verifiedCameras, 91, "Each available camera must be checked with \(audioVariant), without skipping missing resources")
    }

    private func assertCompositionSegment(
        _ track: AVCompositionTrack, sourceURL: URL, sourceRange: CMTimeRange,
        assetDuration: CMTime, context: String
    ) async throws {
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        XCTAssertEqual(segments.count, 1, context)
        let segment = try XCTUnwrap(segments.first as? AVCompositionTrackSegment, context)
        XCTAssertEqual(segment.sourceURL?.resolvingSymlinksInPath().standardizedFileURL,
                       sourceURL.resolvingSymlinksInPath().standardizedFileURL, context)
        XCTAssertEqual(CMTimeCompare(segment.timeMapping.source.start, sourceRange.start), 0, "\(context): no inferred source offset")
        XCTAssertEqual(CMTimeCompare(segment.timeMapping.target.start, .zero), 0, "\(context): common playback starts at zero")
        // MP4's movie duration can include a fractional-frame tail beyond the
        // last video sample. Preserve all available media and the full movie
        // timeline without requiring that empty tail to be a nonempty segment.
        XCTAssertGreaterThanOrEqual(segment.timeMapping.source.duration.seconds + 0.000001,
                                    sourceRange.duration.seconds, "\(context): no source cropping")
        XCTAssertLessThanOrEqual(segment.timeMapping.source.duration.seconds, assetDuration.seconds + 0.000001, context)
        XCTAssertEqual(CMTimeCompare(segment.timeMapping.target.duration, segment.timeMapping.source.duration), 0,
                       "\(context): no stretching")
        let timeline = try await track.load(.timeRange)
        XCTAssertEqual(timeline.duration.seconds, assetDuration.seconds, accuracy: 0.000001,
                       "\(context): retain the full source timeline including any empty tail")
    }

    private func decodeFirstTwoSecondsOfPCM(asset: AVAsset, audioTracks: [AVAssetTrack]) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw NSError(domain: "ReferencePlaybackTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot attach PCM reader"]) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "ReferencePlaybackTests", code: 2) }
        defer { reader.cancelReading() }
        var bytes = Data()
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(buffer)
            guard length > 0 else { continue }
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            bytes.append(chunk)
            guard bytes.count <= 2 * 16_000 * MemoryLayout<Float>.size + 16_384 else {
                throw NSError(domain: "ReferencePlaybackTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "PCM reader exceeded bounded sample range"])
            }
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "ReferencePlaybackTests", code: 4) }
        XCTAssertEqual(bytes.count % MemoryLayout<Float>.size, 0)
        return bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: MemoryLayout<Float>.size).map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor ReviewWorkGate {
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func open() {
        released = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
}
