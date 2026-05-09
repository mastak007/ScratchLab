import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

final class FeatureCacheValidatorTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_cache_validator_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixture helpers

    /// Build a JSONL file with `frameCount` synthetic frames. The optional
    /// closure lets a test mutate individual frames (e.g. drop a landmark
    /// or push a coordinate above 1.0).
    private func writeClip(
        class cls: String,
        stem: String,
        frameCount: Int,
        timestampStart: Double = 0,
        timestampStep: Double = 1.0 / 30.0,
        mutate: (Int, inout ScratchMotionFrame) -> Void = { _, _ in }
    ) throws -> URL {
        let dir = tempDir.appendingPathComponent(cls, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(stem).jsonl")
        var text = ""
        let encoder = JSONEncoder()
        for i in 0..<frameCount {
            var f = ScratchMotionFrame(
                timestamp: timestampStart + Double(i) * timestampStep,
                dominantHand: CGPoint(x: 0.5, y: 0.5),
                dominantHandWrist: CGPoint(x: 0.4, y: 0.6),
                dominantHandIndexTip: CGPoint(x: 0.5, y: 0.5),
                dominantHandThumbTip: CGPoint(x: 0.45, y: 0.55),
                dominantHandMiddleTip: CGPoint(x: 0.55, y: 0.45),
                dominantHandConfidence: 0.9,
                secondaryHandWrist: CGPoint(x: 0.7, y: 0.6),
                recordCenter: nil
            )
            mutate(i, &f)
            let data = try encoder.encode(f)
            text.append(String(data: data, encoding: .utf8)!)
            text.append("\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Happy path

    func test_audit_acceptsCleanCache() throws {
        _ = try writeClip(class: "baby", stem: "baby_take01", frameCount: 30)
        _ = try writeClip(class: "baby", stem: "baby_take02", frameCount: 30)
        _ = try writeClip(class: "tears", stem: "tears_take01", frameCount: 30)

        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.totalFiles, 3)
        XCTAssertEqual(report.totalFrames, 90)
        XCTAssertEqual(report.perClassFiles["baby"], 2)
        XCTAssertEqual(report.perClassFiles["tears"], 1)
        XCTAssertEqual(report.perClassFrames["baby"], 60)
        XCTAssertEqual(report.perClassFrames["tears"], 30)
        XCTAssertEqual(report.dominantHandCoverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.dominantHandWristCoverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.secondaryHandWristCoverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.outOfRangeFrameCount, 0)
        XCTAssertTrue(report.emptyFiles.isEmpty)
        XCTAssertTrue(report.malformedFiles.isEmpty)
        XCTAssertTrue(report.nonMonotonicFiles.isEmpty)
        XCTAssertTrue(report.unknownClassFolders.isEmpty)
        XCTAssertTrue(report.coverageBelowThresholdClasses.isEmpty)
        XCTAssertTrue(report.wristCoverageBelowThresholdClasses.isEmpty)
        XCTAssertNil(report.unexpectedFileCount)
        XCTAssertTrue(report.isStructurallyClean)
        XCTAssertTrue(report.meetsAllThresholds)
    }

    // MARK: - Failure detection

    func test_audit_detectsEmptyFiles() throws {
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("baby_empty.jsonl"))
        _ = try writeClip(class: "baby", stem: "baby_full", frameCount: 30)

        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.emptyFiles.count, 1)
        XCTAssertEqual(report.emptyFiles.first, "baby/baby_empty.jsonl")
        XCTAssertFalse(report.isStructurallyClean)
        XCTAssertFalse(report.meetsAllThresholds)
    }

    func test_audit_detectsMalformedJSON() throws {
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("baby_bad.jsonl")
        try "{not valid json}\n".write(to: bad, atomically: true, encoding: .utf8)

        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.malformedFiles, ["baby/baby_bad.jsonl"])
        XCTAssertFalse(report.isStructurallyClean)
    }

    func test_audit_detectsNonMonotonicTimestamps() throws {
        // Drop the timestamp of frame 5 below frame 4 to break monotonicity.
        _ = try writeClip(class: "baby", stem: "baby_oop", frameCount: 30) { i, frame in
            if i == 5 {
                frame = ScratchMotionFrame(
                    timestamp: 0.05,
                    dominantHand: CGPoint(x: 0.5, y: 0.5),
                    dominantHandWrist: CGPoint(x: 0.4, y: 0.6),
                    dominantHandIndexTip: CGPoint(x: 0.5, y: 0.5),
                    dominantHandThumbTip: CGPoint(x: 0.45, y: 0.55),
                    dominantHandMiddleTip: CGPoint(x: 0.55, y: 0.45),
                    dominantHandConfidence: 0.9,
                    secondaryHandWrist: CGPoint(x: 0.7, y: 0.6),
                    recordCenter: nil
                )
            }
        }
        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.nonMonotonicFiles, ["baby/baby_oop.jsonl"])
        XCTAssertFalse(report.isStructurallyClean)
    }

    func test_audit_countsOutOfRangeCoordinates() throws {
        _ = try writeClip(class: "baby", stem: "baby_oor", frameCount: 30) { i, frame in
            if i % 6 == 0 {
                frame = ScratchMotionFrame(
                    timestamp: Double(i) / 30.0,
                    dominantHand: CGPoint(x: 0.5, y: 0.5),
                    dominantHandWrist: CGPoint(x: 0.5, y: 1.0007),
                    dominantHandIndexTip: CGPoint(x: 0.5, y: 0.5),
                    dominantHandThumbTip: CGPoint(x: 0.5, y: 0.5),
                    dominantHandMiddleTip: CGPoint(x: 0.5, y: 0.5),
                    dominantHandConfidence: 0.9,
                    secondaryHandWrist: nil,
                    recordCenter: nil
                )
            }
        }
        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.outOfRangeFrameCount, 5)  // frames 0,6,12,18,24
        XCTAssertGreaterThan(report.outOfRangeFraction, 0)
        // 5/30 ≈ 16.67% — exceeds the default 5% threshold.
        XCTAssertFalse(report.meetsAllThresholds)
        // Out-of-range alone is not "structural" — file is otherwise clean.
        XCTAssertTrue(report.isStructurallyClean)
    }

    func test_audit_flagsUnknownClassFolder() throws {
        _ = try writeClip(class: "baby", stem: "baby_take01", frameCount: 30)
        _ = try writeClip(class: "made_up_label", stem: "x_take01", frameCount: 30)
        let report = try FeatureCacheValidator().audit(at: tempDir)
        XCTAssertEqual(report.unknownClassFolders, ["made_up_label"])
        XCTAssertFalse(report.isStructurallyClean)
    }

    func test_audit_unexpectedFileCount() throws {
        _ = try writeClip(class: "baby", stem: "baby_take01", frameCount: 30)
        _ = try writeClip(class: "baby", stem: "baby_take02", frameCount: 30)
        let report = try FeatureCacheValidator().audit(
            at: tempDir,
            configuration: .init(expectedFileCount: 5)
        )
        XCTAssertEqual(report.unexpectedFileCount?.expected, 5)
        XCTAssertEqual(report.unexpectedFileCount?.observed, 2)
        XCTAssertFalse(report.meetsAllThresholds)
    }

    func test_audit_belowDominantHandCoverageThreshold() throws {
        // Drop dominantHand from 80% of frames so the class falls under 50%.
        _ = try writeClip(class: "baby", stem: "baby_low", frameCount: 50) { i, frame in
            if i % 5 != 0 {
                frame = ScratchMotionFrame(
                    timestamp: Double(i) / 30.0,
                    dominantHand: nil,
                    dominantHandWrist: CGPoint(x: 0.4, y: 0.6),
                    dominantHandConfidence: 0.0,
                    secondaryHandWrist: nil
                )
            }
        }
        let report = try FeatureCacheValidator().audit(
            at: tempDir,
            configuration: .init(minimumDominantHandCoverage: 0.5)
        )
        XCTAssertEqual(report.coverageBelowThresholdClasses, ["baby"])
        XCTAssertFalse(report.meetsAllThresholds)
    }

    // MARK: - Cache-not-found

    func test_audit_throwsForMissingCache() {
        let bogus = tempDir.appendingPathComponent("nope_\(UUID().uuidString)")
        XCTAssertThrowsError(try FeatureCacheValidator().audit(at: bogus)) { err in
            guard case FeatureCacheValidator.AuditError.cacheNotFound = err else {
                return XCTFail("expected .cacheNotFound, got \(err)")
            }
        }
    }

    func test_audit_throwsWhenPathIsAFile() throws {
        let file = tempDir.appendingPathComponent("a.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try FeatureCacheValidator().audit(at: file)) { err in
            guard case FeatureCacheValidator.AuditError.cacheNotADirectory = err else {
                return XCTFail("expected .cacheNotADirectory, got \(err)")
            }
        }
    }

    // MARK: - Codable round trip on the report

    func test_report_roundTripsThroughJSON() throws {
        _ = try writeClip(class: "baby", stem: "baby_take01", frameCount: 30)
        let report = try FeatureCacheValidator().audit(at: tempDir)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(FeatureCacheAuditReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }
}
