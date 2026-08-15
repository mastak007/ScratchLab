// V3.2 Phase 2 — canonical ScratchNotationPanel presentation.
//
// These tests pin the SEMANTIC regression gate from the Phase 2 spec against
// deterministic geometry/data — never a rendered pixel — per the project's
// pure-geometry testing convention (see ScratchStrokeGeometryTravelAmplitudeTests,
// LaneFaderSpanAdapterTests). ScratchNotationPanel itself contributes no new
// notation math; it only routes canonical data into the existing
// ScratchPhraseChartView / ScratchStrokeGeometry / faderAuthoritySpans
// pipeline, so these tests exercise exactly that routing plus the one new
// pure function (`ScratchStrokeGeometry.turnaroundAnchors`).

import CoreGraphics
import XCTest
@testable import ScratchLab

final class ScratchNotationPanelTests: XCTestCase {

    // MARK: - Fixtures

    /// The canonical Baby Scratch cycle, materialized at a fixed tempo so
    /// every assertion below is exact, not approximate.
    private func babyScratchNotation(bpm: Double = 90) -> ScratchNotation {
        guard let pattern = ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch"),
              let notation = pattern.materialized(bpm: bpm) else {
            XCTFail("babyScratchCycle must materialize at a valid bpm")
            return ScratchNotation(version: 1, scratchID: "unreachable", demoStart: 0, demoEnd: 0,
                                    phraseStart: 0, phraseEnd: 0, timingBasis: "seconds", strokes: [])
        }
        return notation
    }

    // MARK: - 1 & 7. Baby Scratch fader authority: OPEN throughout, no cuts

    func testBabyScratchFaderAuthorityIsOpenThroughoutWithNoClosedSection() {
        let notation = babyScratchNotation()
        XCTAssertTrue(notation.faderEvents.isEmpty,
                       "babyScratchCycle must have no canonical fader-edge channel — per-stroke state is the sole description")

        let spans = notation.faderAuthoritySpans(documentEnd: notation.timelineDuration)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { $0.state == .open },
                      "every authoritative fader span for Baby Scratch must be OPEN")
        XCTAssertFalse(spans.contains { $0.state == .closed },
                       "Baby Scratch must never show a CLOSED section")

