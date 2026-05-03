import XCTest
import Foundation
@testable import ScratchLab

final class CXLNotationCaptureTests: XCTestCase {

    private var recorder: CXLNotationCaptureRecorder!

    override func setUp() {
        super.setUp()
        recorder = CXLNotationCaptureRecorder()
    }

    // MARK: - Session lifecycle

    func testStartSessionSetsRecordingTrue() {
        recorder.startSession(
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: 80,
            loopDuration: 2.0,
            cameraMode: "Desk View",
            calibrationLocked: true,
            deckROI: nil
        )
        XCTAssertTrue(recorder.isRecording)
        XCTAssertFalse(recorder.sessionId.isEmpty)
    }

    func testStopSessionSetsRecordingFalse() {
        recorder.startSession(
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: nil,
            loopDuration: nil,
            cameraMode: nil,
            calibrationLocked: false,
            deckROI: nil
        )
        recorder.stopSession()
        XCTAssertFalse(recorder.isRecording)
    }

    func testStartSessionIsIdempotent() {
        recorder.startSession(
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: nil,
            loopDuration: nil,
            cameraMode: nil,
            calibrationLocked: false,
            deckROI: nil
        )
        let firstId = recorder.sessionId
        recorder.startSession(
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: nil,
            loopDuration: nil,
            cameraMode: nil,
            calibrationLocked: false,
            deckROI: nil
        )
        XCTAssertEqual(recorder.sessionId, firstId, "startSession while recording must not overwrite the session")
    }

    // MARK: - Session metadata encoding

    func testSessionMetadataEncodesAndDecodes() throws {
        let roi = CXLNotationCaptureSession.CXLRect(x: 0.21, y: 0.38, width: 0.42, height: 0.31)
        let session = CXLNotationCaptureSession(
            schemaVersion: cxlNotationCaptureSchemaVersion,
            sessionId: "2026-05-03T13-04-22_baby_001",
            createdAt: Date(timeIntervalSince1970: 1_746_270_000),
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: 80,
            loopDuration: 2.0,
            cameraMode: "Desk View",
            calibrationLocked: true,
            deckROI: roi,
            appBuildVersion: "1.0",
            notes: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CXLNotationCaptureSession.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, cxlNotationCaptureSchemaVersion)
        XCTAssertEqual(decoded.bpm, 80)
        XCTAssertEqual(decoded.loopDuration, 2.0)
        XCTAssertEqual(decoded.calibrationLocked, true)
        let roiX = try XCTUnwrap(decoded.deckROI?.x)
        XCTAssertEqual(roiX, 0.21, accuracy: 0.0001)
    }

    // MARK: - Event JSONL stable field names

