//
//  ScratchActionClassifierEvaluator.swift
//  MotionTrainer
//
//  Slice D evaluator. Loads a trained `ScratchActionClassifier.mlmodel`,
//  runs predictions over the per-window summary feature vectors that
//  Slice C wrote, and produces a structured evaluation report:
//
//      <output-dir>/ScratchActionClassifier.evaluation-report.json
//      <output-dir>/ScratchActionClassifier.confusion-matrix.csv
//
//  CoreML prediction is macOS-only, so the file splits into two halves:
//
//      - Cross-platform: report types (Codable), `ActionEvaluationCalculator`
//        for the pure metrics math (precision / recall / F1, confusion
//        matrix, weak classes, recommendation logic), and the leakage
//        warning helpers. All of this is testable without invoking
//        CoreML.
//      - `#if os(macOS)`: model compile/load, per-window prediction loop,
//        leakage check against an optional Slice C training report, file
//        writing.
//
//  The evaluator deliberately reuses `ActionTrainerFeatures.projectToRow`
//  from Slice C — the feature schema (column names + projection) is the
//  one source of truth across training and evaluation, so they can never
//  drift out of sync.
//

import Foundation
import ScratchLabML

// MARK: - Public report types

public struct ActionPerClassMetrics: Sendable, Codable, Equatable {
    public let support: Int
    public let truePositive: Int
    public let falsePositive: Int
    public let falseNegative: Int
    public let precision: Double
    public let recall: Double
    public let f1: Double

    public init(
        support: Int,
        truePositive: Int,
        falsePositive: Int,
        falseNegative: Int,
        precision: Double,
        recall: Double,
        f1: Double
    ) {
        self.support = support
        self.truePositive = truePositive
        self.falsePositive = falsePositive
        self.falseNegative = falseNegative
        self.precision = precision
        self.recall = recall
        self.f1 = f1
    }
}

public struct ActionLowConfidencePrediction: Sendable, Codable, Equatable {
    public let sourceFile: String
    public let windowIndex: Int
    public let actual: String
    public let predicted: String
    public let confidence: Double

    public init(
        sourceFile: String,
        windowIndex: Int,
        actual: String,
        predicted: String,
        confidence: Double
    ) {
        self.sourceFile = sourceFile
        self.windowIndex = windowIndex
        self.actual = actual
        self.predicted = predicted
        self.confidence = confidence
    }
}

public struct ActionClipSummary: Sendable, Codable, Equatable {
    public let sourceFile: String
    public let actualLabel: String
    public let totalWindows: Int
    public let correctPredictions: Int
    public let accuracy: Double

    public init(
        sourceFile: String,
        actualLabel: String,
        totalWindows: Int,
        correctPredictions: Int,
        accuracy: Double
    ) {
        self.sourceFile = sourceFile
        self.actualLabel = actualLabel
        self.totalWindows = totalWindows
        self.correctPredictions = correctPredictions
        self.accuracy = accuracy
    }
}

/// Where the evaluation windows came from, relative to the model's
/// training partition. Reported in the JSON so a reader can tell at a
/// glance whether the headline accuracy is generalising or just echoing
/// the training set.
public enum ActionEvaluationMode: String, Sendable, Codable, Equatable {
    /// Every evaluation window came from a clip the trained model never
    /// saw during training (i.e. the validation partition only).
    case validationOnly = "validation-only"
    /// Every evaluation window came from clips the model trained on.
    /// The reported accuracy is training accuracy, not generalisation.
    case trainingOnly = "training-only"
    /// Evaluation spans both training and validation partitions —
    /// typical when re-running over the full window cache.
    case fullWindowSet = "full-window-set"
    /// No training report was provided, so the evaluator can't classify
    /// individual windows. Reported metrics are correct but their
    /// generalisation properties are unknown.
    case unknown
}

public struct ActionRecommendation: Sendable, Codable, Equatable {
    public let readyForRuntimeExperiment: Bool
    public let readyForAppBundle: Bool
    public let reasons: [String]
    public let suggestedNextActions: [String]

