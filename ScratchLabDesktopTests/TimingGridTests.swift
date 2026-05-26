import XCTest
@testable import ScratchLab

/// Section 2 / Slice 1 — locks the contract of `TimingGrid` and
/// `GridPosition`: the BPM-aware projection of absolute time onto a
/// musical `(bar, beat, subdivision, phase)` lattice.
///
/// Synthetic, deterministic inputs only. No fixture dependency, no
/// integration with motion-grammar primitives, no algorithm coupling.
final class TimingGridTests: XCTestCase {

    // MARK: - Construction validation

    func testGridConstructorRejectsInvalidParameters() {
        XCTAssertNil(TimingGrid(beatsPerMinute: 0,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: -120,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: .nan,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: .infinity,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: 120,
                                 beatsPerBar: 0,
                                 subdivisionsPerBeat: 4,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: 120,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 0,
                                 origin: 0))
        XCTAssertNil(TimingGrid(beatsPerMinute: 120,
                                 beatsPerBar: 4,
                                 subdivisionsPerBeat: 4,
                                 origin: .nan))
        XCTAssertNotNil(TimingGrid(beatsPerMinute: 120,
                                    beatsPerBar: 4,
                                    subdivisionsPerBeat: 4,
                                    origin: 0))
    }

    // MARK: - Standard 4/4 mapping

    /// 120 BPM ⇒ 0.5 s per beat, 0.125 s per 16th-note subdivision,
    /// 2.0 s per bar.
    func testStandardFourFourAtOrigin() {
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        XCTAssertEqual(grid.secondsPerBeat, 0.5, accuracy: 1e-12)
        XCTAssertEqual(grid.secondsPerSubdivision, 0.125, accuracy: 1e-12)
        XCTAssertEqual(grid.secondsPerBar, 2.0, accuracy: 1e-12)

        let p0 = grid.position(at: 0.0)
        XCTAssertEqual(p0, GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))

        let pBeat1 = grid.position(at: 0.5)
        XCTAssertEqual(pBeat1, GridPosition(bar: 0, beat: 1, subdivision: 0, subdivisionPhase: 0))

