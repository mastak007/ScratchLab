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
