//
//  ScratchActionClassifierTrainer.swift
//  MotionTrainer
//
//  Slice C trainer. Consumes the `ActionWindowDataset` (loaded from the
//  Slice B JSONL window output) and trains a CreateML
//  `MLActivityClassifier`. Writes:
//
//      <output-dir>/ScratchActionClassifier.mlmodel
//      <output-dir>/ScratchActionClassifier.training-report.json
//
//  CreateML is macOS-only, so the trainer's `train(...)` method lives in a
//  `#if os(macOS)` extension. The cross-platform half (configuration, the
//  Codable report types, errors) is always compiled so unit tests can
//  cover everything that doesn't actually invoke CreateML.
//
//  Mirrors the shape of `SoundClassifierTrainer` deliberately: same
//  `TrainingConfiguration` nesting, same sanitised `MLModelMetadata` to
//  keep author / license / NSFullUserName from leaking into the .mlmodel.
//
//  Class imbalance handling
//  ------------------------
//  `MLActivityClassifier` does not expose a `class_weight` parameter. We
//  therefore handle imbalance one of two ways, controlled by
//  `TrainingConfiguration.balanceTrainingClasses`:
//
//      - false (default): train unweighted, but surface the imbalance
//        ratio prominently in the training report. Nothing is silently
//        dropped, so per-class metrics still reflect the real
//        distribution.
//      - true: deterministically downsample TRAINING clips per class to
//        the smallest class's clip count. Validation is left untouched.
//

import Foundation
import ScratchLabML

// MARK: - Public configuration

public struct ScratchActionClassifierTrainer: Sendable {
    public init() {}
}

extension ScratchActionClassifierTrainer {

    public struct TrainingConfiguration: Sendable {
        public var windowsDirectory: URL
        public var outputDirectory: URL
        public var modelFilename: String
        public var validationFraction: Double
        public var seed: UInt64
        public var balanceTrainingClasses: Bool
        public var maximumIterations: Int
        public var predictionWindowSize: Int

        public init(
            windowsDirectory: URL,
            outputDirectory: URL,
            modelFilename: String = "ScratchActionClassifier",
            validationFraction: Double = 0.2,
            seed: UInt64 = 1337,
            balanceTrainingClasses: Bool = false,
            maximumIterations: Int = 50,
            predictionWindowSize: Int = 60
        ) {
            self.windowsDirectory = windowsDirectory
            self.outputDirectory = outputDirectory
            self.modelFilename = modelFilename
            self.validationFraction = validationFraction
            self.seed = seed
            self.balanceTrainingClasses = balanceTrainingClasses
            self.maximumIterations = maximumIterations
            self.predictionWindowSize = predictionWindowSize
        }
    }

    public enum TrainingError: Error, Equatable {
        case datasetLoadFailed(underlying: String)
        case trainingFailed(underlying: String)
        case writeFailed(path: String, underlying: String)
        case trainingUnavailableOnPlatform
    }
}

// MARK: - Codable report

/// Confusion matrix cell as written into the training report. Strings
/// keep this self-describing for readers who don't have the model on hand.
public struct ActionConfusionMatrixCell: Sendable, Codable, Equatable {
    public let actual: String
    public let predicted: String
    public let count: Int

    public init(actual: String, predicted: String, count: Int) {
        self.actual = actual
        self.predicted = predicted
        self.count = count
    }
}

/// Structured training report. Always written next to the .mlmodel as
/// `<modelFilename>.training-report.json`. Codable so the test suite can
/// round-trip without invoking CreateML.
public struct ActionTrainingReport: Sendable, Codable, Equatable {
    public let modelFilename: String
    public let trainerKind: String
    public let predictionWindowSize: Int
    public let maximumIterations: Int
    public let validationFraction: Double
    public let seed: UInt64
    public let balanceTrainingClassesRequested: Bool
    public let balanceTrainingClassesApplied: Bool

    public let totalWindowsLoaded: Int
    public let trainingWindowCount: Int
    public let validationWindowCount: Int
    public let trainingClipCount: Int
    public let validationClipCount: Int
    public let perClassTotal: [String: Int]
    public let perClassTraining: [String: Int]
    public let perClassValidation: [String: Int]
    public let imbalanceRatio: Double

