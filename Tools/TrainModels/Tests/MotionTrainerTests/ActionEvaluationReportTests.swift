import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

/// Tests for the cross-platform parts of the action-classifier
/// evaluator: precision/recall/F1 math, confusion-matrix construction,
/// weak-class detection, top-confusion sorting, recommendation logic,
/// per-clip summary, low-confidence flagging, and Codable round-trip.
/// CoreML invocation is exercised end-to-end by the real `--evaluate-
/// action-classifier` run, not by unit tests.
final class ActionEvaluationReportTests: XCTestCase {

    // MARK: - Helpers

    private func record(
        _ actual: String,
        _ predicted: String,
        confidence: Double? = nil,
        sourceFile: String = "x.jsonl",
        windowIndex: Int = 0
    ) -> ActionEvaluationCalculator.PredictionRecord {
        ActionEvaluationCalculator.PredictionRecord(
            actual: actual,
            predicted: predicted,
            confidence: confidence,
            sourceFile: sourceFile,
            windowIndex: windowIndex
        )
    }

    private func defaultContext(
        weakClassThreshold: Double = 0.7,
        topConfusionsLimit: Int = 5,
        lowConfidenceThreshold: Double = 0.5,
        evaluationMode: ActionEvaluationMode = .validationOnly,
        leakageWarnings: [String] = []
    ) -> ActionEvaluationCalculator.InputContext {
        .init(
            modelPath: "/tmp/model.mlmodel",
            windowsDirectory: "/tmp/windows",
            trainingReportPath: nil,
            weakClassThreshold: weakClassThreshold,
            topConfusionsLimit: topConfusionsLimit,
            lowConfidenceThreshold: lowConfidenceThreshold,
            lowConfidencePredictionsLimit: 50,
            leakageWarnings: leakageWarnings,
            evaluationMode: evaluationMode,
            trainOverlapClipCount: nil,
            validationOverlapClipCount: nil,
            evaluationDurationSeconds: 0,
            reportOutputPath: "/tmp/eval-report.json",
            confusionMatrixCsvPath: "/tmp/eval-confusion.csv"
        )
    }

    // MARK: - Headline metrics

