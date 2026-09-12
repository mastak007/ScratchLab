import XCTest
@testable import ScratchLabML

/// Opt-in compatibility smoke on one existing Baby example. No training,
/// accuracy calculation, dataset changes, or app metadata writes occur here.
final class OfflineScratchAdvisorySmokeTests: XCTestCase {
    func testVerifiedBabyAudioAndVideoProduceSeparateAdvisoryWindows() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["SCRATCHLAB_ADVISORY_SMOKE_ROOT"] else {
            throw XCTSkip("Set SCRATCHLAB_ADVISORY_SMOKE_ROOT to the external reference-library directory for actual-model compatibility smoke.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let manifest = try JSONDecoder().decode(SmokeManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let assets = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        let baby = try XCTUnwrap(manifest.examples.first { $0.classLabel == "baby" })
        let angle = try XCTUnwrap(baby.angles.first { $0.id == "angle_3" })
        let audio = try XCTUnwrap(assets[try XCTUnwrap(baby.audioAssetIDs["noBeat"])])
        let video = try XCTUnwrap(assets[angle.videoAssetID])
        let sound = try XCTUnwrap(assets[try XCTUnwrap(manifest.models.first { $0.modality == "audio" }).assetID])
        let action = try XCTUnwrap(assets[try XCTUnwrap(manifest.models.first { $0.modality == "motion" }).assetID])
        let report = try await OfflineScratchAdvisoryService().analyze(
            audioURL: root.appendingPathComponent(audio.relativePath),
            videoURL: root.appendingPathComponent(video.relativePath),
            soundModel: .init(modelURL: root.appendingPathComponent(sound.relativePath), sourceSHA256: sound.sha256),
            actionModel: .init(modelURL: root.appendingPathComponent(action.relativePath), sourceSHA256: action.sha256)
        )
        if let outputPath = environment["SCRATCHLAB_ADVISORY_SMOKE_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        XCTAssertTrue(report.issues.isEmpty, "\(report.issues)")
        XCTAssertEqual(Set(report.windows.map(\.modality)), Set([.audio, .motion]))
        XCTAssertEqual(report.sources.count, 2)
        XCTAssertTrue(report.windows.allSatisfy { $0.modelScore.isFinite && (0...1).contains($0.modelScore) })
        XCTAssertTrue(report.windows.allSatisfy { !$0.label.isEmpty && $0.endSeconds > $0.startSeconds })
        XCTAssertEqual(report.sources.first { $0.modality == .audio }?.mediaSHA256, audio.sha256)
        XCTAssertEqual(report.sources.first { $0.modality == .motion }?.mediaSHA256, video.sha256)
        XCTAssertEqual(report.sources.first { $0.modality == .motion }?.modelSHA256, action.sha256)
        XCTAssertTrue(report.windows.filter { $0.modality == .motion }.allSatisfy { !$0.qualityNotes.isEmpty })
        // Deliberately do not assert an expected technique: this is interface
        // compatibility evidence, not a generalization/accuracy evaluation.
    }
}

private struct SmokeManifest: Decodable {
    struct Asset: Decodable { let id: String; let relativePath: String; let sha256: String }
    struct Model: Decodable { let modality: String; let assetID: String }
    struct Example: Decodable {
        struct Angle: Decodable { let id: String; let videoAssetID: String }
        let classLabel: String
        let angles: [Angle]
        let audioAssetIDs: [String: String]
    }
    let assets: [Asset]
    let models: [Model]
    let examples: [Example]
}