    public let trainingAccuracy: Double?
    public let validationAccuracy: Double?
    public let trainingError: Double?
    public let validationError: Double?
    public let perClassValidationAccuracy: [String: Double]?
    public let confusion: [ActionConfusionMatrixCell]?
    public let weakestClasses: [String]
    public let weakClassThreshold: Double

    public let trainingDurationSeconds: Double
    public let modelOutputPath: String
    public let reportOutputPath: String

    public init(
        modelFilename: String,
        trainerKind: String,
        predictionWindowSize: Int,
        maximumIterations: Int,
        validationFraction: Double,
        seed: UInt64,
        balanceTrainingClassesRequested: Bool,
        balanceTrainingClassesApplied: Bool,
        totalWindowsLoaded: Int,
        trainingWindowCount: Int,
        validationWindowCount: Int,
        trainingClipCount: Int,
        validationClipCount: Int,
        perClassTotal: [String: Int],
        perClassTraining: [String: Int],
        perClassValidation: [String: Int],
        imbalanceRatio: Double,
        trainingAccuracy: Double?,
        validationAccuracy: Double?,
        trainingError: Double?,
        validationError: Double?,
        perClassValidationAccuracy: [String: Double]?,
        confusion: [ActionConfusionMatrixCell]?,
        weakestClasses: [String],
        weakClassThreshold: Double,
        trainingDurationSeconds: Double,
        modelOutputPath: String,
        reportOutputPath: String
    ) {
        self.modelFilename = modelFilename
        self.trainerKind = trainerKind
        self.predictionWindowSize = predictionWindowSize
        self.maximumIterations = maximumIterations
        self.validationFraction = validationFraction
        self.seed = seed
        self.balanceTrainingClassesRequested = balanceTrainingClassesRequested
        self.balanceTrainingClassesApplied = balanceTrainingClassesApplied
        self.totalWindowsLoaded = totalWindowsLoaded
        self.trainingWindowCount = trainingWindowCount
        self.validationWindowCount = validationWindowCount
        self.trainingClipCount = trainingClipCount
        self.validationClipCount = validationClipCount
        self.perClassTotal = perClassTotal
        self.perClassTraining = perClassTraining
        self.perClassValidation = perClassValidation
        self.imbalanceRatio = imbalanceRatio
        self.trainingAccuracy = trainingAccuracy
        self.validationAccuracy = validationAccuracy
        self.trainingError = trainingError
        self.validationError = validationError
        self.perClassValidationAccuracy = perClassValidationAccuracy
        self.confusion = confusion
        self.weakestClasses = weakestClasses
        self.weakClassThreshold = weakClassThreshold
        self.trainingDurationSeconds = trainingDurationSeconds
        self.modelOutputPath = modelOutputPath
        self.reportOutputPath = reportOutputPath
    }
}

/// What `train(...)` returns on success. The model and report files are
/// already written; these URLs let the CLI print them and tests assert on
/// them.
public struct ScratchActionClassifierTrainingArtifacts: Sendable, Equatable {
    public let modelURL: URL
    public let reportURL: URL
    public let report: ActionTrainingReport

    public init(modelURL: URL, reportURL: URL, report: ActionTrainingReport) {
        self.modelURL = modelURL
        self.reportURL = reportURL
        self.report = report
    }
}

// MARK: - Feature schema (cross-platform — used by the trainer for
//                      column naming, kept here so tests can verify it)

/// Per-window summary feature schema fed to CreateML.
///
/// We use a tabular classifier (`MLBoostedTreeClassifier`) on one-row-per-
/// window summary features rather than the time-series
/// `MLActivityClassifier`, because the per-frame sequence-per-cell shape
/// `MLActivityClassifier` expects in this CreateML version requires a
/// table layout that would force us to invent another intermediate
/// representation. The summary layer here captures enough motion
/// information (per-axis ranges, velocities, path lengths, hand-center
/// crossings, missingness) for a 23-way classifier without losing data
/// we care about.
///
/// Two families of features per window:
///   * `agg_*` — the nine `MotionWindowAggregates` already computed at
///     window-build time (Slice B).
///   * `<frameField>_<stat>` — mean / std / min / max over the per-frame
///     coordinate stream, plus `_rate` for presence flags.
///
/// `recordCenter` is intentionally excluded: the Slice A extractor does
/// not populate it yet, so its statistics would all be constants.
public enum ActionTrainerFeatures {

