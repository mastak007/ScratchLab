import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationBeatGrid.gridLines(...)`:
/// pure, deterministic emission of beat / bar timing markers for a
/// time window. Used by the Mac Baby Scratch practice guide to
/// paint a rhythmic scaffold behind the trace without changing
/// trace geometry.
///
/// The helper carries no clock and no UI dependencies; it takes
/// only primitive inputs (visible window times, BPM, anchor,
/// beats-per-bar) and returns ordered grid lines. This means the
/// grid generation is independent of phrase / polyline / trace
/// data — the renderer can paint the grid during idle, replay,
/// and silence alike.
final class ScratchNotationBeatGridTests: XCTestCase {

    private let beatAt79: Double = 60.0 / 79.0

    // MARK: - 1. Beat spacing equals 60 / BPM

    func testBeatSpacingMatchesBPM() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0.27,
            visibleEnd: 0.27 + beatAt79 * 4,
            bpm: 79.0,
            anchorTime: 0.27
        )
        XCTAssertEqual(lines.count, 5)
        for index in 1..<lines.count {
            XCTAssertEqual(
                lines[index].time - lines[index - 1].time,
                beatAt79,
                accuracy: 1e-9
            )
        }
    }

    // MARK: - 2. First emitted line aligns to the anchor

    /// Beat 0 (the anchor) is a bar by construction (it's `0 %
    /// beatsPerBar`). For the Baby demo this places the first bar
    /// line at audio time 0.27 s — the first audible attack.
    func testFirstLineAlignsToAnchorAsBar() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0.27,
            visibleEnd: 0.27 + beatAt79 * 2,
            bpm: 79.0,
            anchorTime: 0.27
        )
        XCTAssertEqual(lines.first?.time ?? -1, 0.27, accuracy: 1e-9)
        XCTAssertEqual(lines.first?.kind, .bar)
    }

    // MARK: - 3. Bar lines occur every `beatsPerBar` beats

    func testBarLinesEveryFourBeats() {
        // Span 10 beats (0..9) starting just before the anchor so
        // beat 0 is included.
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0.27 - 0.01,
            visibleEnd: 0.27 + beatAt79 * 9 + 0.01,
            bpm: 79.0,
            anchorTime: 0.27,
            beatsPerBar: 4
        )
        XCTAssertEqual(lines.count, 10)
        let bars = lines.filter { $0.kind == .bar }
        XCTAssertEqual(bars.count, 3, "expected bars at beats 0, 4, 8")
        XCTAssertEqual(bars[0].time, 0.27, accuracy: 1e-9)
        XCTAssertEqual(bars[1].time, 0.27 + beatAt79 * 4, accuracy: 1e-9)
        XCTAssertEqual(bars[2].time, 0.27 + beatAt79 * 8, accuracy: 1e-9)
        // Every non-bar line is a beat.
        for line in lines where line.kind != .bar {
            XCTAssertEqual(line.kind, .beat)
        }
    }

    // MARK: - 4. Grid lines are clipped to the visible window

    /// Lines outside `[visibleStart, visibleEnd]` are not emitted.
    /// Lines exactly at the boundary are inclusive.
    func testGridLinesClippedToVisibleWindow() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 5.0,
            visibleEnd: 10.0,
            bpm: 79.0,
            anchorTime: 0.27
        )
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.time, 5.0 - 1e-9)
            XCTAssertLessThanOrEqual(line.time, 10.0 + 1e-9)
        }
    }

    // MARK: - 5. Grid lines are ordered in time

    func testGridLinesOrderedInTime() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: -5.0,
            visibleEnd: 10.0,
            bpm: 79.0,
            anchorTime: 0.27
        )
        let times = lines.map(\.time)
        XCTAssertEqual(times, times.sorted())
    }

    // MARK: - 6. Negative-index beats before the anchor

    /// The grid extends backward from the anchor when the visible
    /// window covers it. Beat -4 is a bar (`-4 % 4 == 0` in Swift).
    func testNegativeBeatIndicesProduceLinesBeforeAnchor() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0.27 - beatAt79 * 4 - 0.01,
            visibleEnd: 0.27 + 0.01,
            bpm: 79.0,
            anchorTime: 0.27
        )
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first?.kind, .bar, "beat -4 should be a bar")
        XCTAssertEqual(lines.last?.kind, .bar, "beat 0 (anchor) should be a bar")
        // Three intermediate lines at beats -3, -2, -1 are beats.
        for index in 1..<(lines.count - 1) {
            XCTAssertEqual(lines[index].kind, .beat)
        }
    }

    // MARK: - 7. Determinism

    func testDeterministicAcrossReruns() {
        let first = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0, visibleEnd: 10,
            bpm: 79.0, anchorTime: 0.27
        )
        for _ in 0..<99 {
            XCTAssertEqual(
                ScratchNotationBeatGrid.gridLines(
                    visibleStart: 0, visibleEnd: 10,
                    bpm: 79.0, anchorTime: 0.27
                ),
                first
            )
        }
    }

    // MARK: - 8. Independent of phrase / polyline / trace data

    /// The helper takes only primitive inputs. This test exercises
    /// it without constructing any phrase, polyline, or trace
    /// objects — a compile-time + runtime demonstration that grid
    /// generation does not require the upstream notation pipeline.
    func testGridIndependentOfPhraseAndTraceData() {
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: 0,
            visibleEnd: 8,
            bpm: 120.0,
            anchorTime: 0.0,
            beatsPerBar: 4
        )
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.first?.time ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(lines[1].time, 60.0 / 120.0, accuracy: 1e-9)
    }

    // MARK: - 9. Invalid inputs produce empty output

    func testNonFiniteBPMReturnsEmpty() {
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 0, visibleEnd: 10,
                bpm: .nan, anchorTime: 0.27
            ).isEmpty
        )
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 0, visibleEnd: 10,
                bpm: .infinity, anchorTime: 0.27
            ).isEmpty
        )
    }

    func testZeroOrNegativeBPMReturnsEmpty() {
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 0, visibleEnd: 10,
                bpm: 0, anchorTime: 0.27
            ).isEmpty
        )
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 0, visibleEnd: 10,
                bpm: -79, anchorTime: 0.27
            ).isEmpty
        )
    }

    func testInvalidWindowReturnsEmpty() {
        // visibleEnd < visibleStart
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 5, visibleEnd: 3,
                bpm: 79.0, anchorTime: 0.27
            ).isEmpty
        )
    }

    func testInvalidBeatsPerBarReturnsEmpty() {
        XCTAssertTrue(
            ScratchNotationBeatGrid.gridLines(
                visibleStart: 0, visibleEnd: 10,
                bpm: 79.0, anchorTime: 0.27, beatsPerBar: 0
            ).isEmpty
        )
    }
}
