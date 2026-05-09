import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

final class ActionWindowDatasetTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch_window_dataset_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixture builder

    /// Write `windowsPerClip` synthetic windows for a given clip, then
    /// each subsequent clip in the class. Each window has 60 frames at
    /// timestamps 0, 1/30, 2/30 … (the trainer doesn't care about real
    /// timestamps — only frame ORDER).
    private func writeClipFile(
        class cls: String,
        clipStem: String,
        windowsPerClip: Int,
        framesPerWindow: Int = 60
    ) throws {
        let dir = tempDir.appendingPathComponent(cls, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(clipStem).windows.jsonl")

        var lines = ""
        let encoder = JSONEncoder()
        for w in 0..<windowsPerClip {
            var frames: [MotionFrameFeatures] = []
            for f in 0..<framesPerWindow {
                let t = Double(w * 30 + f) / 30.0
                frames.append(MotionFrameFeatures(
                    timestamp: t,
                    dominantHandX: 0.5, dominantHandY: 0.5, dominantHandPresent: true,
                    dominantHandWristX: 0.4, dominantHandWristY: 0.6, dominantHandWristPresent: true,
                    dominantHandIndexTipX: 0.5, dominantHandIndexTipY: 0.5, dominantHandIndexTipPresent: true,
                    dominantHandThumbTipX: 0.45, dominantHandThumbTipY: 0.55, dominantHandThumbTipPresent: true,
                    dominantHandMiddleTipX: 0.55, dominantHandMiddleTipY: 0.45, dominantHandMiddleTipPresent: true,
                    secondaryHandWristX: 0.7, secondaryHandWristY: 0.6, secondaryHandWristPresent: true,
                    recordCenterX: 0, recordCenterY: 0, recordCenterPresent: false,
                    dominantHandConfidence: 0.9
                ))
            }
            let agg = MotionWindowAggregates(
                dominantWristPathLength: 0,
                dominantHandPathLength: 0,
                romX: 0, romY: 0,
                meanVelocity: 0, maxVelocity: 0,
                centerLineCrossings: 0,
                dominantHandMissingRatio: 0,
                dominantHandWristMissingRatio: 0
            )
            let window = MotionFeatureWindow(
                classLabel: cls,
                sourceFile: "\(clipStem).jsonl",
                windowIndex: w,
                startTimestamp: frames.first?.timestamp ?? 0,
                endTimestamp: frames.last?.timestamp ?? 0,
                frameCount: frames.count,
                frames: frames,
                aggregates: agg
            )
            let data = try encoder.encode(window)
            lines.append(String(data: data, encoding: .utf8)!)
            lines.append("\n")
        }
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Convenience: build a class with N clips, each producing
    /// `windowsPerClip` windows. Clip stems are `<cls>_takeNN`.
    private func writeClass(
        _ cls: String,
        clipCount: Int,
        windowsPerClip: Int
    ) throws {
        for i in 0..<clipCount {
            let stem = String(format: "%@_take%02d", cls, i)
            try writeClipFile(class: cls, clipStem: stem, windowsPerClip: windowsPerClip)
        }
    }

    // MARK: - Loading

    func test_load_findsAllWindowsAndExtractsClassFromFolder() throws {
        try writeClass("baby", clipCount: 3, windowsPerClip: 4)
        try writeClass("tears", clipCount: 2, windowsPerClip: 5)
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.0, seed: 1
        )
        XCTAssertEqual(ds.allWindows.count, 3 * 4 + 2 * 5)
        XCTAssertEqual(ds.perClassTotal["baby"], 12)
        XCTAssertEqual(ds.perClassTotal["tears"], 10)
        // Session IDs include the class so they're unique across classes.
        let sessionIDs = Set(ds.allWindows.map { $0.sessionID })
        XCTAssertEqual(sessionIDs.count, ds.allWindows.count)
    }

    func test_load_throwsForMissingDirectory() {
        let bogus = tempDir.appendingPathComponent("nope_\(UUID().uuidString)")
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(windowsDir: bogus)) { err in
            guard case ActionWindowDatasetError.windowsDirectoryNotFound = err else {
                return XCTFail("expected .windowsDirectoryNotFound, got \(err)")
            }
        }
    }

    func test_load_throwsForFileInsteadOfDirectory() throws {
        let file = tempDir.appendingPathComponent("a.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(windowsDir: file)) { err in
            guard case ActionWindowDatasetError.windowsDirectoryNotADirectory = err else {
                return XCTFail("expected .windowsDirectoryNotADirectory, got \(err)")
            }
        }
    }

    func test_load_throwsWhenNoWindowsPresent() throws {
        // Empty directory tree (class folder with no .windows.jsonl).
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(windowsDir: tempDir)) { err in
            guard case ActionWindowDatasetError.noWindowsFound = err else {
                return XCTFail("expected .noWindowsFound, got \(err)")
            }
        }
    }

    func test_load_throwsForMalformedJSONLine() throws {
        let dir = tempDir.appendingPathComponent("baby", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("baby_bad.windows.jsonl")
        try "{not json}\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(windowsDir: tempDir)) { err in
            guard case ActionWindowDatasetError.malformedWindowFile = err else {
                return XCTFail("expected .malformedWindowFile, got \(err)")
            }
        }
    }

    func test_load_rejectsValidationFractionOutOfRange() throws {
        try writeClass("baby", clipCount: 4, windowsPerClip: 2)
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.6
        )) { err in
            guard case ActionWindowDatasetError.invalidValidationFraction = err else {
                return XCTFail("expected .invalidValidationFraction, got \(err)")
            }
        }
        XCTAssertThrowsError(try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: -0.1
        ))
    }

    // MARK: - Determinism

    func test_split_isDeterministicForSameSeed() throws {
        try writeClass("baby", clipCount: 8, windowsPerClip: 3)
        try writeClass("tears", clipCount: 8, windowsPerClip: 3)
        let a = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 42
        )
        let b = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 42
        )
        XCTAssertEqual(a.trainingWindows.map { $0.sessionID },
                       b.trainingWindows.map { $0.sessionID })
        XCTAssertEqual(a.validationWindows.map { $0.sessionID },
                       b.validationWindows.map { $0.sessionID })
    }

    func test_split_changesWithDifferentSeed() throws {
        try writeClass("baby", clipCount: 8, windowsPerClip: 3)
        try writeClass("tears", clipCount: 8, windowsPerClip: 3)
        let a = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 42
        )
        let b = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 4242
        )
        let aTrain = Set(a.trainingWindows.map { $0.sourceFile })
        let bTrain = Set(b.trainingWindows.map { $0.sourceFile })
        XCTAssertNotEqual(aTrain, bTrain)
    }

    // MARK: - Stratified split

    func test_split_isStratifiedByClass() throws {
        try writeClass("baby", clipCount: 10, windowsPerClip: 2)
        try writeClass("tears", clipCount: 6, windowsPerClip: 2)
        try writeClass("crabs", clipCount: 4, windowsPerClip: 2)
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 7
        )
        // floor(10*0.25)=2, floor(6*0.25)=1, floor(4*0.25)=1
        // → train clips: 8 + 5 + 3 = 16
        // → val clips: 2 + 1 + 1 = 4
        XCTAssertEqual(ds.trainingClipCount, 16)
        XCTAssertEqual(ds.validationClipCount, 4)
        // Each class is represented in both splits at non-zero counts.
        for cls in ["baby", "tears", "crabs"] {
            XCTAssertGreaterThan(ds.perClassTraining[cls] ?? 0, 0,
                                 "training is missing class \(cls)")
            XCTAssertGreaterThan(ds.perClassValidation[cls] ?? 0, 0,
                                 "validation is missing class \(cls)")
        }
    }

    // MARK: - Group-aware split (no clip leakage)

    func test_split_keepsSourceClipsInOneSplit() throws {
        try writeClass("baby", clipCount: 8, windowsPerClip: 4)
        try writeClass("tears", clipCount: 8, windowsPerClip: 4)
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 99
        )
        let trainClips = Set(ds.trainingWindows.map { $0.sourceFile })
        let valClips = Set(ds.validationWindows.map { $0.sourceFile })
        XCTAssertTrue(trainClips.isDisjoint(with: valClips),
                      "source-clip leakage between train and validation")
    }

    // MARK: - Imbalance + balancing

    func test_imbalanceRatio_reportedWhenClassesUneven() throws {
        try writeClass("baby", clipCount: 8, windowsPerClip: 5)   // 40 windows total
        try writeClass("tears", clipCount: 8, windowsPerClip: 2)  // 16 windows total
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir, validationFraction: 0.25, seed: 1
        )
        // Without balancing, training imbalance carries through.
        XCTAssertGreaterThan(ds.imbalanceRatio, 1.0)
        XCTAssertFalse(ds.balancedTrainingApplied)
    }

    func test_balancing_downsamplesTrainingToSmallestClipCount() throws {
        try writeClass("baby", clipCount: 8, windowsPerClip: 3)
        try writeClass("tears", clipCount: 4, windowsPerClip: 3)
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir,
            validationFraction: 0.25,
            seed: 1,
            balanceTrainingClasses: true
        )
        XCTAssertTrue(ds.balancedTrainingApplied)
        // floor(8*0.25)=2 val clips for baby, leaving 6 train clips.
        // floor(4*0.25)=1 val clip for tears, leaving 3 train clips.
        // Balancing downsamples baby's training to 3 clips → equal training
        // clip counts per class; per-class training-window count is equal.
        let babyWindows = ds.perClassTraining["baby"] ?? 0
        let tearsWindows = ds.perClassTraining["tears"] ?? 0
        XCTAssertEqual(babyWindows, tearsWindows)
        // Validation untouched (3 windows/clip × val clips).
        XCTAssertEqual(ds.perClassValidation["baby"], 6)
        XCTAssertEqual(ds.perClassValidation["tears"], 3)
    }

    func test_balancing_isNoopWhenAlreadyBalanced() throws {
        try writeClass("baby", clipCount: 6, windowsPerClip: 4)
        try writeClass("tears", clipCount: 6, windowsPerClip: 4)
        let ds = try ActionWindowDatasetLoader().load(
            windowsDir: tempDir,
            validationFraction: 0.25,
            seed: 1,
            balanceTrainingClasses: true
        )
        XCTAssertFalse(ds.balancedTrainingApplied,
                       "balancing should be a no-op when classes already match")
    }

    // MARK: - Determinism shuffle

    func test_deterministicShuffle_matchesAcrossInstances() {
        let input = Array(0..<20)
        var rngA = SplitMix64(seed: 7)
        var rngB = SplitMix64(seed: 7)
        let a = deterministicShuffled(input, using: &rngA)
        let b = deterministicShuffled(input, using: &rngB)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a), Set(input))  // permutation, no loss / no dup
    }

    func test_stableHash_isStableForSameString() {
        XCTAssertEqual(stableHash(of: "baby"), stableHash(of: "baby"))
        XCTAssertNotEqual(stableHash(of: "baby"), stableHash(of: "tears"))
    }
}
