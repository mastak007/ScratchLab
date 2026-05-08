import XCTest
@testable import ScratchNotation

final class ScratchNotationGeneratorTests: XCTestCase {

    let generator = ScratchNotationGenerator()

    // MARK: - Forward/back audio + vision combine into stroke notation

    func test_audioOnsetsWithVisualMotion_produceStrokeEventsWithDirection() {
        let timeline = generator.generate(
            takeID: "test_take_01",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 3.0,
            bpm: 120,
            audioOnsets: [
                AudioOnsetEvent(startTime: 0.5, endTime: 1.0, confidence: 0.9),
                AudioOnsetEvent(startTime: 1.5, endTime: 2.0, confidence: 0.85)
            ],
            audioSilences: [
                AudioSilenceEvent(startTime: 1.0, endTime: 1.5, confidence: 0.95),
                AudioSilenceEvent(startTime: 2.0, endTime: 3.0, confidence: 0.95)
            ],
            visualMotion: [
                VisualMotionEvent(direction: .forward, startTime: 0.5, endTime: 1.0, confidence: 0.8),
                VisualMotionEvent(direction: .back,    startTime: 1.5, endTime: 2.0, confidence: 0.8)
            ],
            beatGrid: nil
        )

        let strokes = timeline.events.filter { $0.type == .stroke }
        XCTAssertEqual(strokes.count, 2, "Expected exactly two stroke events")
        XCTAssertEqual(strokes[0].direction, .forward)
        XCTAssertEqual(strokes[1].direction, .back)
        for stroke in strokes {
            XCTAssertEqual(stroke.source, .fused)
            XCTAssertGreaterThan(stroke.confidence, 0.7,
                "Fused stroke confidence should reflect both signals")
            XCTAssertFalse(stroke.approved)
        }
        XCTAssertEqual(timeline.approvalState, .inferred)
    }

    // MARK: - Silence gaps

    func test_silenceWithStillVisual_producesHoldEvent() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 2.0,
            audioOnsets: [],
            audioSilences: [AudioSilenceEvent(startTime: 0.0, endTime: 2.0, confidence: 0.95)],
            visualMotion: [VisualMotionEvent(direction: .still, startTime: 0.0, endTime: 2.0, confidence: 0.8)],
            beatGrid: nil
        )

        XCTAssertEqual(timeline.events.count, 1)
        let event = timeline.events[0]
        XCTAssertEqual(event.type, .hold)
        XCTAssertEqual(event.direction, .none)
        XCTAssertEqual(event.source, .fused)
    }

    func test_silenceWithoutVisual_producesSilenceEvent() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 2.0,
            audioOnsets: [],
            audioSilences: [AudioSilenceEvent(startTime: 0.0, endTime: 2.0, confidence: 0.95)],
            visualMotion: [],
            beatGrid: nil
        )
        XCTAssertEqual(timeline.events.count, 1)
        XCTAssertEqual(timeline.events[0].type, .silence)
        XCTAssertEqual(timeline.events[0].direction, .none)
        XCTAssertEqual(timeline.events[0].source, .audio)
    }

    // MARK: - Missing visual direction

    func test_audioOnsetWithoutVisual_givesUnknownDirection() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 2.0,
            audioOnsets: [AudioOnsetEvent(startTime: 0.5, endTime: 1.0, confidence: 0.9)],
            audioSilences: [],
            visualMotion: [],
            beatGrid: nil
        )
        let strokes = timeline.events.filter { $0.type == .stroke }
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(strokes[0].direction, .unknown)
        XCTAssertEqual(strokes[0].source, .audio)
        // The direction is unknown because vision is missing — confidence should
        // not be silently inflated to look like a fused result.
        XCTAssertEqual(strokes[0].confidence, 0.9, accuracy: 0.0001)
    }

    // MARK: - Missing audio onset

    func test_visualMotionWithoutAudio_lowConfidenceVisionEvent() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 2.0,
            audioOnsets: [],
            audioSilences: [],
            visualMotion: [VisualMotionEvent(direction: .forward, startTime: 0.5, endTime: 1.0, confidence: 0.9)],
            beatGrid: nil
        )

        let strokes = timeline.events.filter { $0.type == .stroke }
        XCTAssertEqual(strokes.count, 1, "Visual motion alone should still produce a stroke event")
        XCTAssertEqual(strokes[0].direction, .forward)
        XCTAssertEqual(strokes[0].source, .vision)
        XCTAssertLessThan(strokes[0].confidence, 0.5,
            "Vision-only events must be marked low-confidence (no audio corroboration)")
    }

    func test_completelyEmptyEvidence_producesUnknownEvent() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 2.0,
            audioOnsets: [],
            audioSilences: [],
            visualMotion: [],
            beatGrid: nil
        )
        XCTAssertEqual(timeline.events.count, 1)
        XCTAssertEqual(timeline.events[0].type, .unknown)
        XCTAssertEqual(timeline.events[0].direction, .unknown)
        XCTAssertEqual(timeline.events[0].confidence, 0.0)
    }

    // MARK: - Beat grid annotation

    func test_beatGrid_annotatesBeatPosition() {
        let grid = BeatGrid(bpm: 120, firstBeatTime: 0.0, beatCount: 4)
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .beatPlusScratch,
            duration: 2.0,
            bpm: 120,
            audioOnsets: [AudioOnsetEvent(startTime: 0.5, endTime: 1.0, confidence: 0.9)],
            audioSilences: [],
            visualMotion: [VisualMotionEvent(direction: .forward, startTime: 0.5, endTime: 1.0, confidence: 0.9)],
            beatGrid: grid
        )
        let stroke = timeline.events.first { $0.type == .stroke }
        XCTAssertNotNil(stroke?.beatPosition)
        XCTAssertEqual(stroke?.beatPosition ?? -1, 1.0, accuracy: 0.001,
            "Onset at t=0.5s under 120 BPM should be at beat position 1.0")
    }

    // MARK: - Adjacent same-type events merge

    func test_mergeAdjacent_collapsesContiguousSameTypeEvents() {
        let timeline = generator.generate(
            takeID: "t",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 3.0,
            audioOnsets: [],
            audioSilences: [
                AudioSilenceEvent(startTime: 0.0, endTime: 1.0, confidence: 0.95),
                AudioSilenceEvent(startTime: 1.0, endTime: 3.0, confidence: 0.95)
            ],
            visualMotion: [],
            beatGrid: nil
        )
        XCTAssertEqual(timeline.events.count, 1,
            "Two contiguous silence regions must merge into one event")
        XCTAssertEqual(timeline.events[0].startTime, 0.0)
        XCTAssertEqual(timeline.events[0].endTime, 3.0)
    }
}
