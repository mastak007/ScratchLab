import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationPositionTrace.derive(...)`:
/// pure, deterministic derivation of a continuous-position trace from
/// direction + duration segments. Cursor carries forward across
/// reversals, never resets to baseline, never escapes `[0, 1]`.
final class ScratchNotationPositionTraceTests: XCTestCase {

    // MARK: - Helpers

    private func segment(
        startTime: TimeInterval,
        endTime: TimeInterval,
        direction: ScratchMotionDirection
    ) -> ScratchLabBabyScratchStrokeSegment {
        ScratchLabBabyScratchStrokeSegment(
            startTime: startTime,
            endTime: endTime,
            direction: direction,
            holdAfter: 0,
            startProgress: 0,
            endProgress: 0
        )
    }

    // MARK: - 1. Continuous positions render without baseline reset

    func testCarriesCursorForwardAcrossReversals() {
        // Two forward strokes (each 0.1 s) followed by one backward
        // stroke (also 0.1 s). With rate = 1.0 / second the cursor
        // walks 0.5 → 0.6 → 0.7 → 0.6 — no return to baseline at any
        // segment boundary.
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.1, direction: .forward),
            segment(startTime: 0.2, endTime: 0.3, direction: .forward),
            segment(startTime: 0.4, endTime: 0.5, direction: .backward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace.count, 3)
        XCTAssertEqual(trace[0].startPosition, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition,   0.6, accuracy: 1e-9)
        XCTAssertEqual(trace[1].startPosition, 0.6, accuracy: 1e-9)
        XCTAssertEqual(trace[1].endPosition,   0.7, accuracy: 1e-9)
        XCTAssertEqual(trace[2].startPosition, 0.7, accuracy: 1e-9)
        XCTAssertEqual(trace[2].endPosition,   0.6, accuracy: 1e-9)
    }

    // MARK: - 2. Reversal at mid-cursor does not drop to baseline

    func testReversalAtMidCursorDoesNotResetToZero() {
        // Cursor is at 0.4 after a 0.1 s backward stroke from start.
        // A reversal forward should resume from 0.4, not from 0.
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.1, direction: .backward),
            segment(startTime: 0.2, endTime: 0.3, direction: .forward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace[0].startPosition, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition,   0.4, accuracy: 1e-9)
        XCTAssertEqual(trace[1].startPosition, 0.4, accuracy: 1e-9)
        XCTAssertEqual(trace[1].endPosition,   0.5, accuracy: 1e-9)
        XCTAssertNotEqual(trace[1].startPosition, 0.0)
    }

    // MARK: - 3. Partial movement near middle renders short segment

    func testPartialMovementRendersShortSegment() {
        // A tiny 0.04 s forward stroke at the default rate moves the
        // cursor by 0.04 — small enough to read as a near-horizontal
        // line in the renderer.
        let segments = [segment(startTime: 0, endTime: 0.04, direction: .forward)]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace[0].startPosition, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition,   0.54, accuracy: 1e-9)
        let movement = abs(trace[0].endPosition - trace[0].startPosition)
        XCTAssertLessThan(movement, 0.1)
    }

    // MARK: - 4. Full movement 0 → 1 still renders full height

    func testFullMovementStillRendersFullHeight() {
        // A single long forward stroke (2 s at default rate) saturates
        // the cursor up to the clamp boundary — full lane height
        // remains achievable when the input justifies it.
        let segments = [segment(startTime: 0, endTime: 2.0, direction: .forward)]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace[0].startPosition, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition,   1.0, accuracy: 1e-9)
    }

    func testFullMovementBackwardSaturatesAtZero() {
        let segments = [segment(startTime: 0, endTime: 2.0, direction: .backward)]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace[0].endPosition, 0.0, accuracy: 1e-9)
    }

    // MARK: - 5. Input without 0 or 1 never produces 0 or 1

    func testNonSaturatingInputStaysOffBoundaries() {
        // Five small alternating strokes near the middle. Cursor
        // wanders around 0.5 without ever reaching 0 or 1.
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.10, direction: .forward),
            segment(startTime: 0.2, endTime: 0.28, direction: .backward),
            segment(startTime: 0.4, endTime: 0.50, direction: .forward),
            segment(startTime: 0.6, endTime: 0.65, direction: .backward),
            segment(startTime: 0.8, endTime: 0.85, direction: .backward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        for entry in trace {
            XCTAssertGreaterThan(entry.startPosition, 0)
            XCTAssertLessThan(entry.startPosition, 1)
            XCTAssertGreaterThan(entry.endPosition, 0)
            XCTAssertLessThan(entry.endPosition, 1)
        }
    }

    // MARK: - 6. Stroke count / direction count preserved

    func testStrokeCountPreserved() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = (0..<5).map { index in
            segment(
                startTime: Double(index) * 0.2,
                endTime: Double(index) * 0.2 + 0.05,
                direction: index.isMultiple(of: 2) ? .forward : .backward
            )
        }
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace.count, segments.count)
    }

    func testDirectionsPreservedInOrder() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.05, direction: .forward),
            segment(startTime: 0.1, endTime: 0.15, direction: .backward),
            segment(startTime: 0.2, endTime: 0.25, direction: .forward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace.map(\.direction),
                       [.forward, .backward, .forward])
    }

    func testNeutralSegmentsAreSkipped() {
        // Explicit hold segments do not move the cursor and do not
        // appear in the trace — neutral is not a scratch.
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.05, direction: .forward),
            segment(startTime: 0.1, endTime: 0.20, direction: .neutral),
            segment(startTime: 0.3, endTime: 0.35, direction: .backward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace.count, 2)
        XCTAssertEqual(trace[0].direction, .forward)
        XCTAssertEqual(trace[1].direction, .backward)
        // Second trace segment must start at the first's end —
        // cursor still carries forward across the dropped neutral.
        XCTAssertEqual(trace[1].startPosition, trace[0].endPosition, accuracy: 1e-9)
    }

    // MARK: - 7. Zero-duration / missing-position segments stay finite

    func testZeroDurationSegmentHoldsCursor() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.1, direction: .forward),
            segment(startTime: 0.2, endTime: 0.2, direction: .forward), // zero
            segment(startTime: 0.3, endTime: 0.35, direction: .forward),
        ]
        let trace = ScratchNotationPositionTrace.derive(from: segments)
        XCTAssertEqual(trace.count, 3)
        XCTAssertEqual(trace[1].startPosition, trace[1].endPosition, accuracy: 1e-9)
        XCTAssertEqual(trace[2].startPosition, trace[1].endPosition, accuracy: 1e-9)
    }

    func testNonFiniteDurationCollapsesToZeroMovement() {
        // A pathological segment with NaN end time → duration =
        // max(0, NaN-startTime) = 0 (NaN compared to 0 fails the >
        // check). Cursor must not become NaN or escape [0, 1].
        let pathological = ScratchLabBabyScratchStrokeSegment(
            startTime: 0,
            endTime: .nan,
            direction: .forward,
            holdAfter: 0,
            startProgress: 0,
            endProgress: 0
        )
        let trace = ScratchNotationPositionTrace.derive(from: [pathological])
        XCTAssertEqual(trace.count, 1)
        XCTAssertTrue(trace[0].endPosition.isFinite)
        XCTAssertGreaterThanOrEqual(trace[0].endPosition, 0)
        XCTAssertLessThanOrEqual(trace[0].endPosition, 1)
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = (0..<7).map { index in
            segment(
                startTime: Double(index) * 0.18,
                endTime: Double(index) * 0.18 + 0.12,
                direction: index.isMultiple(of: 2) ? .forward : .backward
            )
        }
        let first = ScratchNotationPositionTrace.derive(from: segments)
        for _ in 0..<99 {
            XCTAssertEqual(ScratchNotationPositionTrace.derive(from: segments), first)
        }
    }
}