    func test_overallAccuracy_perfectPredictions() {
        let preds = [
            record("a", "a"),
            record("b", "b"),
            record("c", "c"),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        XCTAssertEqual(report.overallAccuracy, 1.0, accuracy: 1e-12)
        XCTAssertEqual(report.totalWindowsEvaluated, 3)
    }

    func test_overallAccuracy_emptyPredictionsReturnsZeros() {
        let report = ActionEvaluationCalculator().compute(
            predictions: [], context: defaultContext()
        )
        XCTAssertEqual(report.totalWindowsEvaluated, 0)
        XCTAssertEqual(report.overallAccuracy, 0)
        XCTAssertTrue(report.perClassMetrics.isEmpty)
        XCTAssertTrue(report.weakClasses.isEmpty)
    }

    // MARK: - Precision / recall / F1

    func test_perClassPrecisionRecallF1_balancedBinary() {
        // a: 4 actual; predicted as a 3 times, as b 1 time → tp=3 fn=1
        // b: 4 actual; predicted as b 3 times, as a 1 time → tp=3 fn=1
        // a falsely predicted 1 time (when true is b) → fp=1
        // b falsely predicted 1 time (when true is a) → fp=1
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        preds.append(contentsOf: (0..<3).map { _ in record("a", "a") })
        preds.append(record("a", "b"))
        preds.append(contentsOf: (0..<3).map { _ in record("b", "b") })
        preds.append(record("b", "a"))
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        let a = report.perClassMetrics["a"]!
        XCTAssertEqual(a.support, 4)
        XCTAssertEqual(a.truePositive, 3)
        XCTAssertEqual(a.falsePositive, 1)
        XCTAssertEqual(a.falseNegative, 1)
        XCTAssertEqual(a.precision, 0.75, accuracy: 1e-12)
        XCTAssertEqual(a.recall, 0.75, accuracy: 1e-12)
        XCTAssertEqual(a.f1, 0.75, accuracy: 1e-12)
    }

    func test_perClassMetrics_handlesZeroDivisionGracefully() {
        // class "x" only appears as true label; class "y" only as predicted.
        let preds = [record("x", "y"), record("x", "y")]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        let x = report.perClassMetrics["x"]!
        // x: tp=0 fn=2 fp=0 → recall=0, precision=0/0 → 0, f1=0
        XCTAssertEqual(x.precision, 0)
        XCTAssertEqual(x.recall, 0)
        XCTAssertEqual(x.f1, 0)
        let y = report.perClassMetrics["y"]!
        // y: tp=0 fp=2 fn=0 → precision=0, recall=0/0 → 0, f1=0
        XCTAssertEqual(y.precision, 0)
        XCTAssertEqual(y.recall, 0)
        XCTAssertEqual(y.f1, 0)
    }

    // MARK: - Confusion matrix

    func test_confusion_matrixContainsEveryObservedPair() {
        let preds = [
            record("a", "a"), record("a", "a"),
            record("a", "b"),
            record("b", "b"),
            record("c", "a"),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        let asTuples = report.confusion.map { ($0.actual, $0.predicted, $0.count) }
        XCTAssertTrue(asTuples.contains(where: { $0 == ("a", "a", 2) }))
        XCTAssertTrue(asTuples.contains(where: { $0 == ("a", "b", 1) }))
        XCTAssertTrue(asTuples.contains(where: { $0 == ("b", "b", 1) }))
        XCTAssertTrue(asTuples.contains(where: { $0 == ("c", "a", 1) }))
        // Confusion cells are sorted (actual, predicted)
        let sortedKeys = report.confusion.map { "\($0.actual)/\($0.predicted)" }
        XCTAssertEqual(sortedKeys, sortedKeys.sorted())
    }

    func test_topConfusions_sortsByCountDescAndExcludesDiagonal() {
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        preds.append(contentsOf: (0..<5).map { _ in record("transformer", "crabs") })
        preds.append(contentsOf: (0..<3).map { _ in record("chirpflare", "transformer") })
        preds.append(contentsOf: (0..<10).map { _ in record("transformer", "transformer") })  // diagonal — excluded
        preds.append(contentsOf: (0..<2).map { _ in record("baby", "tears") })
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext(topConfusionsLimit: 3)
        )
        XCTAssertEqual(report.topConfusions.count, 3)
        XCTAssertEqual(report.topConfusions[0].actual, "transformer")
        XCTAssertEqual(report.topConfusions[0].predicted, "crabs")
        XCTAssertEqual(report.topConfusions[0].count, 5)
        XCTAssertEqual(report.topConfusions[1].count, 3)
        XCTAssertEqual(report.topConfusions[2].count, 2)
        for cell in report.topConfusions {
            XCTAssertNotEqual(cell.actual, cell.predicted, "diagonal leaked into top-confusions")
        }
    }

    // MARK: - Weak class detection

    func test_weakClasses_capturedByThreshold() {
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        // strong: 10/10 correct
        for _ in 0..<10 { preds.append(record("strong", "strong")) }
        // weak: 1/4 correct (precision 1/1, recall 1/4 → F1 = 0.4)
        for _ in 0..<3 { preds.append(record("weak", "strong")) }
        preds.append(record("weak", "weak"))
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext(weakClassThreshold: 0.7)
        )
        XCTAssertEqual(report.weakClasses, ["weak"])
    }

    // MARK: - Per-clip summary

