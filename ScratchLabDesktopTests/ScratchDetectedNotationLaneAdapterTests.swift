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

    // MARK: - CC6 platter fallback tests (DEBUG CC6 platter proxy)

    /// Minimal detected-notation with empty recordMovement but RANE ONE MKII CC6 data.
    /// Two clear strokes: forward 120→125 (delta 5), backward 125→122 (delta 3).
    private var cc6TwoStrokeJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"cc6-test","takeID":"t1","takeNumber":1,"scratchType":"baby_scratch","bpm":95,"captureMode":"timed_click","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[{"takeRelativeTime":1.0,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":120,"normalizedValue":0.9449,"mappedControl":null},{"takeRelativeTime":1.1,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":122,"normalizedValue":0.9606,"mappedControl":null},{"takeRelativeTime":1.2,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":125,"normalizedValue":0.9843,"mappedControl":null},{"takeRelativeTime":1.3,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":124,"normalizedValue":0.9764,"mappedControl":null},{"takeRelativeTime":1.4,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":122,"normalizedValue":0.9606,"mappedControl":null}],"beatGrid":{"beatsPerBar":4,"bpm":95,"countInBeats":4},"notes":""}
        """
    }

    /// Detected-notation with CC6 wrap: 126→127→0→1 (forward wrap crossing the 127→0 boundary).
    private var cc6WrapJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"cc6-wrap","takeID":"t2","takeNumber":2,"scratchType":"baby_scratch","bpm":95,"captureMode":"timed_click","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[{"takeRelativeTime":2.0,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":126,"normalizedValue":0.9921,"mappedControl":null},{"takeRelativeTime":2.1,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":127,"normalizedValue":1.0,"mappedControl":null},{"takeRelativeTime":2.2,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":0,"normalizedValue":0.0,"mappedControl":null},{"takeRelativeTime":2.3,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":1,"normalizedValue":0.0079,"mappedControl":null},{"takeRelativeTime":2.4,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":2,"normalizedValue":0.0157,"mappedControl":null}],"beatGrid":{"beatsPerBar":4,"bpm":95,"countInBeats":4},"notes":""}
        """
    }

    /// Detected-notation with CC6 direction changes.
    private var cc6DirectionChangeJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"cc6-dir","takeID":"t3","takeNumber":3,"scratchType":"baby_scratch","bpm":95,"captureMode":"timed_click","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[{"takeRelativeTime":3.0,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":10,"normalizedValue":0.0787,"mappedControl":null},{"takeRelativeTime":3.1,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":20,"normalizedValue":0.1575,"mappedControl":null},{"takeRelativeTime":3.2,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":30,"normalizedValue":0.2362,"mappedControl":null},{"takeRelativeTime":3.3,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":28,"normalizedValue":0.2205,"mappedControl":null},{"takeRelativeTime":3.4,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":25,"normalizedValue":0.1969,"mappedControl":null},{"takeRelativeTime":3.5,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":20,"normalizedValue":0.1575,"mappedControl":null},{"takeRelativeTime":3.6,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":30,"normalizedValue":0.2362,"mappedControl":null},{"takeRelativeTime":3.7,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":40,"normalizedValue":0.315,"mappedControl":null},{"takeRelativeTime":3.8,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":50,"normalizedValue":0.3937,"mappedControl":null}],"beatGrid":{"beatsPerBar":4,"bpm":95,"countInBeats":4},"notes":""}
        """
    }

    /// Detected-notation with CC6 jitter — a single-sample micro-reversal.
    private var cc6JitterJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"cc6-jitter","takeID":"t4","takeNumber":4,"scratchType":"baby_scratch","bpm":95,"captureMode":"timed_click","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[{"takeRelativeTime":4.0,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":50,"normalizedValue":0.3937,"mappedControl":null},{"takeRelativeTime":4.1,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":55,"normalizedValue":0.4331,"mappedControl":null},{"takeRelativeTime":4.2,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":54,"normalizedValue":0.4252,"mappedControl":null},{"takeRelativeTime":4.3,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":58,"normalizedValue":0.4567,"mappedControl":null},{"takeRelativeTime":4.4,"deviceName":"Rane ONE MKII","channel":7,"controller":6,"value":62,"normalizedValue":0.4882,"mappedControl":null}],"beatGrid":{"beatsPerBar":4,"bpm":95,"countInBeats":4},"notes":""}
        """
    }

    // MARK: CC6 → strokes

    func testRaneCC6ProducesStrokes() throws {
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(cc6TwoStrokeJSON.utf8))
        // Forward 120→122→125 (accumulated delta +5), then backward 125→124→122 (delta -3)
        XCTAssertGreaterThanOrEqual(model.strokes.count, 1)
        // First stroke is forward
        XCTAssertEqual(model.strokes[0].direction, .forward)
    }

    func testRaneCC6HandlesWraps() throws {
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(cc6WrapJSON.utf8))
        // 126→127→0→1→2: unwrapped, that's 126→127→128→129→130 = delta of 4
        XCTAssertGreaterThanOrEqual(model.strokes.count, 1)
        // travelPercent = accumulated delta / 127 = 4/127 ≈ 0.031
        let stroke = model.strokes[0]
        XCTAssertEqual(stroke.travelPercent, 4.0 / 127.0, accuracy: 0.001)
    }

    func testRaneCC6DirectionChangesProduceMultipleStrokes() throws {
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(cc6DirectionChangeJSON.utf8))
        // Forward: 10→20→30 (delta +20), then backward: 30→28→25→20 (delta -10),
        // then forward: 20→30→40→50 (delta +30). Should produce ≥ 2 strokes.
        XCTAssertGreaterThanOrEqual(model.strokes.count, 2)
        // Check alternating directions
        let dirs = model.strokes.map(\.direction)
        for i in 1..<dirs.count {
            XCTAssertNotEqual(dirs[i], dirs[i - 1], "Adjacent strokes must alternate direction")
        }
    }

    func testRaneCC6AudibleStateIsUnknown() throws {
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(cc6TwoStrokeJSON.utf8))
        // CC6 events carry no audio confidence — all strokes should be .unknown
        for stroke in model.strokes {
            XCTAssertEqual(stroke.audibleState, .unknown,
                "CC6-derived strokes must have audibleState = .unknown")
        }
    }

    func testRaneCC6SkipsJitter() throws {
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(cc6JitterJSON.utf8))
        // 50→55 (+5), then 55→54 (-1 jitter), then 54→58→62 (+8 total).
        // The single -1 step is within jitterSteps (3). Should produce 1 stroke, not 3.
        // With +5 -1 +8 merged = +12 total in one forward stroke.
        XCTAssertEqual(model.strokes.count, 1, "Single-sample micro-reversal should be merged as jitter")
        XCTAssertEqual(model.strokes[0].direction, .forward)
        XCTAssertEqual(model.strokes[0].travelPercent, 12.0 / 127.0, accuracy: 0.001)
    }

    // MARK: CC6 empty / missing

    func testEmptyRecordMovementAndNoCC6Fails() {
        let json = """
        {"schemaVersion":"scratchlab_detected_notation_v1","sessionID":"t","takeID":"t","takeNumber":1,"scratchType":"baby","bpm":70,"captureMode":"free","notationSource":"unavailable","detectionSources":[],"labelSource":"unknown","labelConfidence":null,"notationConfidence":null,"recordMovementEvents":[],"audioEvents":[],"faderEvents":[],"mixerMidiEvents":[],"beatGrid":null,"notes":""}
        """
        XCTAssertThrowsError(try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(json.utf8))) { error in
            guard case ScratchDetectedNotationLaneAdapterError.emptyMovementEvents = error else {
                XCTFail("Expected emptyMovementEvents, got \(error)")
                return
            }
        }
    }

    // MARK: Existing path not broken

    func testExistingRecordMovementPathStillWorks() throws {
        // Uses the same JSON as testDecodesOneStroke — recordMovementEvents present,
        // mixerMidiEvents absent. Must load successfully via Path 1.
        let model = try ScratchDetectedNotationLaneAdapter.previewModel(
            from: Data(oneStrokeJSON.utf8))
        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.strokes[0].direction, .forward)
    }
}
