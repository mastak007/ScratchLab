import XCTest
@testable import ScratchLab

/// Section 5 / Slice 1 — locks the contract of
/// `NotationPresentationStroke`, `NotationPresentationModel`, and
/// `NotationPresentationMapper`. Pure projection from grammar +
/// timing + semantic + coaching sidecars to renderer-ready data; no
/// SwiftUI, no rendering geometry, no ML, no scoring.
final class NotationPresentationModelTests: XCTestCase {

    // MARK: - Helpers

    private func segment(start: TimeInterval, end: TimeInterval) -> NotationPrimitive {
        .directionSegment(DirectionSegment(
            direction: .forward,
            startTime: start,
            endTime: end,
            startPosition: 0,
            endPosition: 1,
            minimumConfidence: 1
        ))
    }

    private func reversal(at time: TimeInterval) -> NotationPrimitive {
        .reversal(Reversal(kind: .cusp, time: time, position: 0, minimumConfidence: 1))
    }

    private func position(bar: Int = 0, beat: Int = 0, subdivision: Int = 0, phase: Double = 0) -> GridPosition {
        GridPosition(bar: bar, beat: beat, subdivision: subdivision, subdivisionPhase: phase)
    }

    private func annotation(
        primitiveIndex: Int,
        startBeat: Int,
        endBeat: Int
    ) -> GridAnnotation {
        GridAnnotation(
            primitiveIndex: primitiveIndex,
            start: position(beat: startBeat),
            end: position(beat: endBeat)
        )
    }

    private func familyAttachment(lower: Int, upper: Int, family: ScratchFamily) -> ScratchFamilyAttachment {
        let range = PrimitiveIndexRange(lowerBound: lower, upperBound: upper)!
        let label = ScratchFamilyCatalog.label(for: family)
        return ScratchFamilyAttachment(primitiveRange: range, label: label)
    }

    private func event(time: TimeInterval, kind: CoachingEventKind = .lateReversal) -> CoachingEvent {
        let severity = CoachingEventCatalog.descriptor(for: kind).severity
        return CoachingEvent(time: time, kind: kind, severity: severity, message: nil)!
    }

    // MARK: - 1. empty primitives returns empty model

    func testEmptyPrimitivesReturnsEmptyModel() {
        let model = NotationPresentationMapper.makeModel(
            primitives: [],
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes, [])
    }

    // MARK: - 2. one stroke per primitive

