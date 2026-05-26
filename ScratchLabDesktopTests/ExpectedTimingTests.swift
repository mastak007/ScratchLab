import XCTest
@testable import ScratchLab

/// Section 2 / Slice 5 — locks the contract of `ExpectedTiming` and
/// `ExpectedTimingMapper`. Inverse of the grid annotation: convert
/// `annotation.start` positions back into absolute expected start
/// times. Synthetic, deterministic; no primitive access.
final class ExpectedTimingTests: XCTestCase {

    // MARK: - Helpers

    private func makeStandardGrid() -> TimingGrid {
        TimingGrid(beatsPerMinute: 120,
                   beatsPerBar: 4,
                   subdivisionsPerBeat: 4,
                   origin: 0)!
    }

    private func annotation(index: Int,
                             startBar: Int,
                             startBeat: Int = 0,
                             startSubdivision: Int = 0,
                             startPhase: Double = 0) -> GridAnnotation {
        GridAnnotation(
            primitiveIndex: index,
            start: GridPosition(bar: startBar,
                                 beat: startBeat,
                                 subdivision: startSubdivision,
                                 subdivisionPhase: startPhase),
            end: GridPosition(bar: startBar,
                               beat: startBeat,
                               subdivision: startSubdivision,
                               subdivisionPhase: startPhase)
        )
    }

    // MARK: - 1. Empty input → empty output

    func testEmptyAnnotationsReturnEmptyOutput() {
        let grid = makeStandardGrid()
        let times = ExpectedTimingMapper.expectedStartTimes(for: [], using: grid)
        let map = ExpectedTimingMapper.expectedStartTimeMap(for: [], using: grid)
        XCTAssertEqual(times.count, 0)
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - 2. Array preserves annotation order

    func testArrayPreservesAnnotationOrder() {
        let grid = makeStandardGrid()
        let annotations: [GridAnnotation] = [
            annotation(index: 5, startBar: 0),
            annotation(index: 2, startBar: 1),
            annotation(index: 7, startBar: 2),
            annotation(index: 0, startBar: 3),
        ]
        let times = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(times.count, annotations.count)
        XCTAssertEqual(times.map(\.primitiveIndex), [5, 2, 7, 0])
    }

    // MARK: - 3. expectedStartTime == grid.time(of: annotation.start)

    func testExpectedStartTimeMatchesGridProjection() {
        let grid = makeStandardGrid()
        let annotations: [GridAnnotation] = [
            annotation(index: 0, startBar: 0),    // t = 0.0
            annotation(index: 1, startBar: 0, startBeat: 2), // t = 1.0
            annotation(index: 2, startBar: 1),    // t = 2.0
            annotation(index: 3, startBar: 0,
                       startBeat: 0,
                       startSubdivision: 1),       // t = 0.125
        ]
        let times = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(times[0].expectedStartTime, 0.0,   accuracy: 1e-12)
        XCTAssertEqual(times[1].expectedStartTime, 1.0,   accuracy: 1e-12)
        XCTAssertEqual(times[2].expectedStartTime, 2.0,   accuracy: 1e-12)
        XCTAssertEqual(times[3].expectedStartTime, 0.125, accuracy: 1e-12)
    }

    // MARK: - 4. Pre-origin position maps to negative/early time

    func testPreOriginPositionMapsToNegativeTime() {
        // 120 BPM 4/4 with origin = 1.0. secondsPerBar = 2.0,
        // secondsPerBeat = 0.5. Bar -1's downbeat sits at
        // origin - 2.0 = -1.0; beat 3 of bar -1 sits half a second
        // before origin at t = 0.5; bar 0's downbeat is at origin = 1.0.
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 1.0)!
        let annotations: [GridAnnotation] = [
            annotation(index: 0, startBar: -1),                  // t = -1.0 (negative)
            annotation(index: 1, startBar: -1, startBeat: 3),    // t =  0.5 (pre-origin but positive)
            annotation(index: 2, startBar: 0),                   // t =  1.0 (origin)
        ]
        let times = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(times[0].expectedStartTime, -1.0, accuracy: 1e-12)
        XCTAssertEqual(times[1].expectedStartTime,  0.5, accuracy: 1e-12)
        XCTAssertEqual(times[2].expectedStartTime,  1.0, accuracy: 1e-12)
        // All three predate origin; confirm at least one is genuinely negative.
        XCTAssertLessThan(times[0].expectedStartTime, 0,
                          "primitive 0 should map to a negative absolute time")
    }

    // MARK: - 5. Dictionary uses primitiveIndex as key

