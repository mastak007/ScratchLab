import XCTest
@testable import ScratchNotation

final class DatasetNotationModelTests: XCTestCase {

    func test_event_durationIsEndMinusStart() {
        let e = DatasetNotationEvent(
            type: .stroke,
            direction: .forward,
            startTime: 1.0,
            endTime: 2.5,
            source: .fused,
            confidence: 0.9
        )
        XCTAssertEqual(e.duration, 1.5, accuracy: 1e-9)
    }

    func test_event_clampsConfidenceToUnitRange() {
        let high = DatasetNotationEvent(
            type: .stroke, direction: .forward,
            startTime: 0, endTime: 1,
            source: .fused, confidence: 1.7
        )
        let low = DatasetNotationEvent(
            type: .stroke, direction: .forward,
            startTime: 0, endTime: 1,
            source: .fused, confidence: -0.4
        )
        XCTAssertEqual(high.confidence, 1.0)
        XCTAssertEqual(low.confidence, 0.0)
    }

    func test_timeline_defaultsToInferredAndCurrentSchema() {
        let t = DatasetNotationTimeline(
            takeID: "x",
            scratchType: "baby",
            beatMode: .noBeat,
            duration: 1.0
        )
        XCTAssertEqual(t.approvalState, .inferred)
        XCTAssertEqual(t.schemaVersion, DatasetNotationTimeline.currentSchemaVersion)
    }

    func test_beatGrid_returnsFractionalBeatPositions() {
        let grid = BeatGrid(bpm: 120, firstBeatTime: 0, beatCount: 8)
        XCTAssertEqual(grid.beatPosition(at: 0.0), 0.0)
        XCTAssertEqual(grid.beatPosition(at: 0.5), 1.0)   // 120 bpm -> 0.5 s/beat
        XCTAssertEqual(grid.beatPosition(at: 0.25), 0.5)
    }

    func test_beatGrid_zeroBpmReturnsNil() {
        let grid = BeatGrid(bpm: 0, firstBeatTime: 0, beatCount: 0)
        XCTAssertNil(grid.beatPosition(at: 1.0))
    }

    func test_beatMode_hasExpectedCasesAndRawValues() {
        // Locking the rename in: noBeat / beatOnly / beatPlusScratch / unknown
        let cases = DatasetNotationBeatMode.allCases
        XCTAssertEqual(Set(cases.map(\.rawValue)),
                       ["noBeat", "beatOnly", "beatPlusScratch", "unknown"])
    }

    func test_beatMode_eachCaseRoundTripsThroughJSON() throws {
        for mode in DatasetNotationBeatMode.allCases {
            let timeline = DatasetNotationTimeline(
                takeID: "t",
                scratchType: "baby",
                beatMode: mode,
                duration: 1.0
            )
            let data = try NotationCodec.encode(timeline)
            let decoded = try NotationCodec.decode(data)
            XCTAssertEqual(decoded.beatMode, mode, "beatMode \(mode) failed to round-trip")
        }
    }
}
