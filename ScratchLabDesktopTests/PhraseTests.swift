import XCTest
@testable import ScratchLab

/// Section 2 / Slice 4 — locks the contract of `Phrase`,
/// `PhraseBoundary`, and `PhraseBoundaryMapper.boundaries(...)`.
/// Bar-only phrase model layered above `TimingGrid` / `GridPosition`,
/// with no primitive coupling and no timing-tolerance semantics.
final class PhraseTests: XCTestCase {

    // MARK: - 1. Constructor rejects non-positive barCount

    func testConstructorRejectsZeroAndNegativeBarCount() {
        XCTAssertNil(Phrase(startBar: 0, barCount: 0))
        XCTAssertNil(Phrase(startBar: 0, barCount: -1))
        XCTAssertNil(Phrase(startBar: 5, barCount: -100))
        XCTAssertNotNil(Phrase(startBar: 0, barCount: 1))
        XCTAssertNotNil(Phrase(startBar: 0, barCount: 4))
    }

    // MARK: - 2. Constructor accepts negative startBar

    func testConstructorAcceptsNegativeStartBar() {
        XCTAssertNotNil(Phrase(startBar: -1, barCount: 4))
        XCTAssertNotNil(Phrase(startBar: -100, barCount: 1))
        let phrase = Phrase(startBar: -8, barCount: 4)
        XCTAssertEqual(phrase?.startBar, -8)
        XCTAssertEqual(phrase?.barCount, 4)
    }

    // MARK: - 3. endBarExclusive computes correctly

    func testEndBarExclusiveComputesCorrectly() {
        XCTAssertEqual(Phrase(startBar: 0, barCount: 4)!.endBarExclusive, 4)
        XCTAssertEqual(Phrase(startBar: 7, barCount: 1)!.endBarExclusive, 8)
        XCTAssertEqual(Phrase(startBar: -3, barCount: 4)!.endBarExclusive, 1)
        XCTAssertEqual(Phrase(startBar: -10, barCount: 2)!.endBarExclusive, -8)
    }

    // MARK: - 4. contains includes start bar (and is bar-only)

