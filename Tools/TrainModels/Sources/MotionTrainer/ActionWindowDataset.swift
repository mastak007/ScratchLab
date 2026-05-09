//
//  ActionWindowDataset.swift
//  MotionTrainer
//
//  Slice C dataset preparation. Loads the Slice B `MotionFeatureWindow`
//  JSONL output, splits it into train/validation deterministically, and
//  exposes per-class counts and the imbalance ratio so the trainer (and
//  the CLI) can report clearly without surprising the caller.
//
//  Pure Foundation only — no CreateML import here. The trainer in
//  `ScratchActionClassifierTrainer.swift` consumes this dataset and is the
//  one gated behind `#if os(macOS)`.
//
//  Split semantics (deterministic, stratified, group-aware):
//      1. Walk `<windowsDir>/<class>/*.windows.jsonl` and decode every
//         line as a `MotionFeatureWindow`.
//      2. Group windows by source clip (`MotionFeatureWindow.sourceFile`).
//         All windows from one clip go to the same split — no leakage.
//      3. Within each class, sort source clips by name (deterministic),
//         deterministically shuffle them with a SplitMix64 RNG seeded by
//         `seed`, and take `floor(count * validationFraction)` clips for
//         validation.
//      4. The remaining clips form the training set.
//      5. Optionally `balanceTrainingClasses` downsamples training clips
//         per class to the smallest training class — preserves the full
//         validation set so reported metrics stay representative.
//

import Foundation
import ScratchLabML

// MARK: - Public types

/// One window as loaded from disk, plus its synthesised session ID for
/// downstream training (CreateML's MLActivityClassifier wants a session
/// column distinct from the label column).
public struct LoadedActionWindow: Sendable, Equatable {
    public let classLabel: String
    public let sourceFile: String
    public let windowIndex: Int
    public let sessionID: String
    public let frames: [MotionFrameFeatures]
    public let aggregates: MotionWindowAggregates

    public init(
        classLabel: String,
        sourceFile: String,
        windowIndex: Int,
        sessionID: String,
        frames: [MotionFrameFeatures],
        aggregates: MotionWindowAggregates
    ) {
        self.classLabel = classLabel
        self.sourceFile = sourceFile
        self.windowIndex = windowIndex
        self.sessionID = sessionID
        self.frames = frames
        self.aggregates = aggregates
    }
}

public struct ActionWindowDataset: Sendable {
    public let allWindows: [LoadedActionWindow]
    public let trainingWindows: [LoadedActionWindow]
    public let validationWindows: [LoadedActionWindow]

    public let perClassTotal: [String: Int]
    public let perClassTraining: [String: Int]
    public let perClassValidation: [String: Int]

    public let trainingClipCount: Int
    public let validationClipCount: Int

    public let validationFraction: Double
    public let seed: UInt64
    public let balancedTrainingApplied: Bool

    /// max(per-class training count) / max(1, min(per-class training count)).
    /// Reported so the CLI can print imbalance prominently rather than
    /// silently glossing over it.
    public let imbalanceRatio: Double

    public init(
        allWindows: [LoadedActionWindow],
        trainingWindows: [LoadedActionWindow],
        validationWindows: [LoadedActionWindow],
        perClassTotal: [String: Int],
        perClassTraining: [String: Int],
        perClassValidation: [String: Int],
        trainingClipCount: Int,
        validationClipCount: Int,
        validationFraction: Double,
        seed: UInt64,
        balancedTrainingApplied: Bool,
        imbalanceRatio: Double
    ) {
        self.allWindows = allWindows
        self.trainingWindows = trainingWindows
        self.validationWindows = validationWindows
        self.perClassTotal = perClassTotal
        self.perClassTraining = perClassTraining
        self.perClassValidation = perClassValidation
        self.trainingClipCount = trainingClipCount
        self.validationClipCount = validationClipCount
        self.validationFraction = validationFraction
        self.seed = seed
        self.balancedTrainingApplied = balancedTrainingApplied
        self.imbalanceRatio = imbalanceRatio
    }
}

public enum ActionWindowDatasetError: Error, Equatable {
    case windowsDirectoryNotFound(path: String)
    case windowsDirectoryNotADirectory(path: String)
    case noWindowsFound(path: String)
    case malformedWindowFile(path: String, underlying: String)
    case invalidValidationFraction(value: Double)
}

// MARK: - Loader / splitter