    public init(
        readyForRuntimeExperiment: Bool,
        readyForAppBundle: Bool,
        reasons: [String],
        suggestedNextActions: [String]
    ) {
        self.readyForRuntimeExperiment = readyForRuntimeExperiment
        self.readyForAppBundle = readyForAppBundle
        self.reasons = reasons
        self.suggestedNextActions = suggestedNextActions
    }
}

public struct ActionEvaluationReport: Sendable, Codable, Equatable {
    public let modelPath: String
    public let windowsDirectory: String
    public let trainingReportPath: String?
    public let totalWindowsEvaluated: Int
    public let overallAccuracy: Double
    public let perClassMetrics: [String: ActionPerClassMetrics]
    public let weakClasses: [String]
    public let weakClassThreshold: Double
    public let confusion: [ActionConfusionMatrixCell]
    public let topConfusions: [ActionConfusionMatrixCell]
    public let lowConfidencePredictions: [ActionLowConfidencePrediction]?
    public let lowConfidenceThreshold: Double
    public let perSourceClipSummary: [ActionClipSummary]
    public let evaluationMode: ActionEvaluationMode
    public let leakageWarnings: [String]
    public let trainOverlapClipCount: Int?
    public let validationOverlapClipCount: Int?
    public let recommendation: ActionRecommendation
    public let evaluationDurationSeconds: Double
    public let reportOutputPath: String
    public let confusionMatrixCsvPath: String?

    public init(
        modelPath: String,
        windowsDirectory: String,
        trainingReportPath: String?,
        totalWindowsEvaluated: Int,
        overallAccuracy: Double,
        perClassMetrics: [String: ActionPerClassMetrics],
        weakClasses: [String],
        weakClassThreshold: Double,
        confusion: [ActionConfusionMatrixCell],
        topConfusions: [ActionConfusionMatrixCell],
        lowConfidencePredictions: [ActionLowConfidencePrediction]?,
        lowConfidenceThreshold: Double,
        perSourceClipSummary: [ActionClipSummary],
        evaluationMode: ActionEvaluationMode,
        leakageWarnings: [String],
        trainOverlapClipCount: Int?,
        validationOverlapClipCount: Int?,
        recommendation: ActionRecommendation,
        evaluationDurationSeconds: Double,
        reportOutputPath: String,
        confusionMatrixCsvPath: String?
    ) {
        self.modelPath = modelPath
        self.windowsDirectory = windowsDirectory
        self.trainingReportPath = trainingReportPath
        self.totalWindowsEvaluated = totalWindowsEvaluated
        self.overallAccuracy = overallAccuracy
        self.perClassMetrics = perClassMetrics
        self.weakClasses = weakClasses
        self.weakClassThreshold = weakClassThreshold
        self.confusion = confusion
        self.topConfusions = topConfusions
        self.lowConfidencePredictions = lowConfidencePredictions
        self.lowConfidenceThreshold = lowConfidenceThreshold
        self.perSourceClipSummary = perSourceClipSummary
        self.evaluationMode = evaluationMode
        self.leakageWarnings = leakageWarnings
        self.trainOverlapClipCount = trainOverlapClipCount
        self.validationOverlapClipCount = validationOverlapClipCount
        self.recommendation = recommendation
        self.evaluationDurationSeconds = evaluationDurationSeconds
        self.reportOutputPath = reportOutputPath
        self.confusionMatrixCsvPath = confusionMatrixCsvPath
    }
}

// MARK: - Calculator (cross-platform pure logic)

/// Pure logic that turns a list of (actual, predicted, ...) records into
/// a full `ActionEvaluationReport`. Has no CoreML / AVFoundation / file
/// IO — all callers, including the macOS evaluator and unit tests, share
/// this code.
public struct ActionEvaluationCalculator: Sendable {

    public init() {}

    public struct PredictionRecord: Sendable, Equatable {
        public let actual: String
        public let predicted: String
        /// Optional probability of the predicted label, in `[0, 1]`. `nil`
        /// when the model didn't emit a probability output.
        public let confidence: Double?
        public let sourceFile: String
        public let windowIndex: Int

        public init(
            actual: String,
            predicted: String,
            confidence: Double?,
            sourceFile: String,
            windowIndex: Int
        ) {
            self.actual = actual
            self.predicted = predicted
            self.confidence = confidence
            self.sourceFile = sourceFile
            self.windowIndex = windowIndex
        }
    }

