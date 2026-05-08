import XCTest
@testable import SoundTrainer
@testable import ScratchLabML

final class SoundClassifierTrainerTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_sound_trainer_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeClassFolder(_ label: String, fileCount: Int, ext: String = "wav") throws {
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
            try makeClassFolder(label.rawValue, fileCount: 5)
        }
        let trainer = SoundClassifierTrainer()
        let result = try trainer.validateDataset(at: tempDir, minimumSamplesPerClass: 3)
        XCTAssertEqual(Set(result.labels), Set(ScratchClassLabel.allCases))
        for label in ScratchClassLabel.allCases {
            XCTAssertEqual(result.perLabelCount[label], 5)
        }
    }

    func test_validate_countsEveryRecognizedAudioExtension() throws {
        let label = ScratchClassLabel.baby.rawValue
        let dir = tempDir.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exts = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
        for (i, ext) in exts.enumerated() {
            let url = dir.appendingPathComponent("sample_\(i).\(ext)")
            try Data().write(to: url)
        }
        let trainer = SoundClassifierTrainer()
        let result = try trainer.validateDataset(at: tempDir, minimumSamplesPerClass: 3)
        XCTAssertEqual(result.perLabelCount[.baby], exts.count)
    }

    func test_validate_ignoresNonAudioFilesInClassFolder() throws {
        try makeClassFolder("baby", fileCount: 5, ext: "wav")
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        let trainer = SoundClassifierTrainer()
        let result = try trainer.validateDataset(at: tempDir, minimumSamplesPerClass: 3)
        XCTAssertEqual(result.perLabelCount[.baby], 5)
    }

    // MARK: - Failure modes

    func test_validate_throwsForMissingDirectory() {
        let bogus = tempDir.appendingPathComponent("nope_\(UUID().uuidString)")
        XCTAssertThrowsError(try SoundClassifierTrainer().validateDataset(at: bogus)) { err in
            guard case SoundTrainerError.datasetNotFound = err else {
                return XCTFail("expected .datasetNotFound, got \(err)")
            }
        }
    }

    func test_validate_throwsWhenPathIsAFile() throws {
        let file = tempDir.appendingPathComponent("a-file.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try SoundClassifierTrainer().validateDataset(at: file)) { err in
            guard case SoundTrainerError.datasetNotADirectory = err else {
                return XCTFail("expected .datasetNotADirectory, got \(err)")
            }
        }
    }

    func test_validate_throwsWhenNoClassFolders() {
        XCTAssertThrowsError(try SoundClassifierTrainer().validateDataset(at: tempDir)) { err in
            guard case SoundTrainerError.noClassFolders = err else {
                return XCTFail("expected .noClassFolders, got \(err)")
            }
        }
    }

    func test_validate_rejectsUnknownClassFolder() throws {
        try makeClassFolder("baby", fileCount: 5)
        try makeClassFolder("not_a_real_scratch", fileCount: 5)
        XCTAssertThrowsError(try SoundClassifierTrainer().validateDataset(at: tempDir)) { err in
            guard case SoundTrainerError.unknownClassLabel(let name) = err else {
                return XCTFail("expected .unknownClassLabel, got \(err)")
            }
            XCTAssertEqual(name, "not_a_real_scratch")
        }
    }

    func test_validate_rejectsClassBelowMinimum() throws {
        try makeClassFolder("baby", fileCount: 5)
        try makeClassFolder("tears", fileCount: 1)
        XCTAssertThrowsError(
            try SoundClassifierTrainer().validateDataset(at: tempDir, minimumSamplesPerClass: 3)
        ) { err in
            guard case SoundTrainerError.classBelowMinimum(let label, let count, let minimum) = err else {
                return XCTFail("expected .classBelowMinimum, got \(err)")
            }
            XCTAssertEqual(label, "tears")
            XCTAssertEqual(count, 1)
            XCTAssertEqual(minimum, 3)
        }
    }
}