    /// Per-frame numeric coordinate fields summarised across the window.
    /// 12 coordinates + 1 confidence = 13 fields × 4 stats = 52 columns.
    public static let perFrameNumericFields: [String] = [
        "dominantHandX", "dominantHandY",
        "dominantHandWristX", "dominantHandWristY",
        "dominantHandIndexTipX", "dominantHandIndexTipY",
        "dominantHandThumbTipX", "dominantHandThumbTipY",
        "dominantHandMiddleTipX", "dominantHandMiddleTipY",
        "secondaryHandWristX", "secondaryHandWristY",
        "dominantHandConfidence",
    ]

    public static let summaryStatistics: [String] = ["mean", "std", "min", "max"]

    /// Per-frame Boolean presence flags. We summarise these as a rate in
    /// `[0, 1]` (the fraction of frames where the landmark was detected).
    public static let perFramePresenceFields: [String] = [
        "dominantHandPresent",
        "dominantHandWristPresent",
        "dominantHandIndexTipPresent",
        "dominantHandThumbTipPresent",
        "dominantHandMiddleTipPresent",
        "secondaryHandWristPresent",
    ]

    /// Names of the nine `MotionWindowAggregates` columns, prefixed with
    /// `agg_` to disambiguate from the summary stats.
    public static let aggregateFields: [String] = [
        "agg_dominantWristPathLength",
        "agg_dominantHandPathLength",
        "agg_romX",
        "agg_romY",
        "agg_meanVelocity",
        "agg_maxVelocity",
        "agg_centerLineCrossings",
        "agg_dominantHandMissingRatio",
        "agg_dominantHandWristMissingRatio",
    ]

    /// Full ordered list of feature column names. Order matters for the
    /// training table and for inference at runtime.
    public static let columns: [String] = {
        var out: [String] = []
        out.append(contentsOf: aggregateFields)
        for field in perFrameNumericFields {
            for stat in summaryStatistics {
                out.append("\(field)_\(stat)")
            }
        }
        for flag in perFramePresenceFields {
            out.append("\(flag)_rate")
        }
        return out
    }()

    /// Project one window into its `[columnName: Double]` row.
    public static func projectToRow(_ window: LoadedActionWindow) -> [String: Double] {
        var row: [String: Double] = [:]

        // Aggregates
        let agg = window.aggregates
        row["agg_dominantWristPathLength"] = agg.dominantWristPathLength
        row["agg_dominantHandPathLength"] = agg.dominantHandPathLength
        row["agg_romX"] = agg.romX
        row["agg_romY"] = agg.romY
        row["agg_meanVelocity"] = agg.meanVelocity
        row["agg_maxVelocity"] = agg.maxVelocity
        row["agg_centerLineCrossings"] = Double(agg.centerLineCrossings)
        row["agg_dominantHandMissingRatio"] = agg.dominantHandMissingRatio
        row["agg_dominantHandWristMissingRatio"] = agg.dominantHandWristMissingRatio

        // Per-frame numeric summaries
        let frames = window.frames
        let n = max(1, frames.count)
        for field in perFrameNumericFields {
            let values = frames.map { extractNumeric($0, field: field) }
            let (mean, std, lo, hi) = summaryOf(values: values, fallback: 0)
            row["\(field)_mean"] = mean
            row["\(field)_std"] = std
            row["\(field)_min"] = lo
            row["\(field)_max"] = hi
        }
        // Per-frame presence rates
        for flag in perFramePresenceFields {
            let count = frames.filter { extractPresence($0, flag: flag) }.count
            row["\(flag)_rate"] = Double(count) / Double(n)
        }
        return row
    }

