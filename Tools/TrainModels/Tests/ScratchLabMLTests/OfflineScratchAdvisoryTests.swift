import XCTest
import AVFoundation
import CoreGraphics
@testable import ScratchLabML

final class OfflineScratchAdvisoryTests: XCTestCase {
    func testLegacyTransformKeepsMissingSentinelsAndOffImageClipping() throws {
        let frames = (0..<60).map { index in
            ScratchMotionFrame(
                timestamp: Double(index) / 30,
                dominantHand: index.isMultiple(of: 2) ? CGPoint(x: -0.2, y: 1.2) : nil
            )
        }
        let window = try XCTUnwrap(MotionWindowBuilder().windows(
            forFrames: frames, classLabel: "unlabelled", sourceFile: "fixture"
        ).first)
        let row = ActionTrainerFeatures.projectToRow(window)
        XCTAssertEqual(row.count, 67)
        XCTAssertEqual(row["dominantHandX_mean"], 0)
        XCTAssertEqual(row["dominantHandY_mean"], 0.5)
        XCTAssertEqual(row["dominantHandY_std"], 0.5)
        XCTAssertEqual(row["dominantHandPresent_rate"], 0.5)
        XCTAssertEqual(row["agg_dominantHandMissingRatio"], 0.5)
        XCTAssertEqual(row["agg_dominantHandPathLength"], 0, "Do not bridge missing detections")
        XCTAssertNil(frames[1].dominantHand)
        XCTAssertEqual(frames[0].dominantHand?.y, 1.2, "Raw evidence is not clamped in place")
    }

    func testWindowsKeepRequestedClockAndSixtyThirtyContract() {
        let frames = (0..<91).map { ScratchMotionFrame(timestamp: 0.0333333333 + Double($0) / 30) }
        let windows = MotionWindowBuilder().windows(forFrames: frames, classLabel: "unknown", sourceFile: "fixture")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.frameCount), [60, 60])
        XCTAssertEqual(windows[0].startTimestamp, frames[0].timestamp)
        XCTAssertEqual(windows[0].endTimestamp, frames[59].timestamp)
        XCTAssertEqual(windows[1].startTimestamp, frames[30].timestamp)
        XCTAssertEqual(windows[1].endTimestamp, frames[89].timestamp)
    }

    func testRawModelFingerprintUsesFileBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("fixture.mlmodel")
        try Data("abc".utf8).write(to: model)
        XCTAssertEqual(try OfflineScratchAdvisoryService.modelArtifactSHA256(at: model),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCompiledFingerprintTracksNestedContentAndRelativePaths() throws {
        let directory = try temporaryDirectory().appendingPathComponent("fixture.mlmodelc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let weights = directory.appendingPathComponent("weights.bin")
        try Data([1, 2, 3]).write(to: weights)
        let first = try OfflineScratchAdvisoryService.modelArtifactSHA256(at: directory)
        try Data([1, 2, 4]).write(to: weights)
        let changedContent = try OfflineScratchAdvisoryService.modelArtifactSHA256(at: directory)
        XCTAssertNotEqual(first, changedContent)
        try FileManager.default.moveItem(at: weights, to: directory.appendingPathComponent("renamed.bin"))
        XCTAssertNotEqual(changedContent, try OfflineScratchAdvisoryService.modelArtifactSHA256(at: directory))
    }

    func testMissingInputFailsClearly() async {
        do {
            _ = try await OfflineScratchAdvisoryService().analyze()
            XCTFail("Expected an invalid request")
        } catch let error as OfflineScratchAdvisoryError {
            guard case .invalidRequest = error else { return XCTFail("Unexpected \(error)") }
        } catch { XCTFail("Unexpected \(error)") }
    }

    func testMissingModelDoesNotBecomeAnEmptySuccessfulReport() async {
        do {
            _ = try await OfflineScratchAdvisoryService().analyze(audioURL: URL(fileURLWithPath: "/missing/final.wav"))
            XCTFail("Expected no results")
        } catch let error as OfflineScratchAdvisoryError {
            guard case .noResults(let issues) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(issues.count, 1)
            XCTAssertEqual(issues.first?.modality, .audio)
            XCTAssertTrue(issues.first?.message.contains("model is unavailable") == true)
        } catch { XCTFail("Unexpected \(error)") }
    }

    func testLongMediaIsRejectedRatherThanSilentlyCropped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("one-second.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData?[0][index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        do {
            _ = try await OfflineScratchAdvisoryService(maximumDurationSeconds: 0.1).analyze(
                audioURL: audio,
                soundModel: .init(modelURL: directory.appendingPathComponent("unused.mlmodel"), sourceSHA256: "unused")
            )
            XCTFail("Expected duration refusal before model analysis")
        } catch let error as OfflineScratchAdvisoryError {
            guard case .noResults(let issues) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(issues.first?.message.contains("no partial result was produced") == true)
        }
    }

    func testCancelledRequestProducesCancellationRatherThanResearchOutput() async {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OfflineScratchAdvisoryService().analyze(audioURL: URL(fileURLWithPath: "/not-read.wav"))
        }
        do {
            _ = try await work.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must not be rewritten as a model/source error.
        } catch { XCTFail("Unexpected \(error)") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
