//
//  SoundClassifierTrainer.swift
//  SoundTrainer
//
//  Validates a Create ML-shaped audio dataset and (optionally) trains an
//  MLSoundClassifier from it. Validation is platform-agnostic; training is
//  macOS-only because CreateML is macOS-only.
//
//  Validation is exposed independently so it can be unit-tested without
//  invoking CreateML or producing a real model.
//

import Foundation
import ScratchLabML

// MARK: - Public API (cross-platform)

public struct SoundDatasetValidationResult: Sendable, Equatable {
    public let labels: [ScratchClassLabel]
    public let perLabelCount: [ScratchClassLabel: Int]

    public init(labels: [ScratchClassLabel], perLabelCount: [ScratchClassLabel: Int]) {
        self.labels = labels
        self.perLabelCount = perLabelCount
    }
}

public enum SoundTrainerError: Error, Equatable {
    case datasetNotFound(path: String)
    case datasetNotADirectory(path: String)
    case noClassFolders(path: String)
    case unknownClassLabel(folderName: String)
    case classBelowMinimum(label: String, count: Int, minimum: Int)
    case trainingUnavailableOnPlatform
    case trainingFailed(underlying: String)
}

public struct SoundClassifierTrainer: Sendable {

    public init() {}

    /// Walk the dataset directory, verify every subfolder name maps to a
    /// `ScratchClassLabel`, and confirm each class has at least
    /// `minimumSamplesPerClass` audio files. Throws on the first violation.
    public func validateDataset(
        at url: URL,
        minimumSamplesPerClass: Int = 3,
        fileManager: FileManager = .default
    ) throws -> SoundDatasetValidationResult {

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SoundTrainerError.datasetNotFound(path: url.path)
        }
        guard isDir.boolValue else {
            throw SoundTrainerError.datasetNotADirectory(path: url.path)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SoundTrainerError.datasetNotFound(path: url.path)
        }

        let classFolders = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !classFolders.isEmpty else {
            throw SoundTrainerError.noClassFolders(path: url.path)
        }

        var labels: [ScratchClassLabel] = []
        var counts: [ScratchClassLabel: Int] = [:]

        for folder in classFolders {
            let name = folder.lastPathComponent
            guard let label = ScratchClassLabel(modelLabel: name) else {
                throw SoundTrainerError.unknownClassLabel(folderName: name)
            }
            let count = countAudioFiles(in: folder, fileManager: fileManager)
            if count < minimumSamplesPerClass {
                throw SoundTrainerError.classBelowMinimum(
                    label: label.rawValue,
                    count: count,
                    minimum: minimumSamplesPerClass
                )
            }
            labels.append(label)
            counts[label] = count
        }

        return SoundDatasetValidationResult(labels: labels, perLabelCount: counts)
    }

    private func countAudioFiles(in folder: URL, fileManager: FileManager) -> Int {
        let allowed: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
        guard let items = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return items.filter { allowed.contains($0.pathExtension.lowercased()) }.count
    }
}

// MARK: - Training (macOS only)

#if os(macOS)
import CreateML

extension SoundClassifierTrainer {

    public struct TrainingConfiguration {
        public var datasetURL: URL
        public var outputDirectory: URL
        public var modelFilename: String
        public var minimumSamplesPerClass: Int

        public init(
            datasetURL: URL,
            outputDirectory: URL,
            modelFilename: String = "ScratchSoundClassifier",
            minimumSamplesPerClass: Int = 3
        ) {
            self.datasetURL = datasetURL
            self.outputDirectory = outputDirectory
            self.modelFilename = modelFilename
            self.minimumSamplesPerClass = minimumSamplesPerClass
        }
    }

    /// Validate, train, and write `<modelFilename>.mlmodel` into the output
    /// directory. Returns the URL of the written model. Slow — invoke from a
    /// CLI or background context, never from a unit test.
    public func train(_ config: TrainingConfiguration) throws -> URL {
        _ = try validateDataset(
            at: config.datasetURL,
            minimumSamplesPerClass: config.minimumSamplesPerClass
        )

        let trainingData = MLSoundClassifier.DataSource.labeledDirectories(at: config.datasetURL)
        let classifier: MLSoundClassifier
        do {
            classifier = try MLSoundClassifier(trainingData: trainingData)
        } catch {
            throw SoundTrainerError.trainingFailed(underlying: error.localizedDescription)
        }

        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )
        let modelURL = config.outputDirectory.appendingPathComponent("\(config.modelFilename).mlmodel")

        // Empty metadata — no author, license, version, or any provenance info
        // is written into the .mlmodel.
        let metadata = MLModelMetadata()
        do {
            try classifier.write(to: modelURL, metadata: metadata)
        } catch {
            throw SoundTrainerError.trainingFailed(underlying: error.localizedDescription)
        }
        return modelURL
    }
}
#else
extension SoundClassifierTrainer {
    public func train(_ config: Any) throws -> URL {
        throw SoundTrainerError.trainingUnavailableOnPlatform
    }
}
#endif