    private static func summaryOf(
        values: [Double],
        fallback: Double
    ) -> (mean: Double, std: Double, min: Double, max: Double) {
        guard !values.isEmpty else { return (fallback, fallback, fallback, fallback) }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let std = variance.squareRoot()
        return (mean, std, values.min() ?? fallback, values.max() ?? fallback)
    }

    private static func extractNumeric(
        _ frame: MotionFrameFeatures,
        field: String
    ) -> Double {
        switch field {
        case "dominantHandX": return frame.dominantHandX
        case "dominantHandY": return frame.dominantHandY
        case "dominantHandWristX": return frame.dominantHandWristX
        case "dominantHandWristY": return frame.dominantHandWristY
        case "dominantHandIndexTipX": return frame.dominantHandIndexTipX
        case "dominantHandIndexTipY": return frame.dominantHandIndexTipY
        case "dominantHandThumbTipX": return frame.dominantHandThumbTipX
        case "dominantHandThumbTipY": return frame.dominantHandThumbTipY
        case "dominantHandMiddleTipX": return frame.dominantHandMiddleTipX
        case "dominantHandMiddleTipY": return frame.dominantHandMiddleTipY
        case "secondaryHandWristX": return frame.secondaryHandWristX
        case "secondaryHandWristY": return frame.secondaryHandWristY
        case "dominantHandConfidence": return frame.dominantHandConfidence
        default: return 0
        }
    }

    private static func extractPresence(
        _ frame: MotionFrameFeatures,
        flag: String
    ) -> Bool {
        switch flag {
        case "dominantHandPresent": return frame.dominantHandPresent
        case "dominantHandWristPresent": return frame.dominantHandWristPresent
        case "dominantHandIndexTipPresent": return frame.dominantHandIndexTipPresent
        case "dominantHandThumbTipPresent": return frame.dominantHandThumbTipPresent
        case "dominantHandMiddleTipPresent": return frame.dominantHandMiddleTipPresent
        case "secondaryHandWristPresent": return frame.secondaryHandWristPresent
        default: return false
        }
    }
}

// MARK: - Cross-platform unavailable stub

#if !os(macOS)
extension ScratchActionClassifierTrainer {
    public func train(
        _ config: TrainingConfiguration
    ) throws -> ScratchActionClassifierTrainingArtifacts {
        throw TrainingError.trainingUnavailableOnPlatform
    }
}
#endif

// MARK: - macOS training implementation

#if os(macOS)
import CreateML
import CoreML

extension ScratchActionClassifierTrainer {