    public struct InputContext: Sendable {
        public var modelPath: String
        public var windowsDirectory: String
        public var trainingReportPath: String?
        public var weakClassThreshold: Double
        public var topConfusionsLimit: Int
        public var lowConfidenceThreshold: Double
        public var lowConfidencePredictionsLimit: Int
        public var leakageWarnings: [String]
        public var evaluationMode: ActionEvaluationMode
        public var trainOverlapClipCount: Int?
        public var validationOverlapClipCount: Int?
        public var evaluationDurationSeconds: Double
        public var reportOutputPath: String
        public var confusionMatrixCsvPath: String?

        public init(
            modelPath: String,
            windowsDirectory: String,
            trainingReportPath: String? = nil,
            weakClassThreshold: Double = 0.7,
            topConfusionsLimit: Int = 20,
            lowConfidenceThreshold: Double = 0.5,
            lowConfidencePredictionsLimit: Int = 50,
            leakageWarnings: [String] = [],
            evaluationMode: ActionEvaluationMode = .unknown,
            trainOverlapClipCount: Int? = nil,
            validationOverlapClipCount: Int? = nil,
            evaluationDurationSeconds: Double = 0,
            reportOutputPath: String = "",
            confusionMatrixCsvPath: String? = nil
        ) {
            self.modelPath = modelPath
            self.windowsDirectory = windowsDirectory
            self.trainingReportPath = trainingReportPath
            self.weakClassThreshold = weakClassThreshold
            self.topConfusionsLimit = topConfusionsLimit
            self.lowConfidenceThreshold = lowConfidenceThreshold
            self.lowConfidencePredictionsLimit = lowConfidencePredictionsLimit
            self.leakageWarnings = leakageWarnings
            self.evaluationMode = evaluationMode
            self.trainOverlapClipCount = trainOverlapClipCount
            self.validationOverlapClipCount = validationOverlapClipCount
            self.evaluationDurationSeconds = evaluationDurationSeconds
            self.reportOutputPath = reportOutputPath
            self.confusionMatrixCsvPath = confusionMatrixCsvPath
        }
    }

