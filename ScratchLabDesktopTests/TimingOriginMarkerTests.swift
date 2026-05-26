import XCTest
@testable import ScratchLab

/// Section 2 / Slice 7 — locks the contract of `TimingOriginSource`,
/// `TimingOriginMarker`, and `TimingGridFactory.grid(...)`. Pure
/// value-type wiring for an explicit grid origin. No audio analysis,
/// no clock dependency.
final class TimingOriginMarkerTests: XCTestCase {

    // MARK: - 1. Marker rejects invalid time

    func testMarkerRejectsInvalidTime() {
        XCTAssertNil(TimingOriginMarker(time: -0.01, source: .manual, label: nil))
        XCTAssertNil(TimingOriginMarker(time: -1.0,  source: .imported, label: "x"))
        XCTAssertNil(TimingOriginMarker(time: .nan,  source: .manual, label: nil))
        XCTAssertNil(TimingOriginMarker(time: .infinity, source: .manual, label: nil))
        XCTAssertNil(TimingOriginMarker(time: -.infinity, source: .manual, label: nil))
    }

    // MARK: - 2. Marker accepts zero time

    func testMarkerAcceptsZeroTime() {
        let marker = TimingOriginMarker(time: 0, source: .manual, label: nil)
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.time, 0)
    }

    // MARK: - 3. Marker accepts positive time

    func testMarkerAcceptsPositiveTime() {
        let marker = TimingOriginMarker(time: 1.25, source: .imported, label: "intro")
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.time, 1.25)
    }

    // MARK: - 4. Marker preserves source

    func testMarkerPreservesSource() {
        let manual = TimingOriginMarker(time: 0.5, source: .manual, label: nil)
        let imported = TimingOriginMarker(time: 0.5, source: .imported, label: nil)
        let detected = TimingOriginMarker(time: 0.5, source: .detectedPlaceholder, label: nil)
        XCTAssertEqual(manual?.source, .manual)
        XCTAssertEqual(imported?.source, .imported)
        XCTAssertEqual(detected?.source, .detectedPlaceholder)
    }

    // MARK: - 5. Marker preserves nil label

    func testMarkerPreservesNilLabel() {
        let marker = TimingOriginMarker(time: 1.0, source: .manual, label: nil)
        XCTAssertNotNil(marker)
        XCTAssertNil(marker?.label)
    }

    // MARK: - 6. Marker preserves empty label

    func testMarkerPreservesEmptyLabel() {
        let marker = TimingOriginMarker(time: 1.0, source: .manual, label: "")
        XCTAssertNotNil(marker)
        XCTAssertEqual(marker?.label, "",
                       "empty label must not be coerced to nil or trimmed")
    }

    // MARK: - 7. Factory creates TimingGrid using marker.time as origin

    func testFactoryCreatesGridWithMarkerTimeAsOrigin() {
        let marker = TimingOriginMarker(time: 1.5, source: .manual, label: "downbeat")!
        let grid = TimingGridFactory.grid(beatsPerMinute: 120,
                                            beatsPerBar: 4,
                                            subdivisionsPerBeat: 4,
                                            originMarker: marker)
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.origin, 1.5)
        XCTAssertEqual(grid?.beatsPerMinute, 120)
        XCTAssertEqual(grid?.beatsPerBar, 4)
        XCTAssertEqual(grid?.subdivisionsPerBeat, 4)

        // Equivalent to constructing the grid directly with the same origin.
        let direct = TimingGrid(beatsPerMinute: 120,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: 1.5)
        XCTAssertEqual(grid, direct)
    }

    // MARK: - 8. Factory returns nil for invalid grid parameters

    func testFactoryReturnsNilForInvalidGridParameters() {
        let marker = TimingOriginMarker(time: 0.0, source: .manual, label: nil)!
        XCTAssertNil(TimingGridFactory.grid(beatsPerMinute: 0,
                                             beatsPerBar: 4,
                                             subdivisionsPerBeat: 4,
                                             originMarker: marker))
        XCTAssertNil(TimingGridFactory.grid(beatsPerMinute: 120,
                                             beatsPerBar: 0,
                                             subdivisionsPerBeat: 4,
                                             originMarker: marker))
        XCTAssertNil(TimingGridFactory.grid(beatsPerMinute: 120,
                                             beatsPerBar: 4,
                                             subdivisionsPerBeat: 0,
                                             originMarker: marker))
        XCTAssertNil(TimingGridFactory.grid(beatsPerMinute: .nan,
                                             beatsPerBar: 4,
                                             subdivisionsPerBeat: 4,
                                             originMarker: marker))
    }

    // MARK: - 9. Codable round-trip

    func testCodableRoundTrip() throws {
        let marker = TimingOriginMarker(time: 1.25, source: .imported, label: "intro")!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(marker)
        XCTAssertEqual(try decoder.decode(TimingOriginMarker.self, from: data), marker)
        let second = try encoder.encode(try decoder.decode(TimingOriginMarker.self, from: data))
        XCTAssertEqual(data, second)

        // nil label round-trips cleanly.
        let markerNoLabel = TimingOriginMarker(time: 0.5, source: .manual, label: nil)!
        let dataNoLabel = try encoder.encode(markerNoLabel)
        XCTAssertEqual(
            try decoder.decode(TimingOriginMarker.self, from: dataNoLabel),
            markerNoLabel
        )

        // empty label round-trips and is not coerced to nil.
        let markerEmptyLabel = TimingOriginMarker(time: 0.5, source: .manual, label: "")!
        let dataEmptyLabel = try encoder.encode(markerEmptyLabel)
        let roundTripped = try decoder.decode(TimingOriginMarker.self, from: dataEmptyLabel)
        XCTAssertEqual(roundTripped, markerEmptyLabel)
        XCTAssertEqual(roundTripped.label, "")
    }

    // MARK: - 10. Decoder rejects invalid time

    func testCodableRejectsInvalidTime() {
        let decoder = JSONDecoder()
        let negative = """
        {"time":-0.01,"source":"manual"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingOriginMarker.self, from: negative))

        let nanCase = """
        {"time":"NaN","source":"manual"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingOriginMarker.self, from: nanCase))

        let infinityCase = """
        {"time":"Infinity","source":"manual"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingOriginMarker.self, from: infinityCase))

        let unknownSource = """
        {"time":0.0,"source":"telepathy"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingOriginMarker.self, from: unknownSource),
                             "decoder must reject unknown TimingOriginSource raw values")
    }

    // MARK: - 11. Deterministic factory

    func testFactoryDeterministicAcrossInvocations() {
        let marker = TimingOriginMarker(time: 0.875, source: .manual, label: "bar 0")!
        let first = TimingGridFactory.grid(beatsPerMinute: 142,
                                            beatsPerBar: 4,
                                            subdivisionsPerBeat: 4,
                                            originMarker: marker)
        let second = TimingGridFactory.grid(beatsPerMinute: 142,
                                             beatsPerBar: 4,
                                             subdivisionsPerBeat: 4,
                                             originMarker: marker)
        XCTAssertEqual(first, second)
    }
}