    func test_perSourceClipSummary_isAccuratePerClipAndSorted() {
        let preds = [
            record("a", "a", sourceFile: "clip_zz.jsonl", windowIndex: 0),
            record("a", "b", sourceFile: "clip_zz.jsonl", windowIndex: 1),
            record("b", "b", sourceFile: "clip_aa.jsonl", windowIndex: 0),
            record("b", "b", sourceFile: "clip_aa.jsonl", windowIndex: 1),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        XCTAssertEqual(report.perSourceClipSummary.count, 2)
        XCTAssertEqual(report.perSourceClipSummary[0].sourceFile, "clip_aa.jsonl")
        XCTAssertEqual(report.perSourceClipSummary[0].accuracy, 1.0)
        XCTAssertEqual(report.perSourceClipSummary[1].sourceFile, "clip_zz.jsonl")
        XCTAssertEqual(report.perSourceClipSummary[1].correctPredictions, 1)
        XCTAssertEqual(report.perSourceClipSummary[1].accuracy, 0.5)
    }

    // MARK: - Low-confidence predictions

    func test_lowConfidence_returnsNilWhenNoConfidenceProvided() {
        let preds = [record("a", "a"), record("a", "b")]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        XCTAssertNil(report.lowConfidencePredictions,
                     "should be nil when no records carry confidence")
    }

    func test_lowConfidence_capturesBelowThreshold() {
        let preds = [
            record("a", "a", confidence: 0.95),
            record("a", "b", confidence: 0.40, windowIndex: 1),
            record("b", "b", confidence: 0.85),
            record("b", "a", confidence: 0.30, windowIndex: 2),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(lowConfidenceThreshold: 0.5)
        )
        let lows = report.lowConfidencePredictions ?? []
        XCTAssertEqual(lows.count, 2)
        XCTAssertEqual(lows[0].confidence, 0.30, accuracy: 1e-12,
                       "lowest confidence should sort first")
        XCTAssertEqual(lows[1].confidence, 0.40, accuracy: 1e-12)
    }

    func test_lowConfidence_emptyArrayWhenAllAboveThreshold() {
        let preds = [
            record("a", "a", confidence: 0.95),
            record("a", "a", confidence: 0.85),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(lowConfidenceThreshold: 0.5)
        )
        XCTAssertNotNil(report.lowConfidencePredictions)
        XCTAssertTrue(report.lowConfidencePredictions?.isEmpty ?? false,
                      "non-nil empty list when probability is available but no low-conf hits")
    }

    // MARK: - Recommendation logic

    func test_recommendation_runtimeReadyWhenAccuracyAndWeakClassPass() {
        // 10 correct out of 12 → 83% accuracy, 0 weak classes
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        for _ in 0..<10 { preds.append(record("a", "a")) }
        for _ in 0..<2 { preds.append(record("b", "b")) }
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(evaluationMode: .validationOnly)
        )
        XCTAssertTrue(report.recommendation.readyForRuntimeExperiment)
        XCTAssertFalse(report.recommendation.readyForAppBundle,
                       "app bundle is always false in this slice")
    }

    func test_recommendation_runtimeBlockedByLowAccuracy() {
        // Half right
        let preds = [
            record("a", "a"), record("a", "b"),
            record("b", "b"), record("b", "a"),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(evaluationMode: .validationOnly)
        )
        XCTAssertFalse(report.recommendation.readyForRuntimeExperiment)
        XCTAssertTrue(report.recommendation.reasons.contains(where: { $0.contains("below the 80%") }),
                      "should explain why accuracy fails")
    }

    func test_recommendation_runtimeBlockedByTooManyWeakClasses() {
        // Build 4 weak classes (each 0% F1) and one strong
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        for _ in 0..<200 { preds.append(record("strong", "strong")) }
        for cls in ["weakA", "weakB", "weakC", "weakD"] {
            // every record is a misprediction, so F1 = 0
            for _ in 0..<3 { preds.append(record(cls, "strong")) }
        }
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(weakClassThreshold: 0.7,
                                    evaluationMode: .validationOnly)
        )
        XCTAssertGreaterThanOrEqual(report.weakClasses.count, 4)
        XCTAssertFalse(report.recommendation.readyForRuntimeExperiment,
                       ">3 weak classes should block runtime")
    }

    func test_recommendation_runtimeBlockedWhenEvaluationOnTrainingOnly() {
        // 100% accuracy on a single-class training-only run is not a green light.
        var preds: [ActionEvaluationCalculator.PredictionRecord] = []
        for _ in 0..<10 { preds.append(record("a", "a")) }
        for _ in 0..<10 { preds.append(record("b", "b")) }
        let report = ActionEvaluationCalculator().compute(
            predictions: preds,
            context: defaultContext(evaluationMode: .trainingOnly)
        )
        XCTAssertFalse(report.recommendation.readyForRuntimeExperiment,
                       "training-only evaluation must not unlock runtime")
        XCTAssertTrue(report.recommendation.reasons.contains(where: { $0.contains("training accuracy") }))
    }

    // MARK: - Codable round trip

    func test_evaluationReport_roundTripsThroughJSON() throws {
        let preds = [
            record("a", "a", confidence: 0.9),
            record("a", "b", confidence: 0.4, windowIndex: 1),
            record("b", "b", confidence: 0.85),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ActionEvaluationReport.self, from: encoded)
        XCTAssertEqual(decoded, report)
    }

    // MARK: - Confusion matrix CSV

    func test_confusionMatrixCSV_isSquareWithSortedClassHeaders() {
        let preds = [
            record("a", "a"), record("a", "b"),
            record("b", "b"), record("b", "a"),
        ]
        let report = ActionEvaluationCalculator().compute(
            predictions: preds, context: defaultContext()
        )
        let csv = ActionEvaluationCSV.confusionMatrixCSV(from: report)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "actual\\predicted,a,b")
        XCTAssertEqual(lines[1], "a,1,1")
        XCTAssertEqual(lines[2], "b,1,1")
    }
}