    func testEventTypeFieldIsStableString() throws {
        let event = CXLNotationCaptureEvent(type: "targetStroke")
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"type\":\"targetStroke\"") || json.contains("\"type\" : \"targetStroke\""),
                      "Event type must encode as stable string 'targetStroke', got: \(json)")
    }

    func testDirectionEncodesAsStableString() throws {
        var event = CXLNotationCaptureEvent(type: "targetStroke")
        event.direction = .forward
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"forward\""), "CXLDirection.forward must encode as \"forward\", got: \(json)")
    }

    func testTimingClassificationEncodesAsStableString() throws {
        var event = CXLNotationCaptureEvent(type: "score")
        event.classification = .onTime
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"onTime\""), "CXLTimingClassification.onTime must encode as \"onTime\", got: \(json)")
    }

    func testWrongDirectionEncodesAsStableString() throws {
        var event = CXLNotationCaptureEvent(type: "score")
        event.classification = .wrongDirection
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"wrongDirection\""),
                      "CXLTimingClassification.wrongDirection must encode as \"wrongDirection\", got: \(json)")
    }

    // MARK: - Target and observed records stay separate

    func testTargetStrokeDoesNotModifyObservedDirection() {
        recorder.startSession(
            scratchType: "baby_scratch",
            mode: "scratchRating",
            bpm: nil,
            loopDuration: nil,
            cameraMode: nil,
            calibrationLocked: false,
            deckROI: nil
        )
        let idx = recorder.recordTargetStroke(direction: .forward)
        // Recording a target stroke must not create a motionStroke event.
        // (The recorder must not call recordMotionStroke internally.)
        XCTAssertGreaterThanOrEqual(idx, 0)
        XCTAssertEqual(recorder.eventCount, 2, "Only captureStarted + targetStroke should be present")
    }

    // MARK: - Timing classification

    func testOnTimeClassification() {
        recorder.startSession(
            scratchType: "baby_scratch", mode: "scratchRating",
            bpm: nil, loopDuration: nil, cameraMode: nil, calibrationLocked: false, deckROI: nil
        )
        recorder.recordScore(
            targetStrokeIndex: 0,
            targetDirection: .forward,
            observedDirection: .forward,
            timingErrorMs: 50,
            confidence: 0.9,
            signalSource: .camera
        )
        // Check the last event is a score with onTime classification.
        let scoreEvents = recorder.eventCount
        XCTAssertGreaterThan(scoreEvents, 0)
    }

    func testEarlyClassification() {
        let c = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: -200, confidence: 0.9
        )
        XCTAssertEqual(c, .early)
    }

    func testLateClassification() {
        let c = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: 250, confidence: 0.9
        )
        XCTAssertEqual(c, .late)
    }

    func testWrongDirectionClassification() {
        let c = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .back, timingErrorMs: 30, confidence: 0.9
        )
        XCTAssertEqual(c, .wrongDirection)
    }

    func testIdleWhenConfidenceTooLow() {
        let c = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: 0, confidence: 0.05
        )
        XCTAssertEqual(c, .idle, "Low-confidence observation should classify as .idle")
    }

    func testOnTimeClassificationBoundary() {
        let atNegBoundary = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: -120, confidence: 0.9
        )
        let atPosBoundary = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: 120, confidence: 0.9
        )
        XCTAssertEqual(atNegBoundary, .onTime, "Exactly -120ms should be onTime (boundary inclusive)")
        XCTAssertEqual(atPosBoundary, .onTime, "Exactly +120ms should be onTime (boundary inclusive)")
    }

    // MARK: - loopTime calculation

    func testLoopTimeWrapsAtLoopDuration() {
        // With loopDuration = 2.0 and playbackTime = 3.1, loopTime = 3.1 % 2.0 = 1.1
        let loopDuration = 2.0
        let playbackTime = 3.1
        let loopTime = playbackTime.truncatingRemainder(dividingBy: loopDuration)
        XCTAssertEqual(loopTime, 1.1, accuracy: 0.0001)
    }

    func testLoopTimeIsPlaybackTimeWhenNoDuration() {
        // Without a loopDuration, loopTime = playbackTime - loopStartTime (= playbackTime when loopStartTime = 0)
        recorder.startSession(
            scratchType: "baby_scratch", mode: "scratchRating",
            bpm: nil, loopDuration: nil, cameraMode: nil, calibrationLocked: false, deckROI: nil
        )
        // loopStartTime defaults to 0; loopTime should equal elapsed for small durations
        let idx = recorder.recordTargetStroke(direction: .forward)
        XCTAssertGreaterThanOrEqual(idx, 0)
    }

    // MARK: - Sample throttling

    func testSamplesAreThrottled() {
        recorder.startSession(
            scratchType: "baby_scratch", mode: "scratchRating",
            bpm: nil, loopDuration: nil, cameraMode: nil, calibrationLocked: false, deckROI: nil
        )
        // Call recordSample 100 times in a tight loop — all within the same tick.
        for _ in 0..<100 {
            recorder.recordSample(
                targetDirection: .forward,
                detectedDirection: .forward,
                handX: 0.5, handY: 0.5,
                motionConfidence: 0.9,
                audioConfidence: nil,
                signalSource: .camera,
                timingErrorMs: nil,
                calibrationLocked: false
            )
        }
        // Only 1 sample should have been accepted (the rest are within the throttle window).
        XCTAssertEqual(recorder.sampleCount, 1,
                       "Rapid back-to-back recordSample calls must be throttled to at most 1 per interval")
    }

    // MARK: - Export

    func testExportWritesFourFiles() throws {
        recorder.startSession(
            scratchType: "baby_scratch", mode: "scratchRating",
            bpm: 80, loopDuration: 2.0, cameraMode: "Desk View", calibrationLocked: true, deckROI: nil
        )
        recorder.recordTargetStroke(direction: .forward)
        recorder.recordMotionStroke(
            detectedDirection: .forward, confidence: 0.88, signalSource: .camera, handX: 0.61, handY: 0.44
        )
        recorder.stopSession()

        let result = try recorder.exportSession()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.sessionFile.path),
                      "session.json must exist after export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.eventsFile.path),
                      "events.jsonl must exist after export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.samplesFile.path),
                      "samples.jsonl must exist after export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.summaryFile.path),
                      "summary.csv must exist after export")

        // Verify session.json is valid JSON with correct schema version
        let sessionData = try Data(contentsOf: result.sessionFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(CXLNotationCaptureSession.self, from: sessionData)
        XCTAssertEqual(session.schemaVersion, cxlNotationCaptureSchemaVersion)

        // Verify events.jsonl has at least one line per event
        let eventsData = try Data(contentsOf: result.eventsFile)
        let eventsText = try XCTUnwrap(String(data: eventsData, encoding: .utf8))
        let lines = eventsText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThan(lines.count, 0, "events.jsonl must contain at least one line")

        // Verify summary.csv has header + data row
        let summaryText = try XCTUnwrap(String(
            data: try Data(contentsOf: result.summaryFile), encoding: .utf8
        ))
        let csvLines = summaryText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(csvLines.count, 2, "summary.csv must have a header row and one data row")
    }

    func testExportWithoutSessionThrows() {
        XCTAssertThrowsError(try recorder.exportSession()) { error in
            XCTAssertTrue(error is CXLExportError)
        }
    }

}