    /// Train an MLActivityClassifier from the Slice B window cache and
    /// write `<modelFilename>.mlmodel` plus `<modelFilename>.training-report.json`
    /// into `outputDirectory`. Slow — invoke from a CLI, never from a test.
    public func train(
        _ config: TrainingConfiguration
    ) throws -> ScratchActionClassifierTrainingArtifacts {

        let started = Date()

        // 1. Load and split the windows. ActionWindowDatasetLoader handles
        //    deterministic stratified group splitting and (optionally)
        //    class balancing.
        let dataset: ActionWindowDataset
        do {
            dataset = try ActionWindowDatasetLoader().load(
                windowsDir: config.windowsDirectory,
                validationFraction: config.validationFraction,
                seed: config.seed,
                balanceTrainingClasses: config.balanceTrainingClasses
            )
        } catch {
            throw TrainingError.datasetLoadFailed(
                underlying: String(describing: error)
            )
        }

        // 2. Build train and validation MLDataTables. One row per window;
        //    feature columns are the per-window aggregates plus mean / std /
        //    min / max of every per-frame coordinate, plus presence rates.
        //    See `ActionTrainerFeatures` for the schema.
        let trainTable: MLDataTable
        let valTable: MLDataTable
        do {
            trainTable = try makeDataTable(from: dataset.trainingWindows)
            valTable = try makeDataTable(from: dataset.validationWindows)
        } catch {
            throw TrainingError.datasetLoadFailed(
                underlying: "could not build MLDataTable: \(error.localizedDescription)"
            )
        }

        // 3. Train an MLBoostedTreeClassifier. Tabular classifiers are
        //    well-supported in current CreateML and avoid the API churn
        //    around `MLActivityClassifier` in macOS 14. The per-window
        //    summary representation keeps motion energy / range / center-
        //    line crossings intact while presenting CreateML with the
        //    one-row-per-example shape it expects.
        var modelParameters = MLBoostedTreeClassifier.ModelParameters(
            validation: .table(valTable),
            maxDepth: 6,
            maxIterations: config.maximumIterations
        )
        modelParameters.randomSeed = Int(truncatingIfNeeded: dataset.seed)
        let classifier: MLBoostedTreeClassifier
        do {
            classifier = try MLBoostedTreeClassifier(
                trainingData: trainTable,
                targetColumn: "label",
                featureColumns: ActionTrainerFeatures.columns,
                parameters: modelParameters
            )
        } catch {
            throw TrainingError.trainingFailed(
                underlying: error.localizedDescription
            )
        }

        // 4. Evaluate against the validation table.
        let evaluation = classifier.evaluation(on: valTable)

        let trainingError = classifier.trainingMetrics.classificationError
        let validationError = classifier.validationMetrics.classificationError
        let trainingAccuracy = max(0.0, min(1.0, 1.0 - trainingError))
        let validationAccuracy = max(0.0, min(1.0, 1.0 - validationError))

        let confusionCells = confusionMatrixCells(
            from: evaluation.confusion
        )
        let perClassValidationAccuracy = perClassAccuracy(from: confusionCells)
        let weakClassThreshold: Double = 0.7
        let weakest = perClassValidationAccuracy
            .filter { $0.value < weakClassThreshold }
            .sorted { $0.value < $1.value }
            .map { $0.key }

        // 5. Write the model.
        do {
            try FileManager.default.createDirectory(
                at: config.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw TrainingError.writeFailed(
                path: config.outputDirectory.path,
                underlying: error.localizedDescription
            )
        }
        let modelURL = config.outputDirectory.appendingPathComponent(
            "\(config.modelFilename).mlmodel"
        )
        let metadata = MLModelMetadata(
            author: "ScratchLab",
            shortDescription: "ScratchLab scratch technique action classifier"
                + " (Vision hand-pose per-window summary features,"
                + " MLBoostedTreeClassifier).",
            license: nil,
            version: "1.0",
            additional: [:]
        )
        do {
            try classifier.write(to: modelURL, metadata: metadata)
        } catch {
            throw TrainingError.writeFailed(
                path: modelURL.path,
                underlying: error.localizedDescription
            )
        }

        // 6. Write the report alongside the model.
        let reportURL = config.outputDirectory.appendingPathComponent(
            "\(config.modelFilename).training-report.json"
        )
        let report = ActionTrainingReport(
            modelFilename: config.modelFilename,
            trainerKind: "MLBoostedTreeClassifier (per-window summary features)",
            predictionWindowSize: config.predictionWindowSize,
            maximumIterations: config.maximumIterations,
            validationFraction: dataset.validationFraction,
            seed: dataset.seed,
            balanceTrainingClassesRequested: config.balanceTrainingClasses,
            balanceTrainingClassesApplied: dataset.balancedTrainingApplied,
            totalWindowsLoaded: dataset.allWindows.count,
            trainingWindowCount: dataset.trainingWindows.count,
            validationWindowCount: dataset.validationWindows.count,
            trainingClipCount: dataset.trainingClipCount,
            validationClipCount: dataset.validationClipCount,
            perClassTotal: dataset.perClassTotal,
            perClassTraining: dataset.perClassTraining,
            perClassValidation: dataset.perClassValidation,
            imbalanceRatio: dataset.imbalanceRatio,
            trainingAccuracy: trainingAccuracy,
            validationAccuracy: validationAccuracy,
            trainingError: trainingError,
            validationError: validationError,
            perClassValidationAccuracy: perClassValidationAccuracy.isEmpty
                ? nil : perClassValidationAccuracy,
            confusion: confusionCells.isEmpty ? nil : confusionCells,
            weakestClasses: weakest,
            weakClassThreshold: weakClassThreshold,
            trainingDurationSeconds: Date().timeIntervalSince(started),
            modelOutputPath: modelURL.path,
            reportOutputPath: reportURL.path
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: Data.WritingOptions.atomic)
        } catch {
            throw TrainingError.writeFailed(
                path: reportURL.path,
                underlying: error.localizedDescription
            )
        }

        return ScratchActionClassifierTrainingArtifacts(
            modelURL: modelURL,
            reportURL: reportURL,
            report: report
        )
    }