    func testDictionaryUsesPrimitiveIndexAsKey() throws {
        let grid = makeStandardGrid()
        let annotations: [GridAnnotation] = [
            annotation(index: 5, startBar: 0),  // t = 0.0
            annotation(index: 2, startBar: 1),  // t = 2.0
            annotation(index: 7, startBar: 2),  // t = 4.0
        ]
        let map = ExpectedTimingMapper.expectedStartTimeMap(for: annotations, using: grid)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(try XCTUnwrap(map[5]), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(map[2]), 2.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(map[7]), 4.0, accuracy: 1e-12)
        XCTAssertNil(map[0])
        XCTAssertNil(map[99])
    }

    // MARK: - 6. Duplicate primitiveIndex: later value wins in map

    func testDuplicatePrimitiveIndexLaterValueWins() throws {
        let grid = makeStandardGrid()
        let annotations: [GridAnnotation] = [
            annotation(index: 3, startBar: 0),  // earlier — t = 0.0
            annotation(index: 5, startBar: 1),  // t = 2.0
            annotation(index: 3, startBar: 2),  // later  — t = 4.0 (wins)
        ]
        let map = ExpectedTimingMapper.expectedStartTimeMap(for: annotations, using: grid)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(try XCTUnwrap(map[3]), 4.0, accuracy: 1e-12,
                       "later annotation must overwrite earlier in the map")
        XCTAssertEqual(try XCTUnwrap(map[5]), 2.0, accuracy: 1e-12)

        // Array form is unaffected by duplicates — both entries appear in order.
        let times = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(times.map(\.primitiveIndex), [3, 5, 3])
        XCTAssertEqual(times[0].expectedStartTime, 0.0)
        XCTAssertEqual(times[2].expectedStartTime, 4.0)
    }

    // MARK: - 7. Codable round-trip

    func testCodableRoundTrip() throws {
        let value = ExpectedTiming(primitiveIndex: 7, expectedStartTime: 3.25)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(value)
        XCTAssertEqual(try decoder.decode(ExpectedTiming.self, from: data), value)
        let second = try encoder.encode(try decoder.decode(ExpectedTiming.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 8. Decoder rejects negative primitiveIndex

    func testCodableRejectsNegativePrimitiveIndex() {
        let decoder = JSONDecoder()
        let invalid = """
        {"primitiveIndex":-1,"expectedStartTime":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ExpectedTiming.self, from: invalid)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - 9. Decoder rejects NaN / infinite expectedStartTime

    func testCodableRejectsNonFiniteExpectedStartTime() {
        let decoder = JSONDecoder()
        let nanCase = """
        {"primitiveIndex":0,"expectedStartTime":"NaN"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ExpectedTiming.self, from: nanCase))

        let infCase = """
        {"primitiveIndex":0,"expectedStartTime":"Infinity"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ExpectedTiming.self, from: infCase))
    }

    // MARK: - 10. Deterministic

    func testDeterministicAcrossInvocations() {
        let grid = makeStandardGrid()
        let annotations: [GridAnnotation] = [
            annotation(index: 0, startBar: 0),
            annotation(index: 1, startBar: 0, startBeat: 2),
            annotation(index: 2, startBar: 1),
            annotation(index: 3, startBar: 0, startSubdivision: 1),
        ]
        let firstArray = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        let secondArray = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(firstArray, secondArray)

        let firstMap = ExpectedTimingMapper.expectedStartTimeMap(for: annotations, using: grid)
        let secondMap = ExpectedTimingMapper.expectedStartTimeMap(for: annotations, using: grid)
        XCTAssertEqual(firstMap, secondMap)
    }

    // MARK: - 11. Non-4/4 grid

    func testNonFourFourGridMapsCorrectly() {
        // 180 BPM, 3/4, 4 subs per beat: secondsPerBeat = 1/3,
        // secondsPerBar = 1.0, secondsPerSubdivision = 1/12.
        let grid = TimingGrid(beatsPerMinute: 180,
                              beatsPerBar: 3,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let annotations: [GridAnnotation] = [
            annotation(index: 0, startBar: 0),                    // t = 0
            annotation(index: 1, startBar: 0, startBeat: 2),      // t = 2/3
            annotation(index: 2, startBar: 1),                    // t = 1.0
            annotation(index: 3, startBar: 0,
                       startBeat: 0,
                       startSubdivision: 1),                       // t = 1/12
        ]
        let times = ExpectedTimingMapper.expectedStartTimes(for: annotations, using: grid)
        XCTAssertEqual(times[0].expectedStartTime, 0.0,        accuracy: 1e-9)
        XCTAssertEqual(times[1].expectedStartTime, 2.0 / 3.0,  accuracy: 1e-9)
        XCTAssertEqual(times[2].expectedStartTime, 1.0,        accuracy: 1e-9)
        XCTAssertEqual(times[3].expectedStartTime, 1.0 / 12.0, accuracy: 1e-9)
    }
}
