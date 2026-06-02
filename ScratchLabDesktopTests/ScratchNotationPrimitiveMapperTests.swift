import XCTest
@testable import ScratchLab

/// Section 3 / adapter — locks the contract of
/// `ScratchNotationPrimitiveMapper.derivePrimitives(from:)`.
/// Pure authored-notation → motion-primitive mapping; no ML,
/// no UI, no coaching events, no phrase boundaries.
final class ScratchNotationPrimitiveMapperTests: XCTestCase {

    // MARK: - Helpers

    private func stroke(
        startTime: TimeInterval,
        endTime: TimeInterval,
        direction: ScratchNotationDirection,
        speed: ScratchNotationSpeedClassification = .medium,
        fader: ScratchNotationFaderState = .open
    ) -> ScratchNotation.Stroke {
        ScratchNotation.Stroke(
            startTime: startTime,
            endTime: endTime,
            direction: direction,
            speedClassification: speed,
            faderState: fader
        )
    }

    private func forward(start: TimeInterval, end: TimeInterval) -> ScratchNotation.Stroke {
        stroke(startTime: start, endTime: end, direction: .forward)
    }

    private func backward(start: TimeInterval, end: TimeInterval) -> ScratchNotation.Stroke {
        stroke(startTime: start, endTime: end, direction: .backward)
    }

    private func derive(from strokes: [ScratchNotation.Stroke]) -> [NotationPrimitive] {
        ScratchNotationPrimitiveMapper.derivePrimitives(from: strokes)
    }

    // MARK: - 1. Empty strokes → empty primitives

    func testEmptyStrokesReturnsEmptyPrimitives() {
        let primitives = derive(from: [])
        XCTAssertEqual(primitives.count, 0)
    }

    // MARK: - 2. Single forward stroke

    func testSingleForwardStroke() {
        let primitives = derive(from: [forward(start: 0, end: 0.2)])
        XCTAssertEqual(primitives.count, 1)
        guard case .directionSegment(let segment) = primitives[0] else {
            XCTFail("expected directionSegment"); return
        }
        XCTAssertEqual(segment.direction, .forward)
        XCTAssertEqual(segment.startTime, 0)
        XCTAssertEqual(segment.endTime, 0.2)
        XCTAssertEqual(segment.startPosition, 0)
        XCTAssertEqual(segment.endPosition, 1)
        XCTAssertEqual(segment.minimumConfidence, 1.0)
    }

    // MARK: - 3. Single backward stroke

    func testSingleBackwardStroke() {
        let primitives = derive(from: [backward(start: 0.5, end: 1.0)])
        XCTAssertEqual(primitives.count, 1)
        guard case .directionSegment(let segment) = primitives[0] else {
            XCTFail("expected directionSegment"); return
        }
        XCTAssertEqual(segment.direction, .reverse)
        XCTAssertEqual(segment.startTime, 0.5)
        XCTAssertEqual(segment.endTime, 1.0)
        XCTAssertEqual(segment.startPosition, 1)
        XCTAssertEqual(segment.endPosition, 0)
        XCTAssertEqual(segment.minimumConfidence, 1.0)
    }

    // MARK: - 4. Forward + reverse strokes produce a cusp reversal

    func testForwardThenReverseProducesReversal() {
        let strokes = [
            forward(start: 0, end: 0.2),
            backward(start: 0.2, end: 0.5),
        ]
        let primitives = derive(from: strokes)
        // Expected: [.directionSegment(fwd), .reversal(cusp), .directionSegment(rev)]
        XCTAssertEqual(primitives.count, 3)

        guard case .directionSegment(let first) = primitives[0] else {
            XCTFail("primitive 0 expected directionSegment"); return
        }
        XCTAssertEqual(first.direction, .forward)

        guard case .reversal(let reversal) = primitives[1] else {
            XCTFail("primitive 1 expected reversal"); return
        }
        XCTAssertEqual(reversal.kind, .cusp)
        XCTAssertEqual(reversal.time, 0.2, accuracy: 1e-9)
        XCTAssertEqual(reversal.position, 1.0, accuracy: 1e-9)
        XCTAssertEqual(reversal.minimumConfidence, 1.0)

        guard case .directionSegment(let second) = primitives[2] else {
            XCTFail("primitive 2 expected directionSegment"); return
        }
        XCTAssertEqual(second.direction, .reverse)
    }

    // MARK: - 5. Reverse + forward strokes produce a reversal at 0.0

    func testReverseThenForwardProducesReversalAtZero() {
        let strokes = [
            backward(start: 0, end: 0.15),
            forward(start: 0.15, end: 0.3),
        ]
        let primitives = derive(from: strokes)
        guard case .reversal(let reversal) = primitives[1] else {
            XCTFail("expected reversal"); return
        }
        XCTAssertEqual(reversal.time, 0.15, accuracy: 1e-9)
        XCTAssertEqual(reversal.position, 0.0, accuracy: 1e-9)
    }

    // MARK: - 6. Same-direction consecutive strokes skip the reversal