public struct ActionWindowDatasetLoader: Sendable {

    public init() {}

    /// Walk `windowsDir`, decode every `.windows.jsonl`, and return a
    /// fully-prepared dataset. Throws `noWindowsFound` if no .windows.jsonl
    /// files are present anywhere under the directory.
    public func load(
        windowsDir: URL,
        validationFraction: Double = 0.2,
        seed: UInt64 = 1337,
        balanceTrainingClasses: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ActionWindowDataset {

        guard validationFraction >= 0 && validationFraction <= 0.5 else {
            throw ActionWindowDatasetError.invalidValidationFraction(value: validationFraction)
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: windowsDir.path, isDirectory: &isDir) else {
            throw ActionWindowDatasetError.windowsDirectoryNotFound(path: windowsDir.path)
        }
        guard isDir.boolValue else {
            throw ActionWindowDatasetError.windowsDirectoryNotADirectory(path: windowsDir.path)
        }

        let allWindows = try loadAllWindows(under: windowsDir, fileManager: fileManager)
        guard !allWindows.isEmpty else {
            throw ActionWindowDatasetError.noWindowsFound(path: windowsDir.path)
        }

        // Group by class -> source clip -> windows
        var clipsByClass: [String: [String: [LoadedActionWindow]]] = [:]
        for w in allWindows {
            clipsByClass[w.classLabel, default: [:]][w.sourceFile, default: []].append(w)
        }

        var trainingWindows: [LoadedActionWindow] = []
        var validationWindows: [LoadedActionWindow] = []
        var trainingClipCount = 0
        var validationClipCount = 0

        // Per-class group split. Sort everything for determinism, then
        // shuffle with a seeded RNG so the split is identical across runs
        // with the same `seed`.
        for cls in clipsByClass.keys.sorted() {
            let clipMap = clipsByClass[cls] ?? [:]
            let sortedClipNames = clipMap.keys.sorted()
            var rng = SplitMix64(seed: seed &+ stableHash(of: cls))
            let shuffledClipNames = deterministicShuffled(sortedClipNames, using: &rng)
            let validationCount = Int((Double(shuffledClipNames.count) * validationFraction)
                .rounded(.down))
            let validationClips = Array(shuffledClipNames.prefix(validationCount))
            let trainingClips = Array(shuffledClipNames.dropFirst(validationCount))
            validationClipCount += validationClips.count
            trainingClipCount += trainingClips.count
            for clip in validationClips {
                validationWindows.append(contentsOf: clipMap[clip] ?? [])
            }
            for clip in trainingClips {
                trainingWindows.append(contentsOf: clipMap[clip] ?? [])
            }
        }

        // Sort training/validation by sessionID so downstream MLDataTable
        // construction is deterministic too.
        trainingWindows.sort { $0.sessionID < $1.sessionID }
        validationWindows.sort { $0.sessionID < $1.sessionID }

        // Optional class balancing — applied to training only. Validation
        // is left untouched so reported per-class accuracy reflects the
        // real distribution.
        var balancedApplied = false
        if balanceTrainingClasses {
            let (balanced, didChange) = balanceTraining(
                trainingWindows,
                seed: seed
            )
            trainingWindows = balanced
            balancedApplied = didChange
        }

        // Counts
        var perClassTotal: [String: Int] = [:]
        var perClassTraining: [String: Int] = [:]
        var perClassValidation: [String: Int] = [:]
        for w in allWindows {
            perClassTotal[w.classLabel, default: 0] += 1
        }
        for w in trainingWindows {
            perClassTraining[w.classLabel, default: 0] += 1
        }
        for w in validationWindows {
            perClassValidation[w.classLabel, default: 0] += 1
        }

        let trainCounts = perClassTraining.values
        let imbalance: Double
        if let lo = trainCounts.min(), let hi = trainCounts.max(), lo > 0 {
            imbalance = Double(hi) / Double(lo)
        } else {
            imbalance = 0
        }

        return ActionWindowDataset(
            allWindows: allWindows,
            trainingWindows: trainingWindows,
            validationWindows: validationWindows,
            perClassTotal: perClassTotal,
            perClassTraining: perClassTraining,
            perClassValidation: perClassValidation,
            trainingClipCount: trainingClipCount,
            validationClipCount: validationClipCount,
            validationFraction: validationFraction,
            seed: seed,
            balancedTrainingApplied: balancedApplied,
            imbalanceRatio: imbalance
        )
    }

    // MARK: - Loading

    private func loadAllWindows(
        under root: URL,
        fileManager: FileManager
    ) throws -> [LoadedActionWindow] {

        // Class folders, sorted.
        let classFolders: [URL]
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            classFolders = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw ActionWindowDatasetError.windowsDirectoryNotFound(path: root.path)
        }

        let decoder = JSONDecoder()
        var loaded: [LoadedActionWindow] = []
        for folder in classFolders {
            let files = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let jsonl = files
                .filter { $0.lastPathComponent.hasSuffix(".windows.jsonl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in jsonl {
                let text: String
                do {
                    let data = try Data(contentsOf: file)
                    text = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    throw ActionWindowDatasetError.malformedWindowFile(
                        path: "\(folder.lastPathComponent)/\(file.lastPathComponent)",
                        underlying: error.localizedDescription
                    )
                }
                for (lineIdx, line) in text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .enumerated() {
                    let lineData = Data(line.utf8)
                    let window: MotionFeatureWindow
                    do {
                        window = try decoder.decode(MotionFeatureWindow.self, from: lineData)
                    } catch {
                        throw ActionWindowDatasetError.malformedWindowFile(
                            path: "\(folder.lastPathComponent)/\(file.lastPathComponent)",
                            underlying: "line \(lineIdx + 1): \(error.localizedDescription)"
                        )
                    }
                    let sessionID = "\(window.classLabel)/\(window.sourceFile)/\(window.windowIndex)"
                    loaded.append(LoadedActionWindow(
                        classLabel: window.classLabel,
                        sourceFile: window.sourceFile,
                        windowIndex: window.windowIndex,
                        sessionID: sessionID,
                        frames: window.frames,
                        aggregates: window.aggregates
                    ))
                }
            }
        }
        return loaded
    }

    // MARK: - Balancing

    private func balanceTraining(
        _ windows: [LoadedActionWindow],
        seed: UInt64
    ) -> (windows: [LoadedActionWindow], changed: Bool) {
        var clipsByClass: [String: [String: [LoadedActionWindow]]] = [:]
        for w in windows {
            clipsByClass[w.classLabel, default: [:]][w.sourceFile, default: []].append(w)
        }
        let perClassClipCount = clipsByClass.mapValues { $0.count }
        guard let minClipCount = perClassClipCount.values.min() else {
            return (windows, false)
        }
        let alreadyBalanced = perClassClipCount.values.allSatisfy { $0 == minClipCount }
        if alreadyBalanced {
            return (windows, false)
        }
        var balanced: [LoadedActionWindow] = []
        for cls in clipsByClass.keys.sorted() {
            let clips = clipsByClass[cls] ?? [:]
            let names = clips.keys.sorted()
            var rng = SplitMix64(seed: seed &+ 0x9999 &+ stableHash(of: cls))
            let shuffled = deterministicShuffled(names, using: &rng)
            let kept = shuffled.prefix(minClipCount)
            for clip in kept {
                balanced.append(contentsOf: clips[clip] ?? [])
            }
        }
        balanced.sort { $0.sessionID < $1.sessionID }
        return (balanced, true)
    }
}

// MARK: - Determinism helpers

/// Tiny SplitMix64 RNG. Deterministic given a seed. Used for
/// `array.shuffle(using:)` so train/val splits are reproducible across
/// runs (and therefore across machines and CI).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed != 0 ? seed : 0xDEAD_BEEF_CAFE_BABE
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

/// Stable, platform-independent hash of a string. `Hasher` is fine for
/// in-memory dictionaries but its output is randomised per process —
/// useless for "same seed gives same split everywhere". This FNV-1a
/// variant gives us a deterministic 64-bit value across processes.
func stableHash(of string: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV offset basis
    for byte in string.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x100_0000_01B3        // FNV prime
    }
    return h
}

/// Fisher-Yates shuffle driven by `rng`. Equivalent to
/// `Array.shuffled(using:)` but spelled out so the algorithm is
/// guaranteed identical across Swift toolchain versions.
func deterministicShuffled<T>(_ array: [T], using rng: inout SplitMix64) -> [T] {
    var out = array
    if out.count < 2 { return out }
    for i in (1..<out.count).reversed() {
        let upper = UInt64(i + 1)
        let r = rng.next() % upper
        out.swapAt(i, Int(r))
    }
    return out
}
