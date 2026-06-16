// Tests for CapturedNotationStrokeGeometry: proportional travel-fraction derivation
// from captured DetectedNotationRecordMovementEvent position delta.
//
// Pure model tests — no SwiftUI, no Canvas, no GraphicsContext.
// Covers: scaling by position delta, no promotion on short travel, direction-agnostic
// fraction, zero delta → zero fraction (idle suppression), and count preservation with
// variable travel.

import XCTest
@testable import ScratchLab

final class CapturedNotationTravelTests: XCTestCase {

    private func makeEvent(
        startPosition: Double,
        endPosition: Double,
        direction: String = "forward",
        movementKind: ScratchMovementKind = .normalPush,
        startTime: Double = 0.0,
        endTime: Double = 0.4
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime, endTime: endTime,
            startPosition: startPosition, endPosition: endPosition,
            direction: direction, movementKind: movementKind,
            speed: 0.5, confidence: 0.8, source: "detected"
        )
    }

    // MARK: - Travel fraction

    func testCapturedNotationScalesStrokeByTravelFraction() {
        let fullEvent    = makeEvent(startPosition: 0.0, endPosition: 1.0)
        let halfEvent    = makeEvent(startPosition: 0.0, endPosition: 0.5)
        let quarterEvent = makeEvent(startPosition: 0.0, endPosition: 0.25)

        XCTAssertEqual(CapturedNotationStrokeGeometry.travelFraction(for: fullEvent),    1.0,  accuracy: 1e-6)
        XCTAssertEqual(CapturedNotationStrokeGeometry.travelFraction(for: halfEvent),    0.5,  accuracy: 1e-6)
        XCTAssertEqual(CapturedNotationStrokeGeometry.travelFraction(for: quarterEvent), 0.25, accuracy: 1e-6)

        XCTAssertGreaterThan(
            CapturedNotationStrokeGeometry.travelFraction(for: fullEvent),
            CapturedNotationStrokeGeometry.travelFraction(for: halfEvent))
        XCTAssertGreaterThan(
            CapturedNotationStrokeGeometry.travelFraction(for: halfEvent),
            CapturedNotationStrokeGeometry.travelFraction(for: quarterEvent))
    }

    func testShortTravelStrokeDoesNotPromoteToFullAmplitude() {
        let shortEvent = makeEvent(startPosition: 0.0, endPosition: 0.3)
        let fullEvent  = makeEvent(startPosition: 0.0, endPosition: 1.0)

        let shortFraction = CapturedNotationStrokeGeometry.travelFraction(for: shortEvent)
        let fullFraction  = CapturedNotationStrokeGeometry.travelFraction(for: fullEvent)

        XCTAssertEqual(shortFraction, 0.3, accuracy: 1e-6)
        XCTAssertLessThan(shortFraction, fullFraction,
                          "Short-travel stroke must not be promoted to full amplitude")
        XCTAssertLessThan(shortFraction, 0.4,
                          "A 0.3 travel fraction must remain below 0.4")
    }

    func testDirectionChangePreservesProportionalAmplitude() {
        // Direction reversal must not inflate the travel fraction to 1.0.
        let forwardEvent  = makeEvent(startPosition: 0.1, endPosition: 0.5, direction: "forward")
        let backwardEvent = makeEvent(startPosition: 0.5, endPosition: 0.1, direction: "backward")

        let fFraction = CapturedNotationStrokeGeometry.travelFraction(for: forwardEvent)
        let bFraction = CapturedNotationStrokeGeometry.travelFraction(for: backwardEvent)

        // Both cover the same 0.4 position delta — fractions must be equal.
        XCTAssertEqual(fFraction, 0.4, accuracy: 1e-6)
        XCTAssertEqual(bFraction, 0.4, accuracy: 1e-6,
                       "Direction change must not force amplitude to 1.0")
        XCTAssertEqual(fFraction, bFraction, accuracy: 1e-6)
    }

    func testIdleMovementDoesNotCreateNotationStroke() {
        // An event with identical start and end positions (zero travel) must produce
        // travelFraction 0.0, which the renderer uses to suppress the stroke.
        let idleEvent = makeEvent(startPosition: 0.5, endPosition: 0.5)
        XCTAssertEqual(
            CapturedNotationStrokeGeometry.travelFraction(for: idleEvent), 0.0,
            accuracy: 1e-9,
            "Zero-travel event must produce travelFraction 0 — no notation stroke drawn")
    }

    func testVariableTravelPreservesStrokeCount() {
        // Events with different travel amounts all produce valid fractions; none are
        // collapsed or merged by the travel computation (count preserved).
        let events: [CaptureCore.DetectedNotationRecordMovementEvent] = [
            makeEvent(startPosition: 0.0, endPosition: 1.0, direction: "forward",  startTime: 0.0, endTime: 0.3),
            makeEvent(startPosition: 1.0, endPosition: 0.4, direction: "backward", startTime: 0.4, endTime: 0.7),
            makeEvent(startPosition: 0.4, endPosition: 0.8, direction: "forward",  startTime: 0.8, endTime: 1.1),
        ]

        let fractions = events.map { CapturedNotationStrokeGeometry.travelFraction(for: $0) }

        XCTAssertEqual(fractions.count, 3, "All events produce a fraction — none dropped")
        XCTAssertEqual(fractions[0], 1.0, accuracy: 1e-6, "Event 0: full travel")
        XCTAssertEqual(fractions[1], 0.6, accuracy: 1e-6, "Event 1: 0.6 backward travel")
        XCTAssertEqual(fractions[2], 0.4, accuracy: 1e-6, "Event 2: 0.4 forward travel")

        // All non-zero → all events would render (stroke count unchanged).
        XCTAssertTrue(fractions.allSatisfy { $0 > 0 }, "All events have travel — all would render")
    }

    // MARK: - Clamping

    func testTravelFractionClampedToUnitRange() {
        // Over-range delta must clamp to 1.0; reversed-coordinate delta stays non-negative.
        let overEvent  = makeEvent(startPosition: 0.0, endPosition: 1.5)   // delta 1.5 → 1.0
        let underEvent = makeEvent(startPosition: 0.3, endPosition: 0.0)   // reversed, delta 0.3

        XCTAssertEqual(CapturedNotationStrokeGeometry.travelFraction(for: overEvent),  1.0, accuracy: 1e-6,
                       "Over-range delta must clamp to 1.0")
        XCTAssertEqual(CapturedNotationStrokeGeometry.travelFraction(for: underEvent), 0.3, accuracy: 1e-6,
                       "Reversed positions use abs — still yields the correct positive fraction")
    }
}
