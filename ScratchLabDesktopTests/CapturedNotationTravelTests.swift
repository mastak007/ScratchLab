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

    func testControllerFallbackRebasesStoredExcursionWithoutReadingNormalizedSpeed() throws {
        // These endpoints model finalized/export evidence after a long motor
        // run and no accompanying raw mixer stream. The source value must stay
        // untouched; the event-only adapter may rebase only its stored 0.04
        // excursion and must not interpret finalized `speed` as raw steps.
        let evidence = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 4,
            endTime: 5,
            startPosition: 0.94,
            endPosition: 0.98,
            direction: "forward",
            movementKind: .normalPush,
            speed: 360,
            confidence: 0.9,
            source: "controller"
        )

        let stroke = try XCTUnwrap(PerformedStrokeAdapter.laneStroke(from: evidence))
        XCTAssertEqual(evidence.startPosition, 0.94, accuracy: 1e-12,
                       "finalized/export evidence must not be rewritten to flatten the graph")
        XCTAssertEqual(evidence.endPosition, 0.98, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stroke.measuredStartPosition), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stroke.measuredEndPosition), 0.16, accuracy: 1e-12,
                       "a 0.04 physical excursion uses 16% of the fixed quarter-turn display")
        XCTAssertEqual(try XCTUnwrap(stroke.normalizedTravel), 0.04, accuracy: 1e-12)
        XCTAssertEqual(
            PerformedStrokeAdapter.gestureRelativeNormalizationFrame(for: [evidence]),
            0...1,
            "standalone live notation keeps a fixed display frame instead of rescaling to motor extrema"
        )
    }

    func testBackwardControllerFallbackPreservesSignedSlopeAndStoredExcursion() throws {
        let evidence = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 8,
            endTime: 8.5,
            startPosition: 0.91,
            endPosition: 0.89,
            direction: "backward",
            movementKind: .normalPull,
            speed: 720, // Deliberately ignored by the event-only fallback.
            confidence: 0.9,
            source: "controller"
        )

        let stroke = try XCTUnwrap(PerformedStrokeAdapter.laneStroke(from: evidence))
        let start = try XCTUnwrap(stroke.measuredStartPosition)
        let end = try XCTUnwrap(stroke.measuredEndPosition)
        XCTAssertEqual(start, 0.08, accuracy: 1e-12)
        XCTAssertEqual(end, 0, accuracy: 1e-12)
        XCTAssertLessThan(end - start, 0, "backward notation must keep a negative slope")
        XCTAssertEqual(abs(end - start), 0.08, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(stroke.normalizedTravel), 0.02, accuracy: 1e-12,
                       "the LaneStroke retains exact physical travel separately from display zoom")
        XCTAssertEqual(stroke.startTime, evidence.startTime, accuracy: 1e-12)
        XCTAssertEqual(stroke.endTime, evidence.endTime, accuracy: 1e-12)
    }

    func testControllerDisplayScaleUsesFixedQuarterRevolutionViewportWithoutMutatingPhysicalEvents() throws {
        let cases: [(physical: Double, displayed: Double)] = [
            (0.0625, 0.25),
            (0.125, 0.5),
            (0.25, 1),
            (3, 1)
        ]

        for (index, sample) in cases.enumerated() {
            let event = CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: Double(index),
                endTime: Double(index) + 0.4,
                startPosition: 0,
                endPosition: sample.physical,
                direction: "forward",
                movementKind: .normalPush,
                speed: 1,
                confidence: 0.9,
                source: "controller"
            )

            let stroke = try XCTUnwrap(PerformedStrokeAdapter.laneStroke(from: event))
            XCTAssertEqual(event.startPosition, 0, accuracy: 1e-12)
            XCTAssertEqual(event.endPosition, sample.physical, accuracy: 1e-12,
                           "display zoom must not rewrite physical gesture coordinates")
            XCTAssertEqual(
                ControllerGestureNotationDisplayScale.displayTravelFraction(for: event),
                sample.displayed,
                accuracy: 1e-12
            )
            XCTAssertEqual(try XCTUnwrap(stroke.measuredStartPosition), 0, accuracy: 1e-12)
            XCTAssertEqual(
                try XCTUnwrap(stroke.measuredEndPosition),
                sample.displayed,
                accuracy: 1e-12
            )
            XCTAssertEqual(stroke.startTime, event.startTime, accuracy: 1e-12)
            XCTAssertEqual(stroke.endTime, event.endTime, accuracy: 1e-12)
            XCTAssertEqual(stroke.direction, .forward)
        }
    }

    func testNonControllerPerformedEvidenceKeepsExistingCoordinateFrame() {
        let camera = makeEvent(startPosition: 0.2, endPosition: 0.6)
        XCTAssertEqual(
            ControllerGestureNotationDisplayScale.displayTravelFraction(for: camera),
            0.4,
            accuracy: 1e-12,
            "camera/DVS travel must not receive controller display zoom"
        )
        XCTAssertNil(
            PerformedStrokeAdapter.gestureRelativeNormalizationFrame(for: [camera]),
            "camera/DVS notation keeps its existing coordinate semantics"
        )
    }

    func testMixedControllerAndCameraEvidenceKeepsContentDerivedFrame() {
        let controller = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0,
            endTime: 0.4,
            startPosition: 0,
            endPosition: 0.2,
            direction: "forward",
            movementKind: .normalPush,
            speed: 1,
            confidence: 0.9,
            source: "controller"
        )
        let camera = makeEvent(startPosition: 0.2, endPosition: 0.6)

        XCTAssertNil(
            PerformedStrokeAdapter.gestureRelativeNormalizationFrame(
                for: [controller, camera]
            ),
            "one controller event must not rescale unrelated camera/DVS evidence"
        )
    }

    func testFixedGestureFramePreventsLaterMultiRevolutionRunFromMovingCommittedStroke() throws {
        func controllerEvent(
            startTime: Double,
            endTime: Double,
            startPosition: Double,
            endPosition: Double
        ) -> CaptureCore.DetectedNotationRecordMovementEvent {
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: startTime,
                endTime: endTime,
                startPosition: startPosition,
                endPosition: endPosition,
                direction: "forward",
                movementKind: .normalPush,
                speed: 1,
                confidence: 0.9,
                source: "controller"
            )
        }

        func path(
            _ events: [CaptureCore.DetectedNotationRecordMovementEvent]
        ) throws -> MotionPath {
            let strokes = try events.map {
                try XCTUnwrap(PerformedStrokeAdapter.laneStroke(from: $0))
            }
            let content = LaneContent(
                strokes: strokes,
                segments: [],
                beatsPerMinute: nil,
                duration: events.map(\.endTime).max() ?? 0.1,
                loops: false
            )
            let frame = try XCTUnwrap(
                PerformedStrokeAdapter.gestureRelativeNormalizationFrame(for: events)
            )
            return ScratchStrokeGeometry.motionPath(for: content, normalizingTo: frame)
        }

        let committed = controllerEvent(
            startTime: 0,
            endTime: 0.25,
            startPosition: 0,
            endPosition: 0.125
        )
        let laterMultiRevolution = controllerEvent(
            startTime: 1,
            endTime: 4,
            startPosition: 0,
            endPosition: 3
        )
        let before = try path([committed])
        let after = try path([committed, laterMultiRevolution])
        let beforeStroke = try XCTUnwrap(before.segments.first { !$0.isHold })
        let afterStroke = try XCTUnwrap(after.segments.first { !$0.isHold })

        XCTAssertEqual(afterStroke.startTime, beforeStroke.startTime, accuracy: 1e-12)
        XCTAssertEqual(afterStroke.endTime, beforeStroke.endTime, accuracy: 1e-12)
        XCTAssertEqual(afterStroke.startPosition, beforeStroke.startPosition, accuracy: 1e-12)
        XCTAssertEqual(afterStroke.endPosition, beforeStroke.endPosition, accuracy: 1e-12)
        XCTAssertEqual(afterStroke.endPosition, 0.5, accuracy: 1e-12)
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