    func testSameDirectionStrokesSkipReversal() {
        let strokes = [
            forward(start: 0, end: 0.1),
            forward(start: 0.1, end: 0.2),
        ]
        let primitives = derive(from: strokes)
        // Two direction segments, zero reversals
        XCTAssertEqual(primitives.count, 2)
        guard case .directionSegment = primitives[0] else {
            XCTFail("primitive 0 expected directionSegment"); return
        }
        guard case .directionSegment = primitives[1] else {
            XCTFail("primitive 1 expected directionSegment, no reversal expected"); return
        }
    }

    // MARK: - 7. Three-stroke alternation (F → B → F)

    func testThreeStrokeAlternation() {
        let strokes = [
            forward(start: 0,     end: 0.15),
            backward(start: 0.15, end: 0.35),
            forward(start: 0.35,  end: 0.5),
        ]
        let primitives = derive(from: strokes)
        // Expected: [seg(F), rev, seg(B), rev, seg(F)] = 5 primitives
        XCTAssertEqual(primitives.count, 5)

        guard case .directionSegment(let s0) = primitives[0] else { XCTFail("0"); return }
        XCTAssertEqual(s0.direction, .forward)
        guard case .reversal(let r1) = primitives[1] else { XCTFail("1"); return }
        XCTAssertEqual(r1.position, 1.0, accuracy: 1e-9) // F→B
        guard case .directionSegment(let s2) = primitives[2] else { XCTFail("2"); return }
        XCTAssertEqual(s2.direction, .reverse)
        guard case .reversal(let r3) = primitives[3] else { XCTFail("3"); return }
        XCTAssertEqual(r3.position, 0.0, accuracy: 1e-9) // B→F
        guard case .directionSegment(let s4) = primitives[4] else { XCTFail("4"); return }
        XCTAssertEqual(s4.direction, .forward)
    }

    // MARK: - 8. Timing is preserved exactly

    func testTimingPreservedExactly() {
        let strokes = [
            forward(start: 0.1234, end: 0.5678),
            backward(start: 0.5678, end: 1.2345),
        ]
        let primitives = derive(from: strokes)
        guard case .directionSegment(let s0) = primitives[0] else { XCTFail("0"); return }
        XCTAssertEqual(s0.startTime, 0.1234, accuracy: 1e-9)
        XCTAssertEqual(s0.endTime,   0.5678, accuracy: 1e-9)
        guard case .reversal(let r) = primitives[1] else { XCTFail("1"); return }
        XCTAssertEqual(r.time, 0.5678, accuracy: 1e-9)
        guard case .directionSegment(let s2) = primitives[2] else { XCTFail("2"); return }
        XCTAssertEqual(s2.startTime, 0.5678, accuracy: 1e-9)
        XCTAssertEqual(s2.endTime,   1.2345, accuracy: 1e-9)
    }

    // MARK: - 9. All primitives carry authored confidence

    func testAllPrimitivesCarryAuthoredConfidence() {
        let strokes = [
            forward(start: 0, end: 0.2),
            backward(start: 0.2, end: 0.5),
            forward(start: 0.5, end: 0.8),
        ]
        let primitives = derive(from: strokes)
        XCTAssertFalse(primitives.isEmpty)
        for (index, primitive) in primitives.enumerated() {
            let confidence: Double
            switch primitive {
            case .directionSegment(let s): confidence = s.minimumConfidence
            case .reversal(let r):        confidence = r.minimumConfidence
            case .idleHold:                continue // none expected from this mapper
            }
            XCTAssertEqual(confidence, 1.0, accuracy: 1e-9,
                           "primitive \(index) confidence \(confidence) != 1.0")
        }
    }

    // MARK: - 10. Determinism across calls

    func testDerivationIsDeterministic() {
        let strokes = [
            forward(start: 0, end: 0.1),
            backward(start: 0.1, end: 0.2),
            forward(start: 0.2, end: 0.3),
        ]
        let first = derive(from: strokes)
        let second = derive(from: strokes)
        XCTAssertEqual(first, second)
    }

    // MARK: - 11. Codable round-trip for produced primitives

    func testCodableRoundTrip() throws {
        let strokes = [
            forward(start: 0, end: 0.2),
            backward(start: 0.2, end: 0.55),
            forward(start: 0.55, end: 0.8),
        ]
        let primitives = derive(from: strokes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(primitives)
        let decoded = try decoder.decode([NotationPrimitive].self, from: data)
        XCTAssertEqual(decoded, primitives)
        // Byte-stable: re-encode matches
        let secondData = try encoder.encode(decoded)
        XCTAssertEqual(secondData, data)
    }

    // MARK: - 12. No idle holds are synthesized

    func testNoIdleHoldsSynthesized() {
        let strokes = [
            forward(start: 0, end: 0.1),
            backward(start: 0.5, end: 0.7), // 0.4 s gap after first stroke
            forward(start: 1.0, end: 1.2),
        ]
        let primitives = derive(from: strokes)
        for (index, primitive) in primitives.enumerated() {
            if case .idleHold = primitive {
                XCTFail("primitive \(index) is an idleHold — mapper must not synthesize holds")
            }
        }
        // Should still produce correct reversals at the stroke boundaries.
        let reversalCount = primitives.reduce(0) { count, p in
            if case .reversal = p { return count + 1 }
            return count
        }
        XCTAssertEqual(reversalCount, 2, "two opposite-direction boundaries produce two reversals")
    }
}