        let pBar1 = grid.position(at: 2.0)
        XCTAssertEqual(pBar1, GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0))

        let pSub1 = grid.position(at: 0.125)
        XCTAssertEqual(pSub1, GridPosition(bar: 0, beat: 0, subdivision: 1, subdivisionPhase: 0))

        let pHalfSub = grid.position(at: 0.0625)
        XCTAssertEqual(pHalfSub.bar, 0)
        XCTAssertEqual(pHalfSub.beat, 0)
        XCTAssertEqual(pHalfSub.subdivision, 0)
        XCTAssertEqual(pHalfSub.subdivisionPhase, 0.5, accuracy: 1e-12)
    }

    // MARK: - Round-trip

    func testRoundTripWithinFloatPrecision() {
        let grid = TimingGrid(beatsPerMinute: 117.3,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0.37)!
        var t = -10.0
        let step = 0.0173
        while t <= 100.0 {
            let position = grid.position(at: t)
            let roundTripped = grid.time(of: position)
            XCTAssertEqual(roundTripped, t, accuracy: 1e-9,
                           "round-trip drift at t=\(t): got \(roundTripped)")
            t += step
        }
    }

    // MARK: - Negative bars

    func testNegativeBarsForPreOriginTime() {
        // 120 BPM, 4/4, origin at t=1.0. Half a second before the origin
        // is the last beat of bar -1.
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 1.0)!
        let p = grid.position(at: 0.5)
        XCTAssertEqual(p, GridPosition(bar: -1, beat: 3, subdivision: 0, subdivisionPhase: 0))

        // Earlier still — two bars and one beat before origin.
        // That's 2 * 2.0 + 0.5 = 4.5 s before origin, so t = 1.0 - 4.5 = -3.5.
        let p2 = grid.position(at: -3.5)
        XCTAssertEqual(p2, GridPosition(bar: -3, beat: 3, subdivision: 0, subdivisionPhase: 0))
    }

    // MARK: - Non-zero origin

    func testNonZeroOriginShiftsAllPositions() {
        let origin = 10.0
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: origin)!
        XCTAssertEqual(grid.position(at: origin),
                       GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(grid.position(at: origin + 0.5),
                       GridPosition(bar: 0, beat: 1, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(grid.position(at: origin + 2.0),
                       GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0))
    }

    // MARK: - Non-4/4 time signature

    func testNonFourFourBeatsPerBar() {
        // 180 BPM, 3/4. secondsPerBeat = 1/3, secondsPerBar = 1.0.
        let grid = TimingGrid(beatsPerMinute: 180,
                              beatsPerBar: 3,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        XCTAssertEqual(grid.secondsPerBeat, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(grid.secondsPerBar, 1.0, accuracy: 1e-12)

        // Beat 2 of bar 0 sits at t = 2/3.
        let pBeat2 = grid.position(at: 2.0 / 3.0)
        XCTAssertEqual(pBeat2.bar, 0)
        XCTAssertEqual(pBeat2.beat, 2)
        XCTAssertEqual(pBeat2.subdivision, 0)
        XCTAssertEqual(pBeat2.subdivisionPhase, 0, accuracy: 1e-9)

        // Bar 1 starts at t = 1.0.
        XCTAssertEqual(grid.position(at: 1.0),
                       GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0))
    }

    // MARK: - Non-standard subdivisions

    func testNonStandardSubdivisionsPerBeat() {
        // 120 BPM, 4/4, triplet subdivisions (3 per beat).
        // secondsPerBeat = 0.5, secondsPerSubdivision = 1/6.
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 3,
                              origin: 0)!
        XCTAssertEqual(grid.secondsPerSubdivision, 1.0 / 6.0, accuracy: 1e-12)

        // Triplet 2 of beat 0 sits at t = 2/6 = 1/3.
        let pTriplet2 = grid.position(at: 1.0 / 3.0)
        XCTAssertEqual(pTriplet2.bar, 0)
        XCTAssertEqual(pTriplet2.beat, 0)
        XCTAssertEqual(pTriplet2.subdivision, 2)
        XCTAssertEqual(pTriplet2.subdivisionPhase, 0, accuracy: 1e-9)
    }

    // MARK: - Field bounds on derived positions

    func testSubdivisionPhaseAndIndicesAreInRange() {
        let grid = TimingGrid(beatsPerMinute: 142,
                              beatsPerBar: 5,
                              subdivisionsPerBeat: 4,
                              origin: -3.2)!
        // Deterministic pseudo-random sweep — using a fixed seed pattern.
        let times: [Double] = stride(from: -25.0, to: 25.0, by: 0.137).map { $0 }
        for t in times {
            let p = grid.position(at: t)
            XCTAssertGreaterThanOrEqual(p.beat, 0,
                                        "beat negative at t=\(t): \(p.beat)")
            XCTAssertLessThan(p.beat, grid.beatsPerBar,
                              "beat ≥ beatsPerBar at t=\(t): \(p.beat)")
            XCTAssertGreaterThanOrEqual(p.subdivision, 0,
                                        "subdivision negative at t=\(t): \(p.subdivision)")
            XCTAssertLessThan(p.subdivision, grid.subdivisionsPerBeat,
                              "subdivision ≥ subdivisionsPerBeat at t=\(t): \(p.subdivision)")
            XCTAssertGreaterThanOrEqual(p.subdivisionPhase, 0.0,
                                        "subdivisionPhase < 0 at t=\(t): \(p.subdivisionPhase)")
            XCTAssertLessThan(p.subdivisionPhase, 1.0,
                              "subdivisionPhase ≥ 1 at t=\(t): \(p.subdivisionPhase)")
        }
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let grid = TimingGrid(beatsPerMinute: 95.5,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 6,
                              origin: 1.25)!
        let position = grid.position(at: 7.3)
        XCTAssertGreaterThan(position.subdivisionPhase, 0.0,
                             "test setup expects a non-zero phase to exercise round-trip")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let gridData = try encoder.encode(grid)
        XCTAssertEqual(try decoder.decode(TimingGrid.self, from: gridData), grid)

        let positionData = try encoder.encode(position)
        XCTAssertEqual(try decoder.decode(GridPosition.self, from: positionData), position)
    }

    func testCodableRejectsOutOfRangeGridPosition() {
        let decoder = JSONDecoder()

        let phaseTooHigh = """
        {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":1.5}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: phaseTooHigh))

        let phaseExactlyOne = """
        {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":1.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: phaseExactlyOne))

        let phaseNegative = """
        {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":-0.1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: phaseNegative))

        let beatNegative = """
        {"bar":0,"beat":-1,"subdivision":0,"subdivisionPhase":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: beatNegative))

        let subdivisionNegative = """
        {"bar":0,"beat":0,"subdivision":-1,"subdivisionPhase":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: subdivisionNegative))

        let phaseNaN = """
        {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":"NaN"}
        """.data(using: .utf8)!
        // JSONDecoder treats NaN strings as decoding failure (Double),
        // either via type-mismatch or — if it parsed — via our range
        // guard. Either way, throwing is the contract.
        XCTAssertThrowsError(try decoder.decode(GridPosition.self, from: phaseNaN))
    }

    // MARK: - Determinism

    func testDeterminismAcrossInvocations() {
        let grid = TimingGrid(beatsPerMinute: 128,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0.5)!
        for t in stride(from: -5.0, to: 5.0, by: 0.073) {
            XCTAssertEqual(grid.position(at: t), grid.position(at: t))
        }
    }
}