        // Contiguous, gapless coverage of the full document — no invented or
        // dropped span between strokes.
        let sorted = spans.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(sorted.first?.startTime ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(sorted.last?.endTime ?? -1, notation.timelineDuration, accuracy: 1e-9)
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertEqual(a.endTime, b.startTime, accuracy: 1e-9, "fader spans must be contiguous, no gaps")
        }
    }

    /// Non-empty canonical `faderEvents` are authoritative even when they
    /// disagree with per-stroke `faderState` — the authority rule the Baby
    /// Scratch gate depends on must hold in the other direction too.
    func testNonEmptyFaderEventsAreAuthoritativeOverConflictingPerStrokeState() {
        let notation = ScratchNotation(
            version: 1, scratchID: "test_fader_authority",
            demoStart: 0, demoEnd: 1.0, phraseStart: 0, phraseEnd: 1.0,
            timingBasis: "seconds",
            strokes: [
                // Per-stroke state says CLOSED — must be overridden by the
                // non-empty faderEvents channel below.
                .init(startTime: 0.0, endTime: 1.0, direction: .forward,
                      speedClassification: .medium, faderState: .closed)
            ],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.5, state: .closed)
            ]
        )
        let spans = notation.faderAuthoritySpans(documentEnd: 1.0)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].state, .open, "the authoritative edge channel wins over per-stroke .closed")
        XCTAssertEqual(spans[1].state, .closed)
    }

    // MARK: - 2 & 3. Platter/fader and Target/Performance share one domain

    func testChartWindowRoutesTheSameSharedDomainToBothLanes() {
        let target = babyScratchNotation()
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: target.timelineDuration)

        let targetWindow = ScratchNotationPanel.chartWindow(lane: .target, domain: domain)
        let performanceWindow = ScratchNotationPanel.chartWindow(lane: .performance, domain: domain)

        XCTAssertEqual(targetWindow.target, domain, "the TARGET panel must read the shared domain as its own window")
        XCTAssertNil(targetWindow.captured)
        XCTAssertEqual(performanceWindow.captured, domain, "the PERFORMANCE panel must read the SAME domain, never a derived one")
        XCTAssertNil(performanceWindow.target)
    }

    func testChartWindowIsNilWhenNoDomainIsSupplied() {
        let window = ScratchNotationPanel.chartWindow(lane: .target, domain: nil)
        XCTAssertNil(window.target)
        XCTAssertNil(window.captured)
    }

    // MARK: - 4. Direction semantics survive presentation mapping

    func testBabyScratchForwardRisesAndBackwardFalls() {
        let notation = babyScratchNotation()
        let content = LaneContent(notation: notation)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let strokeSegments = path.segments.filter { !$0.isHold }

        XCTAssertEqual(strokeSegments.count, 2)
        XCTAssertEqual(strokeSegments[0].kind, .stroke(.forward))
        XCTAssertGreaterThan(strokeSegments[0].endPosition, strokeSegments[0].startPosition,
                             "a forward stroke must rise on the platter-position curve")
        XCTAssertEqual(strokeSegments[1].kind, .stroke(.backward))
        XCTAssertLessThan(strokeSegments[1].endPosition, strokeSegments[1].startPosition,
                          "a backward stroke must fall on the platter-position curve")
    }

    // MARK: - 5. Turnaround anchors correspond to canonical reversal data

    func testBabyScratchTurnaroundAnchorAtTheForwardStrokesEnd() {
        let notation = babyScratchNotation(bpm: 90)
        let content = LaneContent(notation: notation)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let anchors = ScratchStrokeGeometry.turnaroundAnchors(strokes: content.strokes, path: path)

        XCTAssertEqual(anchors.count, 1, "one cycle of Baby Scratch has exactly one forward→backward reversal")
        let forwardStroke = content.strokes.sorted { $0.startTime < $1.startTime }[0]
        XCTAssertEqual(anchors[0].time, forwardStroke.endTime, accuracy: 1e-9,
                       "the turnaround must sit at the forward stroke's own end time, not a decorative extremum")
        XCTAssertEqual(anchors[0].position, path.position(at: forwardStroke.endTime), accuracy: 1e-9)
    }

    func testNoTurnaroundWithoutAForwardToBackwardBoundary() {
        // Two forward strokes in a row: no reversal exists, so no anchor
        // should be invented.
        let content = LaneContent(
            strokes: [
                LaneStroke(startTime: 0, endTime: 0.5, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
                LaneStroke(startTime: 0.5, endTime: 1.0, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
            ],
            segments: [], beatsPerMinute: nil, duration: 1.0, loops: false)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let anchors = ScratchStrokeGeometry.turnaroundAnchors(strokes: content.strokes, path: path)
        XCTAssertTrue(anchors.isEmpty)
    }

    // MARK: - 6. Holds/rests preserve musical time

    func testHoldBetweenStrokesOccupiesItsFullTimeSpanAndStaysFlat() {
        let content = LaneContent(
            strokes: [
                LaneStroke(startTime: 0.0, endTime: 0.5, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
                // 1.0s silent gap — still occupies musical time.
                LaneStroke(startTime: 1.5, endTime: 2.0, direction: .backward, speed: .medium, faderState: .open, isGhost: false),
            ],
            segments: [], beatsPerMinute: nil, duration: 2.0, loops: false)
        let path = ScratchStrokeGeometry.motionPath(for: content)

        let holds = path.segments.filter { $0.isHold }
        let gapHold = holds.first { $0.startTime >= 0.5 - 1e-9 && $0.endTime <= 1.5 + 1e-9 }
        XCTAssertNotNil(gapHold, "the gap between strokes must materialize as an explicit hold segment")
        XCTAssertEqual(gapHold?.startTime ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(gapHold?.endTime ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(gapHold?.startPosition, gapHold?.endPosition, "a hold must stay flat, never read as travel")

        // The full document duration must remain covered start-to-end —
        // silence never collapses the time domain.
        XCTAssertEqual(path.timeRange.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(path.timeRange.upperBound, 2.0, accuracy: 1e-9)
    }

    // MARK: - 8. Presentation mapping never mutates canonical notation data

    func testBuildingPanelInputsDoesNotMutateTheSourceNotation() {
        let original = babyScratchNotation()
        let beforeCopy = original

        // Exercise the same read path the panel exercises: LaneContent
        // construction, motion-path derivation, fader-authority resolution.
        let content = LaneContent(notation: original)
        _ = ScratchStrokeGeometry.motionPath(for: content)
        _ = original.faderAuthoritySpans(documentEnd: original.timelineDuration)
        _ = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: original.timelineDuration)

        XCTAssertEqual(original, beforeCopy, "reading canonical notation for presentation must never mutate it")
    }
}