// MARK: - Common comparison domain (stacked TARGET / MY PERFORMANCE)

final class ScratchPhraseChartComparisonDomainTests: XCTestCase {

    func testCommonDomainIsTargetAuthoritative() {
        // Target spans 3 s. The performed take's own span is irrelevant —
        // the stacked comparison displays the TARGET's domain for both charts.
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: 3.0)
        XCTAssertEqual(domain.lowerBound, 0.0)
        XCTAssertEqual(domain.upperBound, 3.0, accuracy: 1e-9)
    }

    func testCommonDomainNeverCollapses() {
        // A degenerate (empty) target still yields a usable, non-zero domain.
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: 0.0)
        XCTAssertGreaterThan(domain.upperBound - domain.lowerBound, 0.0)
    }

    func testSameMusicalTimeMapsToSameNormalizedX() {
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: 3.0)
        let width = 300.0
        // Halfway through the target (1.5 s) maps to the horizontal centre —
        // the exact same x a performed stroke at 1.5 s gets, because both
        // charts consume this one domain.
        let x = ScratchPhraseChartComparisonDomain.normalizedX(time: 1.5, domain: domain, width: width)
        XCTAssertEqual(x, 150.0, accuracy: 1e-9)

        // The mapping is linear and domain-relative: a performed event at the
        // target's right edge (3.0 s) maps to the right edge regardless of the
        // performed take's own maximum end time.
        let rightEdge = ScratchPhraseChartComparisonDomain.normalizedX(time: 3.0, domain: domain, width: width)
        XCTAssertEqual(rightEdge, width, accuracy: 1e-9)
    }

    func testDomainIsIndependentOfPerformedSpan() {
        // A performed take ending at 1.2 s must NOT rescale the chart: the
        // displayed domain still spans the target's 3.0 s, so a performed
        // stroke at 1.2 s lands at 40% width, not 100%.
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: 3.0)
        let width = 100.0
        let x = ScratchPhraseChartComparisonDomain.normalizedX(time: 1.2, domain: domain, width: width)
        XCTAssertEqual(x, 40.0, accuracy: 1e-9)
    }

    func testPerformedEventPastTargetEndOverflowsWithoutRescaling() {
        // A performed stroke whose time exceeds the target's duration must NOT
        // rescale the shared domain — it maps to an x past the right edge
        // (clipped by the renderer), and the target's duration stays
        // authoritative. This is the "duration mismatch" contract: a longer
        // performed take never stretches the TARGET's time axis.
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: 3.0)
        let width = 300.0
        let overflow = ScratchPhraseChartComparisonDomain.normalizedX(time: 4.0, domain: domain, width: width)
        XCTAssertGreaterThan(overflow, width, "an over-long performed stroke must overflow, not rescale the target domain")
        XCTAssertEqual(domain.upperBound, 3.0, accuracy: 1e-9)
    }
}
