import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

final class ActionDatasetValidatorTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_action_validator_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeClassFolder(_ label: String, fileCount: Int, ext: String = "mp4") throws {
        let dir = tempDir.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            let url = dir.appendingPathComponent("\(label)_\(i).\(ext)")
            try Data().write(to: url)
        }
    }

    // MARK: - Happy path

    func test_validate_acceptsAllExpectedClassLabels() throws {
        for label in ScratchClassLabel.allCases {
            try makeClassFolder(label.rawValue, fileCount: 12)
        }
        let validator = ActionDatasetValidator()
        let result = try validator.validateDataset(at: tempDir, minimumSamplesPerClass: 12)
        XCTAssertEqual(Set(result.labels), Set(ScratchClassLabel.allCases))
        for label in ScratchClassLabel.allCases {
            XCTAssertEqual(result.perLabelCount[label], 12)
        }
    }

    func test_validate_returnsLabelsSortedByFolderName() throws {
        try makeClassFolder("baby", fileCount: 12)
        try makeClassFolder("tears", fileCount: 12)
        try makeClassFolder("crabs", fileCount: 12)
        let result = try ActionDatasetValidator()
            .validateDataset(at: tempDir, minimumSamplesPerClass: 12)
        XCTAssertEqual(result.labels.map { $0.rawValue }, ["baby", "crabs", "tears"])
    }

    // MARK: - mp4 counting

    func test_validate_ignoresNonMp4FilesInClassFolder() throws {
        try makeClassFolder("baby", fileCount: 12, ext: "mp4")
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        try Data().write(to: dir.appendingPathComponent("clip.mov"))
        try Data().write(to: dir.appendingPathComponent("audio.wav"))
        let result = try ActionDatasetValidator()
            .validateDataset(at: tempDir, minimumSamplesPerClass: 12)
        XCTAssertEqual(result.perLabelCount[.baby], 12)
    }

    func test_validate_acceptsUppercaseExtensionForMp4() throws {
        let label = ScratchClassLabel.baby.rawValue
        let dir = tempDir.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<12 {
            try Data().write(to: dir.appendingPathComponent("clip_\(i).MP4"))
        }
        let result = try ActionDatasetValidator()
            .validateDataset(at: tempDir, minimumSamplesPerClass: 12)
        XCTAssertEqual(result.perLabelCount[.baby], 12)
    }

    func test_clips_returnsOnlyMp4SortedByName() throws {
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("b.mp4"))
        try Data().write(to: dir.appendingPathComponent("a.mp4"))
        try Data().write(to: dir.appendingPathComponent("c.txt"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        let urls = ActionDatasetValidator().clips(in: dir)
        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["a.mp4", "b.mp4"])
    }

    // MARK: - Failure modes

    func test_validate_throwsForMissingDirectory() {
        let bogus = tempDir.appendingPathComponent("nope_\(UUID().uuidString)")
        XCTAssertThrowsError(try ActionDatasetValidator().validateDataset(at: bogus)) { err in
            guard case MotionTrainerError.datasetNotFound = err else {
                return XCTFail("expected .datasetNotFound, got \(err)")
            }
        }
    }

    func test_validate_throwsWhenPathIsAFile() throws {
        let file = tempDir.appendingPathComponent("a-file.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try ActionDatasetValidator().validateDataset(at: file)) { err in
            guard case MotionTrainerError.datasetNotADirectory = err else {
                return XCTFail("expected .datasetNotADirectory, got \(err)")
            }
        }
    }

    func test_validate_throwsWhenNoClassFolders() {
        XCTAssertThrowsError(try ActionDatasetValidator().validateDataset(at: tempDir)) { err in
            guard case MotionTrainerError.noClassFolders = err else {
                return XCTFail("expected .noClassFolders, got \(err)")
            }
        }
    }

    func test_validate_rejectsUnknownClassFolder() throws {
        try makeClassFolder("baby", fileCount: 12)
        try makeClassFolder("not_a_real_scratch", fileCount: 12)
        XCTAssertThrowsError(try ActionDatasetValidator().validateDataset(at: tempDir)) { err in
            guard case MotionTrainerError.unknownClassLabel(let name) = err else {
                return XCTFail("expected .unknownClassLabel, got \(err)")
            }
            XCTAssertEqual(name, "not_a_real_scratch")
        }
    }

    func test_validate_rejectsClassBelowMinimum() throws {
        try makeClassFolder("baby", fileCount: 12)
        try makeClassFolder("tears", fileCount: 3)
        XCTAssertThrowsError(
            try ActionDatasetValidator().validateDataset(at: tempDir, minimumSamplesPerClass: 12)
        ) { err in
            guard case MotionTrainerError.classBelowMinimum(let label, let count, let minimum) = err else {
                return XCTFail("expected .classBelowMinimum, got \(err)")
            }
            XCTAssertEqual(label, "tears")
            XCTAssertEqual(count, 3)
            XCTAssertEqual(minimum, 12)
        }
    }

    // MARK: - Codable round trip on the new ScratchMotionFrame fields

    func test_motionFrame_roundTripsThroughJSON() throws {
        let frame = ScratchMotionFrame(
            timestamp: 1.5,
            dominantHand: CGPoint(x: 0.4, y: 0.6),
            recordEdgeAngle: 12.5,
            crossfaderPosition: 0.7,
            dominantHandWrist: CGPoint(x: 0.41, y: 0.61),
            dominantHandIndexTip: CGPoint(x: 0.42, y: 0.62),
            dominantHandThumbTip: CGPoint(x: 0.43, y: 0.63),
            dominantHandMiddleTip: CGPoint(x: 0.44, y: 0.64),
            dominantHandConfidence: 0.93,
            secondaryHandWrist: CGPoint(x: 0.55, y: 0.7),
            recordCenter: CGPoint(x: 0.5, y: 0.5)
        )
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(ScratchMotionFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
    }

    func test_motionFrame_compatibleWithLegacyInitializer() {
        // Existing call sites (timestamp-only and the four original params)
        // must keep compiling — this test is a compile-time guard.
        let a = ScratchMotionFrame(timestamp: 0)
        let b = ScratchMotionFrame(
            timestamp: 1,
            dominantHand: CGPoint(x: 0.5, y: 0.5)
        )
        let c = ScratchMotionFrame(
            timestamp: 2,
            dominantHand: CGPoint(x: 0.1, y: 0.2),
            recordEdgeAngle: 0.3,
            crossfaderPosition: 0.4
        )
        XCTAssertEqual(a.timestamp, 0)
        XCTAssertNil(a.dominantHandWrist)
        XCTAssertEqual(b.dominantHand?.x, 0.5)
        XCTAssertEqual(c.crossfaderPosition, 0.4)
    }
}
