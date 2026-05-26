import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationPresentationAdapter`. Pure
/// additive projection from `ScratchNotation` to
/// `NotationPresentationModel`; no SwiftUI, no rendering geometry, no
/// export-schema touch, no ML, no scoring.
final class ScratchNotationPresentationAdapterTests: XCTestCase {

    // MARK: - Helpers

    private func stroke(
        start: TimeInterval,
        end: TimeInterval,
        direction: ScratchNotationDirection = .forward,
        speed: ScratchNotationSpeedClassification = .medium,
        fader: ScratchNotationFaderState = .open
    ) -> ScratchNotation.Stroke {
        ScratchNotation.Stroke(
            startTime: start,
            endTime: end,
            direction: direction,
            speedClassification: speed,
            faderState: fader
        )
    }

    private func notation(strokes: [ScratchNotation.Stroke]) -> ScratchNotation {
        ScratchNotation(
            version: 1,
            scratchID: "test",
            demoStart: 0,
            demoEnd: 4,
            phraseStart: nil,
            phraseEnd: nil,
            timingBasis: "audio",
            strokes: strokes
        )
    }

    // MARK: - 1. empty source maps to empty model

    func testEmptyStrokesMapsToEmptyModel() {
        let model = ScratchNotationPresentationAdapter.makeModel(
            from: notation(strokes: [])
        )
        XCTAssertEqual(model.strokes, [])
    }

    // MARK: - 2. source stroke count maps to model stroke count

    func testStrokeCountMatchesSource() {
        let source = notation(strokes: [
            stroke(start: 0,   end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
            stroke(start: 1.0, end: 1.4),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.count, source.strokes.count)
    }

    // MARK: - 3. primitiveIndex is stable 0..<n in source order

    func testPrimitiveIndexIsStableSourceOrder() {
        let source = notation(strokes: [
            stroke(start: 0,   end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
            stroke(start: 1.0, end: 1.4),
            stroke(start: 1.5, end: 1.9, direction: .backward),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.map(\.primitiveIndex), [0, 1, 2, 3])
    }

    // MARK: - 4. startTime / endTime map directly from source

    func testStartAndEndTimesMapDirectly() {
        let source = notation(strokes: [
            stroke(start: 0.10, end: 0.42),
            stroke(start: 0.55, end: 0.91, direction: .backward),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.map(\.startTime), [0.10, 0.55])
        XCTAssertEqual(model.strokes.map(\.endTime),   [0.42, 0.91])
    }

    // MARK: - 5. positions are nil — no GridAnnotation sidecar on ScratchNotation

    func testPositionsAreNil() {
        let source = notation(strokes: [
            stroke(start: 0, end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.startPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.endPosition == nil })
    }

    // MARK: - 6. family is nil — no ScratchFamilyAnnotationSet sidecar

    func testFamilyIsNil() {
        let source = notation(strokes: [
            stroke(start: 0, end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.family == nil })
    }

    // MARK: - 7. coachingKinds is empty — no CoachingEventSet sidecar

    func testCoachingKindsAreEmpty() {
        let source = notation(strokes: [
            stroke(start: 0, end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
        ])
        let model = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.coachingKinds.isEmpty })
    }

    // MARK: - 8. deterministic — repeated mapping returns equal models

    func testRepeatedMappingIsDeterministic() {
        let source = notation(strokes: [
            stroke(start: 0,   end: 0.4),
            stroke(start: 0.5, end: 0.9, direction: .backward),
            stroke(start: 1.0, end: 1.4),
        ])
        let modelA = ScratchNotationPresentationAdapter.makeModel(from: source)
        let modelB = ScratchNotationPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(modelA, modelB)
    }
}
