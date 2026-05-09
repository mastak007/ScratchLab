//
//  ActionDatasetValidator.swift
//  MotionTrainer
//
//  Walks an action-classifier dataset directory and verifies every subfolder
//  is a known `ScratchClassLabel` with at least the configured minimum
//  number of `.mp4` clips. Mirrors `SoundClassifierTrainer.validateDataset`
//  in error shape and report style so both pipelines feel the same.
//
//  Pure Foundation — no Vision, no AVFoundation. Cheap to call from a unit
//  test or from the CLI's `--validate-only` mode.
//

import Foundation
import ScratchLabML

// MARK: - Public API

public struct ActionDatasetValidationResult: Sendable, Equatable {
    public let labels: [ScratchClassLabel]
    public let perLabelCount: [ScratchClassLabel: Int]

    public init(labels: [ScratchClassLabel], perLabelCount: [ScratchClassLabel: Int]) {
        self.labels = labels
        self.perLabelCount = perLabelCount
    }
}

public enum MotionTrainerError: Error, Equatable {
    case datasetNotFound(path: String)
    case datasetNotADirectory(path: String)
    case noClassFolders(path: String)
    case unknownClassLabel(folderName: String)
    case classBelowMinimum(label: String, count: Int, minimum: Int)
    case clipUnreadable(path: String, underlying: String)
    case extractionFailed(path: String, underlying: String)
}

public struct ActionDatasetValidator: Sendable {

    public init() {}

    /// Walk the dataset directory, verify every subfolder name maps to a
    /// `ScratchClassLabel`, and confirm each class has at least
    /// `minimumSamplesPerClass` `.mp4` files. Throws on the first violation.
    public func validateDataset(
        at url: URL,
        minimumSamplesPerClass: Int = 12,
        fileManager: FileManager = .default
    ) throws -> ActionDatasetValidationResult {

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw MotionTrainerError.datasetNotFound(path: url.path)
        }
        guard isDir.boolValue else {
            throw MotionTrainerError.datasetNotADirectory(path: url.path)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MotionTrainerError.datasetNotFound(path: url.path)
        }

        let classFolders = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !classFolders.isEmpty else {
            throw MotionTrainerError.noClassFolders(path: url.path)
        }

        var labels: [ScratchClassLabel] = []
        var counts: [ScratchClassLabel: Int] = [:]

        for folder in classFolders {
            let name = folder.lastPathComponent
            guard let label = ScratchClassLabel(modelLabel: name) else {
                throw MotionTrainerError.unknownClassLabel(folderName: name)
            }
            let count = countVideoFiles(in: folder, fileManager: fileManager)
            if count < minimumSamplesPerClass {
                throw MotionTrainerError.classBelowMinimum(
                    label: label.rawValue,
                    count: count,
                    minimum: minimumSamplesPerClass
                )
            }
            labels.append(label)
            counts[label] = count
        }

        return ActionDatasetValidationResult(labels: labels, perLabelCount: counts)
    }

    /// List every `.mp4` clip in a class folder, sorted by filename.
    /// Used by the CLI to drive feature extraction.
    public func clips(
        in folder: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Private

    private func countVideoFiles(in folder: URL, fileManager: FileManager) -> Int {
        return clips(in: folder, fileManager: fileManager).count
    }
}
