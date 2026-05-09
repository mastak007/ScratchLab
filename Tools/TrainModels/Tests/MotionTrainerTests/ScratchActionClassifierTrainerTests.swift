import XCTest
@testable import MotionTrainer
@testable import ScratchLabML

/// Tests for the cross-platform parts of the action-classifier trainer:
/// configuration defaults, the Codable training report, and feature-column
/// schema. Full CreateML training is too heavy for unit tests; this layer
/// is what we cover here, plus the report's JSON round-trip.
final class ScratchActionClassifierTrainerTests: XCTestCase {

    func test_trainingConfiguration_defaults() {
        let cfg = ScratchActionClassifierTrainer.TrainingConfiguration(
            windowsDirectory: URL(fileURLWithPath: "/tmp/x", isDirectory: true),
            outputDirectory: URL(fileURLWithPath: "/tmp/y", isDirectory: true)
        )
        XCTAssertEqual(cfg.modelFilename, "ScratchActionClassifier")
        XCTAssertEqual(cfg.validationFraction, 0.2)
        XCTAssertEqual(cfg.seed, 1337)
        XCTAssertFalse(cfg.balanceTrainingClasses)
        XCTAssertEqual(cfg.maximumIterations, 50)
        XCTAssertEqual(cfg.predictionWindowSize, 60)
    }

    func test_featureColumns_areStableAndUnique() {
        let cols = ActionTrainerFeatures.columns
        XCTAssertEqual(Set(cols).count, cols.count, "duplicate feature column names")
        XCTAssertFalse(cols.contains("session"))
        XCTAssertFalse(cols.contains("label"))
        // 9 aggregates + 13 numeric per-frame fields × 4 stats + 6 presence rates = 67.
        let expectedCount = ActionTrainerFeatures.aggregateFields.count
            + ActionTrainerFeatures.perFrameNumericFields.count
                * ActionTrainerFeatures.summaryStatistics.count
            + ActionTrainerFeatures.perFramePresenceFields.count
        XCTAssertEqual(cols.count, expectedCount)
        XCTAssertEqual(expectedCount, 67)
    }

    func test_featureColumns_matchMotionFrameFeatures() {
        // Sanity-check: aggregates are namespaced with `agg_`; every other
        // column should derive from a per-frame numeric or presence field.
        let validPrefixes = ActionTrainerFeatures.aggregateFields
            + ActionTrainerFeatures.perFrameNumericFields.map { $0 + "_" }
            + ActionTrainerFeatures.perFramePresenceFields.map { $0 + "_" }
        for col in ActionTrainerFeatures.columns {
            let hit = validPrefixes.contains { col.hasPrefix($0) }
            XCTAssertTrue(hit, "feature column \(col) doesn't match any known prefix")
        }
    }

    func test_projectToRow_emitsAllExpectedColumns() {
        let frames = (0..<60).map { i in
            MotionFrameFeatures(
                timestamp: Double(i) / 30.0,
                dominantHandX: 0.5, dominantHandY: 0.5, dominantHandPresent: true,
                dominantHandWristX: 0.4, dominantHandWristY: 0.6, dominantHandWristPresent: true,
                dominantHandIndexTipX: 0.5, dominantHandIndexTipY: 0.5, dominantHandIndexTipPresent: true,
                dominantHandThumbTipX: 0.45, dominantHandThumbTipY: 0.55, dominantHandThumbTipPresent: true,
                dominantHandMiddleTipX: 0.55, dominantHandMiddleTipY: 0.45, dominantHandMiddleTipPresent: true,
                secondaryHandWristX: 0.7, secondaryHandWristY: 0.6, secondaryHandWristPresent: true,
                recordCenterX: 0, recordCenterY: 0, recordCenterPresent: false,
                dominantHandConfidence: 0.9
            )
        }
        let agg = MotionWindowAggregates(
            dominantWristPathLength: 0.1,
            dominantHandPathLength: 0.2,
            romX: 0.3, romY: 0.4,
            meanVelocity: 0.5, maxVelocity: 0.6,
            centerLineCrossings: 7,
            dominantHandMissingRatio: 0,
            dominantHandWristMissingRatio: 0
        )
        let window = LoadedActionWindow(
            classLabel: "baby",
            sourceFile: "x.jsonl",
            windowIndex: 0,
            sessionID: "baby/x.jsonl/0",
            frames: frames,
            aggregates: agg
        )
        let row = ActionTrainerFeatures.projectToRow(window)
        for col in ActionTrainerFeatures.columns {
            XCTAssertNotNil(row[col], "missing column \(col)")
        }
        // Aggregate-specific values land verbatim.
        XCTAssertEqual(row["agg_dominantWristPathLength"], 0.1)
        XCTAssertEqual(row["agg_centerLineCrossings"], 7)
        // Static values produce zero std and equal min == max.
        XCTAssertEqual(row["dominantHandX_mean"], 0.5)
        XCTAssertEqual(row["dominantHandX_std"], 0)
        XCTAssertEqual(row["dominantHandX_min"], 0.5)
        XCTAssertEqual(row["dominantHandX_max"], 0.5)
        // Presence rates: every frame has dominantHand → rate is 1.0.
        XCTAssertEqual(row["dominantHandPresent_rate"], 1.0)
    }

    func test_actionTrainingReport_roundTripsThroughJSON() throws {
        let cells = [
            ActionConfusionMatrixCell(actual: "baby", predicted: "baby", count: 12),
            ActionConfusionMatrixCell(actual: "baby", predicted: "tears", count: 1),
            ActionConfusionMatrixCell(actual: "tears", predicted: "tears", count: 9),
        ]
        let report = ActionTrainingReport(
            modelFilename: "ScratchActionClassifier",
            trainerKind: "MLActivityClassifier",
            predictionWindowSize: 60,
            maximumIterations: 50,
            validationFraction: 0.2,
            seed: 1337,
            balanceTrainingClassesRequested: false,
            balanceTrainingClassesApplied: false,
            totalWindowsLoaded: 4700,
            trainingWindowCount: 3760,
            validationWindowCount: 940,
            trainingClipCount: 560,
            validationClipCount: 140,
            perClassTotal: ["baby": 156, "tears": 256],
            perClassTraining: ["baby": 124, "tears": 204],
            perClassValidation: ["baby": 32, "tears": 52],
            imbalanceRatio: 1.64,
            trainingAccuracy: 0.92,
            validationAccuracy: 0.88,
            trainingError: 0.08,
            validationError: 0.12,
            perClassValidationAccuracy: ["baby": 0.95, "tears": 0.81],
            confusion: cells,
            weakestClasses: ["transformer"],
            weakClassThreshold: 0.7,
            trainingDurationSeconds: 123.4,
            modelOutputPath: "/some/path/ScratchActionClassifier.mlmodel",
            reportOutputPath: "/some/path/ScratchActionClassifier.training-report.json"
        )
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ActionTrainingReport.self, from: encoded)
        XCTAssertEqual(decoded, report)
    }

    func test_trainingError_equatable() {
        XCTAssertEqual(
            ScratchActionClassifierTrainer.TrainingError.trainingFailed(underlying: "x"),
            ScratchActionClassifierTrainer.TrainingError.trainingFailed(underlying: "x")
        )
        XCTAssertNotEqual(
            ScratchActionClassifierTrainer.TrainingError.trainingFailed(underlying: "x"),
            ScratchActionClassifierTrainer.TrainingError.trainingFailed(underlying: "y")
        )
    }
}