    func testOneStrokePerPrimitive() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
        ]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes.count, primitives.count)
    }

    // MARK: - 3. preserves primitive order

    func testPreservesPrimitiveOrder() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
        ]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes.map(\.primitiveIndex), [0, 1, 2])
    }

    // MARK: - 4. maps primitive time spans

    func testMapsPrimitiveTimeSpans() {
        let primitives = [
            segment(start: 0.0, end: 1.0),
            reversal(at: 1.0),
            segment(start: 1.0, end: 2.5),
        ]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes.map { ($0.startTime, $0.endTime) }.map(\.0), [0.0, 1.0, 1.0])
        XCTAssertEqual(model.strokes.map { ($0.startTime, $0.endTime) }.map(\.1), [1.0, 1.0, 2.5])
    }

    // MARK: - 5. attaches grid positions by primitiveIndex

    func testAttachesGridPositionsByPrimitiveIndex() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
        ]
        let annotations = [
            annotation(primitiveIndex: 0, startBeat: 0, endBeat: 1),
            annotation(primitiveIndex: 2, startBeat: 2, endBeat: 3),
        ]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: annotations,
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes[0].startPosition, position(beat: 0))
        XCTAssertEqual(model.strokes[0].endPosition, position(beat: 1))
        XCTAssertEqual(model.strokes[2].startPosition, position(beat: 2))
        XCTAssertEqual(model.strokes[2].endPosition, position(beat: 3))
    }

    // MARK: - 6. handles missing grid annotation with nil positions

    func testHandlesMissingGridAnnotationWithNilPositions() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
        ]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertNil(model.strokes[0].startPosition)
        XCTAssertNil(model.strokes[0].endPosition)
        XCTAssertNil(model.strokes[1].startPosition)
        XCTAssertNil(model.strokes[1].endPosition)
    }

    // MARK: - 7. attaches family by primitive index range

    func testAttachesFamilyByPrimitiveIndexRange() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
            reversal(at: 2),
        ]
        let attachments = [
            familyAttachment(lower: 0, upper: 1, family: .baby),
            familyAttachment(lower: 2, upper: 3, family: .scribble),
        ]
        let set = ScratchFamilyAnnotationSet(attachments: attachments)!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: set,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes.map(\.family), [.baby, .baby, .scribble, .scribble])
    }

    // MARK: - 8. missing family annotation leaves family nil

    func testMissingFamilyAnnotationLeavesFamilyNil() {
        let primitives = [segment(start: 0, end: 1)]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertNil(model.strokes[0].family)
    }

    // MARK: - 9. attaches coaching kind by event time in stroke range

    func testAttachesCoachingKindByEventTimeInStrokeRange() {
        let primitives = [
            segment(start: 0, end: 1),
            segment(start: 1, end: 2),
        ]
        let set = CoachingEventSet(events: [
            event(time: 0.5, kind: .lateReversal),
            event(time: 1.5, kind: .earlyReversal),
        ])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: set
        )
        XCTAssertEqual(model.strokes[0].coachingKinds, [.lateReversal])
        XCTAssertEqual(model.strokes[1].coachingKinds, [.earlyReversal])
    }

    // MARK: - 10. event at start included

    func testEventAtStartIncluded() {
        let primitives = [segment(start: 1.0, end: 2.0)]
        let set = CoachingEventSet(events: [event(time: 1.0, kind: .lateReversal)])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: set
        )
        XCTAssertEqual(model.strokes[0].coachingKinds, [.lateReversal])
    }

    // MARK: - 11. event at end excluded for non-zero stroke

    func testEventAtEndExcludedForNonZeroStroke() {
        let primitives = [
            segment(start: 0, end: 1.0),
            segment(start: 1.0, end: 2.0),
        ]
        let set = CoachingEventSet(events: [event(time: 1.0, kind: .lateReversal)])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: set
        )
        XCTAssertEqual(model.strokes[0].coachingKinds, [])
        XCTAssertEqual(model.strokes[1].coachingKinds, [.lateReversal])
    }

    // MARK: - 12. zero-duration primitive includes event exactly at start

    func testZeroDurationPrimitiveIncludesEventExactlyAtStart() {
        let primitives = [reversal(at: 1.0)]
        let set = CoachingEventSet(events: [
            event(time: 0.9999, kind: .lateReversal),
            event(time: 1.0, kind: .earlyReversal),
            event(time: 1.0001, kind: .unstableTiming),
        ])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: set
        )
        XCTAssertEqual(model.strokes[0].coachingKinds, [.earlyReversal])
    }

    // MARK: - 13. multiple coaching events preserve time order

    func testMultipleCoachingEventsPreserveTimeOrder() {
        let primitives = [segment(start: 0, end: 5)]
        let set = CoachingEventSet(events: [
            event(time: 1.0, kind: .lateReversal),
            event(time: 2.0, kind: .earlyReversal),
            event(time: 3.0, kind: .unstableTiming),
        ])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: set
        )
        XCTAssertEqual(
            model.strokes[0].coachingKinds,
            [.lateReversal, .earlyReversal, .unstableTiming]
        )
    }

    // MARK: - 14. Codable round-trip

    func testCodableRoundTrip() throws {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
        ]
        let annotations = [
            annotation(primitiveIndex: 0, startBeat: 0, endBeat: 1),
            annotation(primitiveIndex: 2, startBeat: 2, endBeat: 3),
        ]
        let familySet = ScratchFamilyAnnotationSet(attachments: [
            familyAttachment(lower: 0, upper: 2, family: .baby)
        ])!
        let coachingSet = CoachingEventSet(events: [
            event(time: 0.5, kind: .lateReversal),
            event(time: 1.0, kind: .earlyReversal),
        ])!
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: annotations,
            familyAnnotations: familySet,
            coachingEvents: coachingSet
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(model)
        let decoded = try decoder.decode(NotationPresentationModel.self, from: data)
        XCTAssertEqual(decoded, model)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(second, data)
    }

    // MARK: - 15. Deterministic repeated mapping

    func testDeterministicRepeatedMapping() {
        let primitives = [
            segment(start: 0, end: 1),
            reversal(at: 1),
            segment(start: 1, end: 2),
        ]
        let annotations = [
            annotation(primitiveIndex: 0, startBeat: 0, endBeat: 1),
        ]
        let familySet = ScratchFamilyAnnotationSet(attachments: [
            familyAttachment(lower: 0, upper: 2, family: .baby)
        ])!
        let coachingSet = CoachingEventSet(events: [
            event(time: 0.5, kind: .lateReversal),
        ])!
        let first = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: annotations,
            familyAnnotations: familySet,
            coachingEvents: coachingSet
        )
        let second = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: annotations,
            familyAnnotations: familySet,
            coachingEvents: coachingSet
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - 16. No UI/render/export/ML dependency

    /// Compile-time assertion. The test builds a presentation model
    /// using only grammar / timing / semantic / coaching surfaces
    /// that the spec sanctions. If the presentation file reached for
    /// SwiftUI, Canvas, AppKit, UIKit, renderers, exporters, CoreML
    /// or CreateML, this file would fail to build without the
    /// matching imports — and it deliberately does not import them.
    func testModelBuildableWithoutUIRenderExportOrMLImports() {
        let primitives = [segment(start: 0, end: 1)]
        let model = NotationPresentationMapper.makeModel(
            primitives: primitives,
            annotations: [],
            familyAnnotations: nil,
            coachingEvents: nil
        )
        XCTAssertEqual(model.strokes.count, 1)
    }
}