    /// Headline metrics + structured report from a list of predictions.
    public func compute(
        predictions: [PredictionRecord],
        context: InputContext
    ) -> ActionEvaluationReport {

        // Collect every label that appears as either actual or predicted
        // so the per-class table is complete even when a class has zero
        // true positives but non-zero false positives.
        var classes = Set<String>()
        for p in predictions {
            classes.insert(p.actual)
            classes.insert(p.predicted)
        }

        // Per-class TP / FP / FN tallies.
        var truePositive: [String: Int] = [:]
        var falsePositive: [String: Int] = [:]
        var falseNegative: [String: Int] = [:]
        var support: [String: Int] = [:]
        for cls in classes {
            truePositive[cls] = 0
            falsePositive[cls] = 0
            falseNegative[cls] = 0
            support[cls] = 0
        }
        var totalCorrect = 0
        for p in predictions {
            support[p.actual, default: 0] += 1
            if p.actual == p.predicted {
                truePositive[p.actual, default: 0] += 1
                totalCorrect += 1
            } else {
                falsePositive[p.predicted, default: 0] += 1
                falseNegative[p.actual, default: 0] += 1
            }
        }

        var perClass: [String: ActionPerClassMetrics] = [:]
        for cls in classes {
            let tp = Double(truePositive[cls] ?? 0)
            let fp = Double(falsePositive[cls] ?? 0)
            let fn = Double(falseNegative[cls] ?? 0)
            let precision = (tp + fp) > 0 ? tp / (tp + fp) : 0
            let recall = (tp + fn) > 0 ? tp / (tp + fn) : 0
            let f1 = (precision + recall) > 0
                ? 2 * precision * recall / (precision + recall)
                : 0
            perClass[cls] = ActionPerClassMetrics(
                support: support[cls] ?? 0,
                truePositive: truePositive[cls] ?? 0,
                falsePositive: falsePositive[cls] ?? 0,
                falseNegative: falseNegative[cls] ?? 0,
                precision: precision,
                recall: recall,
                f1: f1
            )
        }

        let total = predictions.count
        let overallAccuracy = total > 0 ? Double(totalCorrect) / Double(total) : 0

        // Confusion matrix: every (actual, predicted) pair we observed.
        var counts: [String: [String: Int]] = [:]
        for cls in classes {
            counts[cls] = [:]
            for c2 in classes {
                counts[cls]?[c2] = 0
            }
        }
        for p in predictions {
            counts[p.actual]?[p.predicted, default: 0] += 1
        }
        var confusionCells: [ActionConfusionMatrixCell] = []
        for actual in classes.sorted() {
            for predicted in classes.sorted() {
                let n = counts[actual]?[predicted] ?? 0
                if n > 0 {
                    confusionCells.append(ActionConfusionMatrixCell(
                        actual: actual,
                        predicted: predicted,
                        count: n
                    ))
                }
            }
        }

        let topConfusions = Array(
            confusionCells
                .filter { $0.actual != $0.predicted && $0.count > 0 }
                .sorted { $0.count > $1.count }
                .prefix(context.topConfusionsLimit)
        )

        // Weak classes — F1 below threshold. Include classes with zero
        // support so a missing class is loud, not silent.
        let weakClasses = perClass
            .filter { $0.value.f1 < context.weakClassThreshold }
            .keys
            .sorted()

        // Low-confidence predictions, if probability output is available.
        var lowConfidencePredictions: [ActionLowConfidencePrediction]? = nil
        let withConfidence = predictions.compactMap { p -> (PredictionRecord, Double)? in
            guard let c = p.confidence else { return nil }
            return (p, c)
        }
        if !withConfidence.isEmpty {
            let lowList = withConfidence
                .filter { $0.1 < context.lowConfidenceThreshold }
                .sorted { $0.1 < $1.1 }
                .prefix(context.lowConfidencePredictionsLimit)
                .map { (p, c) in
                    ActionLowConfidencePrediction(
                        sourceFile: p.sourceFile,
                        windowIndex: p.windowIndex,
                        actual: p.actual,
                        predicted: p.predicted,
                        confidence: c
                    )
                }
            // Always populate (possibly empty) when probability output is
            // available — empty list is a meaningful signal ("no low
            // confidence predictions"). `nil` means probability wasn't
            // emitted by the model.
            lowConfidencePredictions = Array(lowList)
        }

        // Per-source-clip summary.
        var clipBuckets: [String: (label: String, total: Int, correct: Int)] = [:]
        for p in predictions {
            var bucket = clipBuckets[p.sourceFile] ?? (label: p.actual, total: 0, correct: 0)
            bucket.total += 1
            if p.actual == p.predicted { bucket.correct += 1 }
            // If we ever encounter a clip with mixed labels (shouldn't
            // happen), keep the first label seen — better than mutating
            // mid-stream.
            clipBuckets[p.sourceFile] = bucket
        }
        let clipSummaries = clipBuckets
            .map { file, bucket in
                ActionClipSummary(
                    sourceFile: file,
                    actualLabel: bucket.label,
                    totalWindows: bucket.total,
                    correctPredictions: bucket.correct,
                    accuracy: bucket.total > 0
                        ? Double(bucket.correct) / Double(bucket.total)
                        : 0
                )
            }
            .sorted { $0.sourceFile < $1.sourceFile }

        let recommendation = makeRecommendation(
            overallAccuracy: overallAccuracy,
            weakClasses: weakClasses,
            weakClassThreshold: context.weakClassThreshold,
            evaluationMode: context.evaluationMode,
            leakageWarnings: context.leakageWarnings
        )

        return ActionEvaluationReport(
            modelPath: context.modelPath,
            windowsDirectory: context.windowsDirectory,
            trainingReportPath: context.trainingReportPath,
            totalWindowsEvaluated: total,
            overallAccuracy: overallAccuracy,
            perClassMetrics: perClass,
            weakClasses: weakClasses,
            weakClassThreshold: context.weakClassThreshold,
            confusion: confusionCells,
            topConfusions: topConfusions,
            lowConfidencePredictions: lowConfidencePredictions,
            lowConfidenceThreshold: context.lowConfidenceThreshold,
            perSourceClipSummary: clipSummaries,
            evaluationMode: context.evaluationMode,
            leakageWarnings: context.leakageWarnings,
            trainOverlapClipCount: context.trainOverlapClipCount,
            validationOverlapClipCount: context.validationOverlapClipCount,
            recommendation: recommendation,
            evaluationDurationSeconds: context.evaluationDurationSeconds,
            reportOutputPath: context.reportOutputPath,
            confusionMatrixCsvPath: context.confusionMatrixCsvPath
        )
    }