    // MARK: - DataTable construction

    /// Build a one-row-per-window `MLDataTable`. Each row carries the
    /// projected summary feature vector (see
    /// `ActionTrainerFeatures.projectToRow`) plus a `label` column.
    private func makeDataTable(
        from windows: [LoadedActionWindow]
    ) throws -> MLDataTable {
        var labels: [String] = []
        labels.reserveCapacity(windows.count)
        var columns: [String: [Double]] = [:]
        for col in ActionTrainerFeatures.columns {
            columns[col] = []
            columns[col]?.reserveCapacity(windows.count)
        }

        for w in windows {
            labels.append(w.classLabel)
            let row = ActionTrainerFeatures.projectToRow(w)
            for col in ActionTrainerFeatures.columns {
                columns[col]?.append(row[col] ?? 0)
            }
        }

        var dict: [String: MLDataValueConvertible] = ["label": labels]
        for col in ActionTrainerFeatures.columns {
            dict[col] = columns[col] ?? []
        }
        return try MLDataTable(dictionary: dict)
    }

    // MARK: - Confusion matrix decoding

    /// Walk the confusion `MLDataTable` produced by `evaluation.confusion`
    /// and project it into our `ActionConfusionMatrixCell` shape so we can
    /// embed it in the JSON report. The column names CreateML uses on the
    /// confusion table have varied across SDK releases, so we accept the
    /// common spellings.
    private func confusionMatrixCells(
        from table: MLDataTable
    ) -> [ActionConfusionMatrixCell] {
        // Apple has shipped at least three different column-name spellings
        // for the confusion table over CreateML's life (each tier of the
        // classifier hierarchy normalises differently). We accept the
        // common ones and fall back to printing the observed names on
        // stderr so the next mismatch is easy to triage rather than
        // resulting in a silent empty `confusion: null` in the report.
        let columnNames = Set(table.columnNames)
        let actualColumn = [
            "True Label", "True Class", "Actual Class", "TrueLabel", "actual",
        ].first(where: { columnNames.contains($0) })
        let predictedColumn = [
            "Predicted", "Predicted Class", "Prediction", "predicted",
        ].first(where: { columnNames.contains($0) })
        let countColumn = [
            "Count", "count", "Number",
        ].first(where: { columnNames.contains($0) })

        guard let actualCol = actualColumn,
              let predictedCol = predictedColumn,
              let countCol = countColumn else {
            FileHandle.standardError.write(Data((
                "warning: confusion matrix column names not recognised; "
                + "have \(table.columnNames). Per-class metrics will be "
                + "absent from the training report.\n"
            ).utf8))
            return []
        }
        var cells: [ActionConfusionMatrixCell] = []
        for row in table.rows {
            let actual = row[actualCol]?.stringValue ?? ""
            let predicted = row[predictedCol]?.stringValue ?? ""
            let count = row[countCol]?.intValue ?? 0
            if actual.isEmpty || predicted.isEmpty { continue }
            cells.append(ActionConfusionMatrixCell(
                actual: actual,
                predicted: predicted,
                count: count
            ))
        }
        return cells.sorted {
            ($0.actual, $0.predicted) < ($1.actual, $1.predicted)
        }
    }

    private func perClassAccuracy(
        from confusion: [ActionConfusionMatrixCell]
    ) -> [String: Double] {
        var totalByActual: [String: Int] = [:]
        var correctByActual: [String: Int] = [:]
        for cell in confusion {
            totalByActual[cell.actual, default: 0] += cell.count
            if cell.actual == cell.predicted {
                correctByActual[cell.actual, default: 0] += cell.count
            }
        }
        var out: [String: Double] = [:]
        for (cls, total) in totalByActual where total > 0 {
            out[cls] = Double(correctByActual[cls] ?? 0) / Double(total)
        }
        return out
    }
}

#endif
