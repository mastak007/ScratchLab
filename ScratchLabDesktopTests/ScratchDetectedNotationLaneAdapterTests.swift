// ScratchDetectedNotationLaneAdapterTests — unit tests for the DEBUG detected-notation
// lane adapter bridge. Tests decode, mapping, edge cases, and rejection of old format.
//
// Uses embedded JSON strings (no fixture files) to keep the slice small and avoid
// pbxproj resource risk.

import XCTest
@testable import ScratchLab

final class ScratchDetectedNotationLaneAdapterTests: XCTestCase {

    // MARK: - Embedded test JSON (no fixture files)

    /// Minimal detected-notation document with one forward stroke.
    private var oneStrokeJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"test","takeID":"t1","takeNumber":1,"scratchType":"baby_scratch","bpm":70,"captureMode":"timed_click","notationSource":"detected","detectionSources":["motion"],"labelSource":"detected","labelConfidence":null,"notationConfidence":0.8,"recordMovementEvents":[{"direction":"forward","startTime":1.0,"endTime":2.0,"startPosition":0.1,"endPosition":0.3,"movementKind":"normalPush","speed":0.2,"confidence":0.66,"source":"fused"}],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":{"beatsPerBar":4,"bpm":70,"countInBeats":4},"notes":""}
        """
    }

    /// Detected-notation document with two strokes (forward + backward) — multi-event.
    private var twoStrokeJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"test","takeID":"t2","takeNumber":2,"scratchType":"baby_scratch","bpm":90,"captureMode":"timed_click","notationSource":"detected","detectionSources":["motion","audio"],"labelSource":"detected","labelConfidence":null,"notationConfidence":0.9,"recordMovementEvents":[{"direction":"forward","startTime":1.0,"endTime":1.5,"startPosition":0.1,"endPosition":0.4,"movementKind":"normalPush","speed":0.6,"confidence":0.75,"source":"fused"},{"direction":"backward","startTime":2.0,"endTime":2.3,"startPosition":0.4,"endPosition":0.15,"movementKind":"normalPush","speed":0.83,"confidence":0.55,"source":"detected"}],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":{"beatsPerBar":4,"bpm":90,"countInBeats":4},"notes":""}
        """
    }

    /// Detected-notation document with zero recordMovementEvents.
    private var emptyEventsJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"test","takeID":"t3","takeNumber":3,"scratchType":"baby_scratch","bpm":70,"captureMode":"timed_click","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":{"beatsPerBar":4,"bpm":70,"countInBeats":4},"notes":"No notation events detected"}
        """
    }

    /// Old RANE-style ScratchTimeline JSON — must be rejected by this adapter.
    private var oldFormatJSON: String {
        """
        {"events":[{"timeSeconds":0.1,"cc6Step":1},{"timeSeconds":0.2,"cc6Step":-1}]}
        """
    }

    /// Malformed JSON that is neither format.
    private var garbageJSON: String {
        "not json at all"
    }

    // MARK: - Decode success

    func testDecodesOneStroke() throws {
        let data = Data(oneStrokeJSON.utf8)
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(from: data)
        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.warnings.count, 0)

        let s = model.strokes[0]
        XCTAssertEqual(s.direction, .forward)
        XCTAssertEqual(s.startTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.endTime, 2.0, accuracy: 1e-9)
        // position delta: abs(0.3 - 0.1) = 0.2
        XCTAssertEqual(s.travelPercent, 0.2, accuracy: 1e-9)
        // fused + confidence 0.66 >= 0.45 → audible
        XCTAssertEqual(s.audibleState, .audible)
    }

    func testDecodesTwoStrokes() throws {
        let data = Data(twoStrokeJSON.utf8)
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(from: data)
        XCTAssertEqual(model.strokes.count, 2)

        // Stroke 1: forward, delta = 0.3
        let s1 = model.strokes[0]
        XCTAssertEqual(s1.direction, .forward)
        XCTAssertEqual(s1.travelPercent, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s1.audibleState, .audible)

        // Stroke 2: backward → .reverse, delta = 0.25
        let s2 = model.strokes[1]
        XCTAssertEqual(s2.direction, .reverse)
        XCTAssertEqual(s2.travelPercent, 0.25, accuracy: 1e-9)
        // "detected" source with confidence 0.55 >= 0.45 → audible
        XCTAssertEqual(s2.audibleState, .audible)
    }

    // MARK: - Empty events → clean failure

    func testEmptyMovementEventsThrows() {
        let data = Data(emptyEventsJSON.utf8)
        XCTAssertThrowsError(try ScratchDetectedNotationLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchDetectedNotationLaneAdapterError.emptyMovementEvents = error else {
                XCTFail("Expected emptyMovementEvents, got \(error)")
                return
            }
        }
    }

    // MARK: - Old format rejection

    func testRejectsOldRaneFormat() {
        let data = Data(oldFormatJSON.utf8)
        XCTAssertThrowsError(try ScratchDetectedNotationLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchDetectedNotationLaneAdapterError.notDetectedNotationFormat = error else {
                XCTFail("Expected notDetectedNotationFormat, got \(error)")
                return
            }
        }
    }

    func testRejectsGarbage() {
        let data = Data(garbageJSON.utf8)
        XCTAssertThrowsError(try ScratchDetectedNotationLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchDetectedNotationLaneAdapterError.notDetectedNotationFormat = error else {
                XCTFail("Expected notDetectedNotationFormat, got \(error)")
                return
            }
        }
    }

    // MARK: - Deterministic

    func testDeterministic() {
        let data = Data(twoStrokeJSON.utf8)
        let a = try! ScratchDetectedNotationLaneAdapter.previewModel(from: data)
        let b = try! ScratchDetectedNotationLaneAdapter.previewModel(from: data)
        XCTAssertEqual(a, b)
    }

    // MARK: - Audible state edge cases

    func testLowConfidenceBecomesUnknown() throws {
        let json = """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"t","takeID":"t","takeNumber":1,"scratchType":"baby","bpm":70,"captureMode":"free","notationSource":"detected","detectionSources":["motion"],"labelSource":"detected","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[{"direction":"forward","startTime":1.0,"endTime":2.0,"startPosition":0.1,"endPosition":0.2,"movementKind":"normalPush","speed":0.1,"confidence":0.30,"source":"detected"}],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":null,"notes":""}
        """
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(from: Data(json.utf8))
        XCTAssertEqual(model.strokes[0].audibleState, .unknown)
    }

    func testUnknownSourceBecomesUnknown() throws {
        let json = """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"t","takeID":"t","takeNumber":1,"scratchType":"baby","bpm":70,"captureMode":"free","notationSource":"detected","detectionSources":[],"labelSource":"detected","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[{"direction":"forward","startTime":1.0,"endTime":2.0,"startPosition":0.1,"endPosition":0.2,"movementKind":"normalPush","speed":0.1,"confidence":null,"source":null}],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":null,"notes":""}
        """
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(from: Data(json.utf8))
        XCTAssertEqual(model.strokes[0].audibleState, .unknown)
    }

    // MARK: - Malformed events skipped (not crashed)

    func testSkipsMalformedEvents() throws {
        // One event missing startTime — should be skipped; the other valid
        let json = """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"t","takeID":"t","takeNumber":1,"scratchType":"baby","bpm":70,"captureMode":"free","notationSource":"detected","detectionSources":[],"labelSource":"detected","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[{"direction":"forward","startTime":null,"endTime":2.0,"startPosition":0.1,"endPosition":0.3},{"direction":"backward","startTime":3.0,"endTime":4.0,"startPosition":0.3,"endPosition":0.1}],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":null,"notes":""}
        """
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(from: Data(json.utf8))
        // Only the valid backward stroke survives
        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.strokes[0].direction, .reverse)
    }

    // MARK: - Integration: display model round-trip

    func testIntegrationWithDisplayAdapter() throws {
        let data = Data(twoStrokeJSON.utf8)
        let preview = try ScratchDetectedNotationLaneAdapter.previewModel(from: data)
        let display = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview, fullScaleTravelPercent: 1.0)
        XCTAssertEqual(display.strokes.count, 2)
        XCTAssertTrue(display.scaleIsUsable)

        let stats = display.stats
        XCTAssertEqual(stats.totalStrokes, 2)
        // Both are meaningful (travelPercent >= 1.0? No — 0.3 and 0.25, so both are < 1.0)
        // Actually with fullScaleTravelPercent=1.0, travelPercent 0.3/0.25 are both < 1.0
        // So they should be microTravel
        XCTAssertEqual(stats.meaningfulTravelStrokes, 0)
        XCTAssertEqual(stats.microTravelStrokes, 2)
        XCTAssertEqual(stats.zeroDurationStrokes, 0)
    }
}