    /// Decision-support output. Encoded into the report so downstream
    /// tools (CI, dashboards) can read the same recommendation the CLI
    /// prints.
    ///
    /// Rules:
    ///   * `readyForRuntimeExperiment` is true iff overall accuracy
    ///     >= 0.80 AND no more than 3 classes fall below the F1
    ///     threshold AND the evaluation mode isn't `trainingOnly`
    ///     (training accuracy can't unlock a runtime experiment).
    ///   * `readyForAppBundle` is **always false** in this slice.
    ///     Bundling requires an evaluation against fresh, never-seen
    ///     captures; that's a future slice's gate.
    public func makeRecommendation(
        overallAccuracy: Double,
        weakClasses: [String],
        weakClassThreshold: Double,
        evaluationMode: ActionEvaluationMode,
        leakageWarnings: [String]
    ) -> ActionRecommendation {

        let accuracyPass = overallAccuracy >= 0.80
        let weakClassPass = weakClasses.count <= 3
        let modePass = evaluationMode != .trainingOnly
        let runtimeReady = accuracyPass && weakClassPass && modePass

        let pct = String(format: "%.2f%%", overallAccuracy * 100)
        let thresholdPct = String(format: "%.2f", weakClassThreshold)
        var reasons: [String] = []
        var actions: [String] = []

        if accuracyPass {
            reasons.append(
                "Overall accuracy \(pct) meets the 80% runtime-experiment threshold."
            )
        } else {
            reasons.append(
                "Overall accuracy \(pct) is below the 80% runtime-experiment threshold."
            )
            actions.append(
                "Improve the trained model — more data per weak class, richer features, or temporal modelling."
            )
        }

        if weakClassPass {
            if weakClasses.isEmpty {
                reasons.append("No classes fall below F1 \(thresholdPct).")
            } else {
                reasons.append(
                    "\(weakClasses.count) class(es) below F1 \(thresholdPct):"
                    + " \(weakClasses.joined(separator: ", "))."
                    + " Acceptable for a runtime experiment but watch closely."
                )
            }
        } else {
            reasons.append(
                "\(weakClasses.count) classes below F1 \(thresholdPct):"
                + " \(weakClasses.joined(separator: ", "))."
                + " Too many weak classes for a runtime experiment."
            )
            actions.append(
                "Targeted data collection / augmentation for weak classes:"
                + " \(weakClasses.joined(separator: ", "))."
            )
        }

        switch evaluationMode {
        case .trainingOnly:
            reasons.append(
                "Evaluation set was the training set — accuracy here is"
                + " training accuracy, not generalisation."
            )
            actions.append(
                "Re-run evaluation against validation-only or fresh windows."
            )
        case .fullWindowSet:
            reasons.append(
                "Evaluation set spans both training and validation clips —"
                + " accuracy will overstate runtime performance."
            )
            actions.append(
                "Re-run with validation-only clips, or capture fresh takes,"
                + " before drawing conclusions for runtime."
            )
        case .validationOnly:
            reasons.append("Evaluation set is held-out validation clips only.")
        case .unknown:
            reasons.append(
                "No training-report metadata was provided — generalisation"
                + " cannot be confirmed from this evaluation alone."
            )
            actions.append(
                "Pass --training-report to enable train/validation leakage checks."
            )
        }

        if !leakageWarnings.isEmpty {
            reasons.append(
                "Leakage / quality warnings present (\(leakageWarnings.count)):"
                + " review the leakageWarnings field in the report."
            )
        }

        // App-bundle gate is always closed in this slice.
        reasons.append(
            "App-bundle deployment requires evaluation against fresh,"
            + " never-seen captures — not yet performed."
        )
        actions.append(
            "Capture fresh test takes (different sessions, performers,"
            + " lighting) and re-run the evaluator before bundling."
        )

        return ActionRecommendation(
            readyForRuntimeExperiment: runtimeReady,
            readyForAppBundle: false,
            reasons: reasons,
            suggestedNextActions: actions
        )
    }
}