    func testContainsIncludesStartBarAndIsBarOnly() {
        let phrase = Phrase(startBar: 2, barCount: 4)!
        // Start bar with various beat/subdivision/phase combinations:
        // every variant must be contained.
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: 2, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: 2, beat: 3, subdivision: 3, subdivisionPhase: 0.999)
        ))
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: 5, beat: 2, subdivision: 1, subdivisionPhase: 0.5)
        ))
    }

    // MARK: - 5. contains excludes endBarExclusive

    func testContainsExcludesEndBarExclusive() {
        let phrase = Phrase(startBar: 2, barCount: 4)!  // covers bars 2..5
        XCTAssertFalse(phrase.contains(
            GridPosition(bar: 6, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
        XCTAssertFalse(phrase.contains(
            GridPosition(bar: 7, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
        XCTAssertFalse(phrase.contains(
            GridPosition(bar: 1, beat: 3, subdivision: 3, subdivisionPhase: 0.999)
        ))
    }

    // MARK: - 6. contains handles negative bars

    func testContainsHandlesNegativeBars() {
        let phrase = Phrase(startBar: -3, barCount: 4)!  // covers bars -3..0
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: -3, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: -1, beat: 2, subdivision: 1, subdivisionPhase: 0.5)
        ))
        XCTAssertTrue(phrase.contains(
            GridPosition(bar: 0, beat: 3, subdivision: 3, subdivisionPhase: 0.999)
        ))
        XCTAssertFalse(phrase.contains(
            GridPosition(bar: -4, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
        XCTAssertFalse(phrase.contains(
            GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0)
        ))
    }

    // MARK: - 7. startTime / endTime on standard 120 BPM 4/4

    func testStartTimeAndEndTimeOnStandardGrid() {
        // 120 BPM, 4/4 → secondsPerBar = 2.0, origin = 0.
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let phrase = Phrase(startBar: 2, barCount: 4)!
        XCTAssertEqual(phrase.startTime(using: grid), 4.0, accuracy: 1e-9)
        XCTAssertEqual(phrase.endTime(using: grid), 12.0, accuracy: 1e-9)
        XCTAssertEqual(phrase.endTime(using: grid) - phrase.startTime(using: grid),
                       Double(phrase.barCount) * grid.secondsPerBar,
                       accuracy: 1e-9)

        // Negative startBar must produce a negative startTime.
        let preOrigin = Phrase(startBar: -2, barCount: 1)!
        XCTAssertEqual(preOrigin.startTime(using: grid), -4.0, accuracy: 1e-9)
        XCTAssertEqual(preOrigin.endTime(using: grid), -2.0, accuracy: 1e-9)
    }

    // MARK: - 8. Non-4/4 grid start/end times

    func testNonFourFourGridStartEndTimes() {
        // 180 BPM, 3/4 → secondsPerBeat = 1/3, secondsPerBar = 1.0.
        let grid = TimingGrid(beatsPerMinute: 180,
                              beatsPerBar: 3,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let phrase = Phrase(startBar: 0, barCount: 8)!
        XCTAssertEqual(phrase.startTime(using: grid), 0.0, accuracy: 1e-9)
        XCTAssertEqual(phrase.endTime(using: grid), 8.0, accuracy: 1e-9)

        // Origin shift.
        let shiftedGrid = TimingGrid(beatsPerMinute: 180,
                                      beatsPerBar: 3,
                                      subdivisionsPerBeat: 4,
                                      origin: 2.0)!
        XCTAssertEqual(phrase.startTime(using: shiftedGrid), 2.0, accuracy: 1e-9)
        XCTAssertEqual(phrase.endTime(using: shiftedGrid), 10.0, accuracy: 1e-9)
    }

    // MARK: - 9. boundaries mapper returns empty for empty phrases

    func testBoundariesEmptyInputYieldsEmptyOutput() {
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let boundaries = PhraseBoundaryMapper.boundaries(phrases: [], using: grid)
        XCTAssertEqual(boundaries.count, 0)
    }

    // MARK: - 10. boundaries mapper preserves phrase order

    func testBoundariesPreserveOrder() {
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let phrases = [
            Phrase(startBar: 0,  barCount: 4)!,
            Phrase(startBar: 8,  barCount: 4)!,
            Phrase(startBar: 16, barCount: 2)!,
            Phrase(startBar: -4, barCount: 4)!,
        ]
        let boundaries = PhraseBoundaryMapper.boundaries(phrases: phrases, using: grid)
        XCTAssertEqual(boundaries.count, phrases.count)
        XCTAssertEqual(boundaries.map(\.phraseIndex), [0, 1, 2, 3])
    }

    // MARK: - 11. boundaries mapper creates expected positions

    func testBoundariesCreateExpectedPositions() {
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let phrases = [
            Phrase(startBar: 0,  barCount: 4)!,
            Phrase(startBar: 4,  barCount: 4)!,
            Phrase(startBar: -2, barCount: 2)!,
        ]
        let boundaries = PhraseBoundaryMapper.boundaries(phrases: phrases, using: grid)
        XCTAssertEqual(boundaries[0].start,
                       GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(boundaries[0].endExclusive,
                       GridPosition(bar: 4, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(boundaries[1].start,
                       GridPosition(bar: 4, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(boundaries[1].endExclusive,
                       GridPosition(bar: 8, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(boundaries[2].start,
                       GridPosition(bar: -2, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(boundaries[2].endExclusive,
                       GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
    }

    // MARK: - 12. Phrase Codable round-trip

    func testPhraseCodableRoundTrip() throws {
        let phrase = Phrase(startBar: -5, barCount: 16)!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(phrase)
        XCTAssertEqual(try decoder.decode(Phrase.self, from: data), phrase)
        let second = try encoder.encode(try decoder.decode(Phrase.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 13. PhraseBoundary Codable round-trip

    func testPhraseBoundaryCodableRoundTrip() throws {
        let boundary = PhraseBoundary(
            phraseIndex: 3,
            start: GridPosition(bar: 2, beat: 0, subdivision: 0, subdivisionPhase: 0),
            endExclusive: GridPosition(bar: 6, beat: 0, subdivision: 0, subdivisionPhase: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(boundary)
        XCTAssertEqual(try decoder.decode(PhraseBoundary.self, from: data), boundary)
        let second = try encoder.encode(try decoder.decode(PhraseBoundary.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 14. Decoder rejects invalid Phrase

    func testCodableRejectsInvalidPhrase() {
        let decoder = JSONDecoder()
        let zero = """
        {"startBar":0,"barCount":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(Phrase.self, from: zero))

        let negative = """
        {"startBar":0,"barCount":-1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(Phrase.self, from: negative))
    }

    // MARK: - 15. Decoder rejects invalid PhraseBoundary

    func testCodableRejectsInvalidPhraseBoundary() {
        let decoder = JSONDecoder()
        let negativeIndex = """
        {
          "phraseIndex": -1,
          "start": {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":0.0},
          "endExclusive": {"bar":4,"beat":0,"subdivision":0,"subdivisionPhase":0.0}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseBoundary.self, from: negativeIndex))

        // Nested GridPosition validation must also fire (subdivisionPhase
        // ≥ 1 is rejected by the GridPosition decoder).
        let invalidNestedPosition = """
        {
          "phraseIndex": 0,
          "start": {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":1.5},
          "endExclusive": {"bar":4,"beat":0,"subdivision":0,"subdivisionPhase":0.0}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseBoundary.self, from: invalidNestedPosition))
    }

    // MARK: - 16. Mapper deterministic

    func testMapperDeterministicAcrossInvocations() {
        let grid = TimingGrid(beatsPerMinute: 142,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 1.5)!
        let phrases = [
            Phrase(startBar: 0, barCount: 4)!,
            Phrase(startBar: 4, barCount: 4)!,
            Phrase(startBar: 8, barCount: 4)!,
        ]
        let first = PhraseBoundaryMapper.boundaries(phrases: phrases, using: grid)
        let second = PhraseBoundaryMapper.boundaries(phrases: phrases, using: grid)
        XCTAssertEqual(first, second)
    }
}
