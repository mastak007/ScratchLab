import XCTest
@testable import ScratchLab

final class SessionQualityAnalyzerTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_500_000)

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Empty / insufficient data

    func testEmptySnapshotProducesNilNumericFields() {
        let snapshot = makeSnapshot(peakLevels: [], movements: [])
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 0.5,
            now: Self.referenceDate
        )
        XCTAssertNil(report.peakLevelMax)
        XCTAssertNil(report.peakLevelMedian)
        XCTAssertNil(report.audioEventRMSMedian)
        XCTAssertNil(report.interOnsetGapMean)
        XCTAssertNil(report.interOnsetGapStdev)
        XCTAssertNil(report.directionFlipsPerSecond)
        XCTAssertEqual(report.directionFlipCount, 0)
        XCTAssertEqual(report.audioEventCount, 0)
        XCTAssertEqual(report.recordMovementEventCount, 0)
        XCTAssertFalse(report.clippingDetected)
        XCTAssertFalse(report.lowSignalDetected)
        XCTAssertFalse(report.timingVarianceFlagged)
        XCTAssertFalse(report.directionConflictDetected)
        // duration 0.5 is below missingPhraseRegionMinDuration (1.0)
        XCTAssertFalse(report.incompletePhraseDetected)
    }

    func testIncompletePhraseDetectedAtDurationAboveMinimum() {
        let snapshot = makeSnapshot(peakLevels: [], movements: [])
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 5.0,
            now: Self.referenceDate
        )
        XCTAssertTrue(report.incompletePhraseDetected)
        XCTAssertEqual(report.audioEventCount, 0)
    }

    // MARK: - Clipping

    func testClippingDetectedAtOrAboveThreshold() throws {
        let snapshot = makeSnapshot(
            peakLevels: [0.40, 0.45, 0.99, 0.38],
            rmsLevels: [0.20, 0.21, 0.50, 0.18]
        )
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.0,
            now: Self.referenceDate
        )
        XCTAssertTrue(report.clippingDetected)
        XCTAssertEqual(try XCTUnwrap(report.peakLevelMax), 0.99, accuracy: 1e-9)
        XCTAssertEqual(report.audioEventCount, 4)
    }

    func testClippingNotDetectedBelowThreshold() throws {
        let snapshot = makeSnapshot(peakLevels: [0.40, 0.45, 0.97, 0.38])
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.0,
            now: Self.referenceDate
        )
        XCTAssertFalse(report.clippingDetected)
        XCTAssertEqual(try XCTUnwrap(report.peakLevelMax), 0.97, accuracy: 1e-9)
    }

    // MARK: - Low signal

    func testLowSignalDetectedWhenMedianBelowThreshold() throws {
        let snapshot = makeSnapshot(peakLevels: Array(repeating: 0.05, count: 6))
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 3.0,
            now: Self.referenceDate
        )
        XCTAssertTrue(report.lowSignalDetected)
        XCTAssertEqual(try XCTUnwrap(report.peakLevelMedian), 0.05, accuracy: 1e-9)
    }

    func testLowSignalNotDetectedWhenMedianAboveThreshold() {
        let snapshot = makeSnapshot(peakLevels: [0.05, 0.50, 0.50, 0.50, 0.50, 0.50])
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 3.0,
            now: Self.referenceDate
        )
        XCTAssertFalse(report.lowSignalDetected)
    }

    // MARK: - Timing variance

    func testTimingVarianceFlaggedForIrregularGaps() {
        let snapshot = makeSnapshot(
            startTimes: [0.0, 1.0, 1.05, 2.5],
            peakLevels: [0.4, 0.4, 0.4, 0.4]
        )
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 3.0,
            now: Self.referenceDate
        )
        XCTAssertTrue(report.timingVarianceFlagged)
        XCTAssertNotNil(report.interOnsetGapMean)
        XCTAssertNotNil(report.interOnsetGapStdev)
    }

    func testTimingVarianceNotFlaggedForRegularGaps() {
        let snapshot = makeSnapshot(
            startTimes: [0.0, 0.5, 1.0, 1.5, 2.0],
            peakLevels: [0.4, 0.4, 0.4, 0.4, 0.4]
        )
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.5,
            now: Self.referenceDate
        )
        XCTAssertFalse(report.timingVarianceFlagged)
        XCTAssertNotNil(report.interOnsetGapMean)
        XCTAssertNotNil(report.interOnsetGapStdev)
    }

    func testTimingStatisticsNilForFewerThanFourOnsets() {
        let snapshot = makeSnapshot(
            startTimes: [0.0, 0.5, 1.0],
            peakLevels: [0.4, 0.4, 0.4]
        )
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.0,
            now: Self.referenceDate
        )
        XCTAssertNil(report.interOnsetGapMean)
        XCTAssertNil(report.interOnsetGapStdev)
        XCTAssertFalse(report.timingVarianceFlagged)
    }

    // MARK: - Direction conflict

    func testDirectionConflictDetectedForRapidFlips() {
        let directions = Array(repeating: ["forward", "backward"], count: 6).flatMap { $0 }
        let movements = directions.enumerated().map { index, direction in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: Double(index) * 0.08,
                endTime: Double(index) * 0.08 + 0.06,
                startPosition: 0.0,
                endPosition: 1.0,
                direction: direction,
                movementKind: .normalPush,
                speed: 1.0,
                confidence: 0.5,
                source: "detected"
            )
        }
        let snapshot = makeSnapshot(peakLevels: [], movements: movements)
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 1.0,
            now: Self.referenceDate
        )
        XCTAssertTrue(report.directionConflictDetected)
        XCTAssertEqual(report.directionFlipCount, 11)
        XCTAssertEqual(report.recordMovementEventCount, 12)
    }

    func testDirectionConflictNotDetectedBelowMovementMinimum() {
        let directions = ["forward", "backward", "forward", "backward",
                          "forward", "backward", "forward", "backward",
                          "forward", "backward", "forward"]
        let movements = directions.enumerated().map { index, direction in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: Double(index) * 0.08,
                endTime: Double(index) * 0.08 + 0.06,
                startPosition: 0.0,
                endPosition: 1.0,
                direction: direction,
                movementKind: .normalPush,
                speed: 1.0,
                confidence: 0.5,
                source: "detected"
            )
        }
        let snapshot = makeSnapshot(peakLevels: [], movements: movements)
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 1.0,
            now: Self.referenceDate
        )
        XCTAssertFalse(report.directionConflictDetected)
        XCTAssertEqual(report.recordMovementEventCount, 11)
    }

    // MARK: - JSON

    func testReportRoundTripsThroughJSON() throws {
        let snapshot = makeSnapshot(
            startTimes: [0.0, 0.5, 1.0, 1.5, 2.0],
            peakLevels: [0.30, 0.35, 0.32, 0.34, 0.31],
            rmsLevels: [0.12, 0.13, 0.12, 0.14, 0.12]
        )
        let original = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.5,
            now: Self.referenceDate
        )
        let data = try encoder.encode(original)
        let restored = try decoder.decode(SessionQualityReport.self, from: data)
        XCTAssertEqual(original, restored)
        XCTAssertEqual(restored.schemaVersion, SessionQualityReport.currentSchemaVersion)
    }

    func testNilNumericFieldsAreOmittedFromJSON() throws {
        // Per user spec: "If a metric cannot be truthfully computed:
        // leave nil, omit from export". Swift Codable's default
        // synthesised behaviour for `Optional` properties is
        // `encodeIfPresent`, which omits the key entirely when the
        // value is nil. This test pins that behaviour.
        let snapshot = makeSnapshot(peakLevels: [], movements: [])
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 0.5,
            now: Self.referenceDate
        )
        let data = try encoder.encode(report)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["peakLevelMax"])
        XCTAssertNil(json["peakLevelMedian"])
        XCTAssertNil(json["audioEventRMSMedian"])
        XCTAssertNil(json["interOnsetGapMean"])
        XCTAssertNil(json["interOnsetGapStdev"])
        XCTAssertNil(json["directionFlipsPerSecond"])
        // Booleans and counts must still be present.
        XCTAssertEqual(json["clippingDetected"] as? Bool, false)
        XCTAssertEqual(json["incompletePhraseDetected"] as? Bool, false)
        XCTAssertEqual(json["audioEventCount"] as? Int, 0)
    }

    func testReportDecodesWhenOptionalNumericKeysAreMissing() throws {
        let stub = """
        {
          "schemaVersion": "scratchlab_session_quality_v1",
          "analyzedAt": "2026-05-26T00:00:00Z",
          "takeDurationSeconds": 1.0,
          "audioEventCount": 0,
          "recordMovementEventCount": 0,
          "directionFlipCount": 0,
          "clippingDetected": false,
          "lowSignalDetected": false,
          "timingVarianceFlagged": false,
          "incompletePhraseDetected": false,
          "directionConflictDetected": false
        }
        """
        let data = Data(stub.utf8)
        let report = try decoder.decode(SessionQualityReport.self, from: data)
        XCTAssertNil(report.peakLevelMax)
        XCTAssertNil(report.peakLevelMedian)
        XCTAssertNil(report.audioEventRMSMedian)
        XCTAssertNil(report.interOnsetGapMean)
        XCTAssertNil(report.interOnsetGapStdev)
        XCTAssertNil(report.directionFlipsPerSecond)
    }

    func testAudioEventRMSMedianComputedFromEvents() throws {
        let snapshot = makeSnapshot(
            peakLevels: [0.40, 0.40, 0.40],
            rmsLevels: [0.10, 0.20, 0.30]
        )
        let report = SessionQualityAnalyzer.analyze(
            snapshot: snapshot,
            takeDuration: 2.0,
            now: Self.referenceDate
        )
        XCTAssertEqual(try XCTUnwrap(report.audioEventRMSMedian), 0.20, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        startTimes: [Double]? = nil,
        peakLevels: [Double],
        rmsLevels: [Double]? = nil,
        movements: [CaptureCore.DetectedNotationRecordMovementEvent] = []
    ) -> CaptureCore.DetectedNotationSnapshot {
        let times = startTimes ?? peakLevels.enumerated().map { index, _ in Double(index) * 0.5 }
        let rms = rmsLevels ?? peakLevels.map { $0 * 0.4 }
        let events = zip(zip(times, peakLevels), rms).map { pair, rmsLevel in
            CaptureCore.DetectedNotationAudioEvent(
                startTime: pair.0,
                endTime: pair.0 + 0.05,
                duration: 0.05,
                peakLevel: pair.1,
                rmsLevel: rmsLevel,
                confidence: 0.5,
                eventKind: "scratchBurst",
                source: "audio"
            )
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: movements,
            audioEvents: events,
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
    }
}