// MARK: - Confusion-matrix CSV

public enum ActionEvaluationCSV {

    /// Square confusion-matrix CSV: one row per actual class, one column
    /// per predicted class, counts in each cell. Class order is
    /// alphabetic so the file is reproducible across runs.
    public static func confusionMatrixCSV(from report: ActionEvaluationReport) -> String {
        let classes = Array(
            Set(report.confusion.flatMap { [$0.actual, $0.predicted] })
        ).sorted()
        var matrix: [String: [String: Int]] = [:]
        for actual in classes {
            matrix[actual] = [:]
            for predicted in classes {
                matrix[actual]?[predicted] = 0
            }
        }
        for cell in report.confusion {
            matrix[cell.actual]?[cell.predicted] = cell.count
        }
        var csv = "actual\\predicted," + classes.joined(separator: ",") + "\n"
        for actual in classes {
            csv += actual
            for predicted in classes {
                csv += ",\(matrix[actual]?[predicted] ?? 0)"
            }
            csv += "\n"
        }
        return csv
    }
}

// MARK: - Evaluator entry point

public struct ScratchActionClassifierEvaluator: Sendable {
    public init() {}
}

extension ScratchActionClassifierEvaluator {

    public struct Configuration: Sendable {
        public var modelURL: URL
        public var windowsDirectory: URL
        public var outputDirectory: URL
        public var trainingReportURL: URL?
        public var weakClassThreshold: Double
        public var topConfusions: Int
        public var lowConfidenceThreshold: Double
        public var modelFilename: String

        public init(
            modelURL: URL,
            windowsDirectory: URL,
            outputDirectory: URL,
            trainingReportURL: URL? = nil,
            weakClassThreshold: Double = 0.7,
            topConfusions: Int = 20,
            lowConfidenceThreshold: Double = 0.5,
            modelFilename: String = "ScratchActionClassifier"
        ) {
            self.modelURL = modelURL
            self.windowsDirectory = windowsDirectory
            self.outputDirectory = outputDirectory
            self.trainingReportURL = trainingReportURL
            self.weakClassThreshold = weakClassThreshold
            self.topConfusions = topConfusions
            self.lowConfidenceThreshold = lowConfidenceThreshold
            self.modelFilename = modelFilename
        }
    }

    public struct Artifacts: Sendable, Equatable {
        public let reportURL: URL
        public let confusionMatrixCsvURL: URL
        public let report: ActionEvaluationReport

        public init(
            reportURL: URL,
            confusionMatrixCsvURL: URL,
            report: ActionEvaluationReport
        ) {
            self.reportURL = reportURL
            self.confusionMatrixCsvURL = confusionMatrixCsvURL
            self.report = report
        }
    }

    public enum EvaluationError: Error, Equatable {
        case modelNotFound(path: String)
        case modelLoadFailed(underlying: String)
        case windowsLoadFailed(underlying: String)
        case predictionFailed(underlying: String)
        case writeFailed(path: String, underlying: String)
        case evaluationUnavailableOnPlatform
    }
}

// MARK: - Cross-platform unavailable stub

#if !os(macOS)
extension ScratchActionClassifierEvaluator {
    public func evaluate(_ config: Configuration) throws -> Artifacts {
        throw EvaluationError.evaluationUnavailableOnPlatform
    }
}
#endif

// MARK: - macOS evaluator

#if os(macOS)
import CoreML

extension ScratchActionClassifierEvaluator {

    /// Compile and load the .mlmodel, run predictions over every window
    /// in `windowsDirectory`, build the report, and write
    /// `<modelFilename>.evaluation-report.json` plus
    /// `<modelFilename>.confusion-matrix.csv` into `outputDirectory`.
    public func evaluate(_ config: Configuration) throws -> Artifacts {
        let started = Date()

        guard FileManager.default.fileExists(atPath: config.modelURL.path) else {
            throw EvaluationError.modelNotFound(path: config.modelURL.path)
        }

        // CoreML needs a compiled .mlmodelc to instantiate `MLModel`.
        // `MLModel.compileModel` writes the compiled artefact into the
        // user's caches directory and returns the URL. Clean it up when
        // we're done so we don't leave breadcrumbs around.
        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: config.modelURL)
        } catch {
            throw EvaluationError.modelLoadFailed(
                underlying: "compileModel: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: compiledURL) }

        let model: MLModel
        do {
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            throw EvaluationError.modelLoadFailed(
                underlying: error.localizedDescription
            )
        }

        // Load every window so the evaluator runs against the full set
        // by default. The leakage detector below classifies each window
        // as train / validation / unknown when a training report is
        // provided.
        let dataset: ActionWindowDataset
        do {
            dataset = try ActionWindowDatasetLoader().load(
                windowsDir: config.windowsDirectory,
                validationFraction: 0,
                seed: 0
            )
        } catch {
            throw EvaluationError.windowsLoadFailed(
                underlying: String(describing: error)
            )
        }

        // Optional training report → reproduce the original train/val
        // split (deterministic given the seed) and emit leakage
        // warnings. If parsing fails we don't abort — we just record
        // the failure as a warning and continue with mode=.unknown.
        var trainingReport: ActionTrainingReport? = nil
        var leakageWarnings: [String] = []
        var evaluationMode: ActionEvaluationMode = .unknown
        var trainOverlap: Int? = nil
        var validationOverlap: Int? = nil

        if let trainingReportURL = config.trainingReportURL {
            do {
                let data = try Data(contentsOf: trainingReportURL)
                trainingReport = try JSONDecoder().decode(
                    ActionTrainingReport.self,
                    from: data
                )
            } catch {
                leakageWarnings.append(
                    "training-report at \(trainingReportURL.path) could not"
                    + " be parsed (\(error.localizedDescription)) —"
                    + " leakage check skipped."
                )
            }
        }

        if let report = trainingReport {
            do {
                let partitioned = try ActionWindowDatasetLoader().load(
                    windowsDir: config.windowsDirectory,
                    validationFraction: report.validationFraction,
                    seed: report.seed,
                    balanceTrainingClasses: false
                )
                let trainingClipFiles = Set(
                    partitioned.trainingWindows.map { $0.sourceFile }
                )
                let validationClipFiles = Set(
                    partitioned.validationWindows.map { $0.sourceFile }
                )
                let evaluatedClips = Set(
                    dataset.allWindows.map { $0.sourceFile }
                )
                trainOverlap = evaluatedClips.intersection(trainingClipFiles).count
                validationOverlap = evaluatedClips.intersection(validationClipFiles).count
                let trainCount = trainOverlap ?? 0
                let valCount = validationOverlap ?? 0
                if trainCount > 0 && valCount > 0 {
                    evaluationMode = .fullWindowSet
                    leakageWarnings.append(
                        "Evaluation set spans both the training partition"
                        + " (\(trainCount) clip(s)) and the validation"
                        + " partition (\(valCount) clip(s)) —"
                        + " overall accuracy will overstate runtime"
                        + " performance."
                    )
                } else if trainCount > 0 && valCount == 0 {
                    evaluationMode = .trainingOnly
                    leakageWarnings.append(
                        "Every evaluated clip is in the training"
                        + " partition — reported accuracy is training"
                        + " accuracy, not generalisation."
                    )
                } else if valCount > 0 && trainCount == 0 {
                    evaluationMode = .validationOnly
                }
            } catch {
                leakageWarnings.append(
                    "Could not reproduce train/val split for leakage"
                    + " check: \(error.localizedDescription)"
                )
            }
        }

        // Prediction loop. One MLDictionaryFeatureProvider per window.
        // The model's input column names are exactly the ones produced
        // by `ActionTrainerFeatures.projectToRow` so training and
        // evaluation can never disagree on schema.
        var predictions: [ActionEvaluationCalculator.PredictionRecord] = []
        predictions.reserveCapacity(dataset.allWindows.count)
        for window in dataset.allWindows {
            let row = ActionTrainerFeatures.projectToRow(window)
            var dict: [String: MLFeatureValue] = [:]
            dict.reserveCapacity(row.count)
            for (key, value) in row {
                dict[key] = MLFeatureValue(double: value)
            }
            let provider: MLDictionaryFeatureProvider
            do {
                provider = try MLDictionaryFeatureProvider(dictionary: dict)
            } catch {
                throw EvaluationError.predictionFailed(
                    underlying: "feature provider: \(error.localizedDescription)"
                )
            }
            let output: MLFeatureProvider
            do {
                output = try model.prediction(from: provider)
            } catch {
                throw EvaluationError.predictionFailed(
                    underlying: error.localizedDescription
                )
            }
            let predicted = output.featureValue(for: "label")?.stringValue ?? ""
            var confidence: Double? = nil
            if let probs = output.featureValue(for: "labelProbability")?
                .dictionaryValue {
                if let n = probs[predicted as NSObject] {
                    confidence = n.doubleValue
                }
            }
            predictions.append(
                ActionEvaluationCalculator.PredictionRecord(
                    actual: window.classLabel,
                    predicted: predicted,
                    confidence: confidence,
                    sourceFile: window.sourceFile,
                    windowIndex: window.windowIndex
                )
            )
        }

        // Class-imbalance leakage warning. >3x ratio means accuracy
        // pivots heavily on the majority classes; per-class F1 is the
        // honest metric.
        let supportByClass = predictions.reduce(into: [String: Int]()) { dict, p in
            dict[p.actual, default: 0] += 1
        }
        if let lo = supportByClass.values.min(),
           let hi = supportByClass.values.max(),
           lo > 0 {
            let ratio = Double(hi) / Double(lo)
            if ratio > 3 {
                leakageWarnings.append(
                    String(
                        format: "Class imbalance support ratio %.2f —"
                            + " overall accuracy is biased by majority"
                            + " classes; trust per-class F1.",
                        ratio
                    )
                )
            }
        }

        // Resolve output paths.
        do {
            try FileManager.default.createDirectory(
                at: config.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw EvaluationError.writeFailed(
                path: config.outputDirectory.path,
                underlying: error.localizedDescription
            )
        }
        let reportURL = config.outputDirectory.appendingPathComponent(
            "\(config.modelFilename).evaluation-report.json"
        )
        let csvURL = config.outputDirectory.appendingPathComponent(
            "\(config.modelFilename).confusion-matrix.csv"
        )

        let context = ActionEvaluationCalculator.InputContext(
            modelPath: config.modelURL.path,
            windowsDirectory: config.windowsDirectory.path,
            trainingReportPath: config.trainingReportURL?.path,
            weakClassThreshold: config.weakClassThreshold,
            topConfusionsLimit: config.topConfusions,
            lowConfidenceThreshold: config.lowConfidenceThreshold,
            lowConfidencePredictionsLimit: 50,
            leakageWarnings: leakageWarnings,
            evaluationMode: evaluationMode,
            trainOverlapClipCount: trainOverlap,
            validationOverlapClipCount: validationOverlap,
            evaluationDurationSeconds: Date().timeIntervalSince(started),
            reportOutputPath: reportURL.path,
            confusionMatrixCsvPath: csvURL.path
        )
        let evaluation = ActionEvaluationCalculator().compute(
            predictions: predictions,
            context: context
        )

        // Write report JSON + confusion matrix CSV. Both atomic.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(evaluation)
            try data.write(to: reportURL, options: Data.WritingOptions.atomic)
        } catch {
            throw EvaluationError.writeFailed(
                path: reportURL.path,
                underlying: error.localizedDescription
            )
        }
        do {
            let csv = ActionEvaluationCSV.confusionMatrixCSV(from: evaluation)
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        } catch {
            throw EvaluationError.writeFailed(
                path: csvURL.path,
                underlying: error.localizedDescription
            )
        }

        return Artifacts(
            reportURL: reportURL,
            confusionMatrixCsvURL: csvURL,
            report: evaluation
        )
    }
}

#endif
