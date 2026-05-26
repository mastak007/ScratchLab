import XCTest
@testable import ScratchLab

/// Section 1 / Slice 1 — locks the contract of the motion-grammar
/// primitives and the deterministic derivation from
/// `PlatterPositionTimeline`. Synthetic, deterministic inputs only;
/// fixture-backed coverage is deferred to a later slice.
final class NotationGrammarTests: XCTestCase {

    // MARK: - Empty / degenerate inputs

    func testEmptyTimelineYieldsNoPrimitives() {
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0,
            endTime: 1,
            samples: []
        )
        XCTAssertNotNil(timeline)
        let primitives = derivePrimitives(from: timeline!)
        XCTAssertTrue(primitives.isEmpty)
    }

    func testSingleSampleTimelineYieldsNoPrimitives() {
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0,
            endTime: 1,
            samples: [PlatterPositionSample(time: 0.5, position: 0.0, confidence: 1.0)]
        )
        XCTAssertNotNil(timeline)
        let primitives = derivePrimitives(from: timeline!)
        XCTAssertTrue(primitives.isEmpty)
    }

    // MARK: - Monotone direction

    func testMonotoneForwardSweepEmitsSingleForwardSegment() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0,  confidence: 1.0),
            PlatterPositionSample(time: 0.2, position: 0.25, confidence: 1.0),
            PlatterPositionSample(time: 0.4, position: 0.50, confidence: 1.0),
            PlatterPositionSample(time: 0.6, position: 0.75, confidence: 1.0),
            PlatterPositionSample(time: 0.8, position: 1.00, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitives.count, 1)
        guard case .directionSegment(let segment) = primitives[0] else {
            return XCTFail("Expected DirectionSegment, got \(primitives[0])")
        }
        XCTAssertEqual(segment.direction, .forward)
        XCTAssertEqual(segment.startTime, 0.0, accuracy: 1e-9)
        XCTAssertEqual(segment.endTime, 0.8, accuracy: 1e-9)
        XCTAssertEqual(segment.startPosition, 0.0, accuracy: 1e-9)
        XCTAssertEqual(segment.endPosition, 1.0, accuracy: 1e-9)
        XCTAssertEqual(segment.minimumConfidence, 1.0, accuracy: 1e-9)
    }

    // MARK: - Direction + reversals

    func testForwardReverseForwardEmitsThreeSegmentsAndTwoReversals() {
        // Triangle-wave-ish positions: rise → fall → rise.
        // All velocities have magnitude 5.0, well above default eps (0.02)
        // and the default cusp threshold (0.10) → both reversals are cusp.
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.1, position: 0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.2, position: 1.0, confidence: 1.0),
            PlatterPositionSample(time: 0.3, position: 0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.4, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.5, position: 0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.6, position: 1.0, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 0.6,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitives.count, 5,
                       "Expected fwd, reversal, rev, reversal, fwd; got \(primitives)")

        guard case .directionSegment(let seg0) = primitives[0],
              case .reversal(let rev0)         = primitives[1],
              case .directionSegment(let seg1) = primitives[2],
              case .reversal(let rev1)         = primitives[3],
              case .directionSegment(let seg2) = primitives[4]
        else {
            return XCTFail("Unexpected primitive ordering: \(primitives)")
        }

        XCTAssertEqual(seg0.direction, .forward)
        XCTAssertEqual(seg1.direction, .reverse)
        XCTAssertEqual(seg2.direction, .forward)

        XCTAssertEqual(rev0.kind, .cusp)
        XCTAssertEqual(rev0.time, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rev0.position, 1.0, accuracy: 1e-9)

        XCTAssertEqual(rev1.kind, .cusp)
        XCTAssertEqual(rev1.time, 0.4, accuracy: 1e-9)
        XCTAssertEqual(rev1.position, 0.0, accuracy: 1e-9)
    }

    // MARK: - Idle holds

    func testSubEpsilonJitterYieldsIdleHoldAndNoReversals() {
        // All velocity magnitudes here are 0.002 (= 0.001 / 0.5), well
        // below default eps = 0.02. Total span 1.0 s ≥ dwell = 0.05.
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.000, confidence: 1.0),
            PlatterPositionSample(time: 0.5, position: 0.001, confidence: 1.0),
            PlatterPositionSample(time: 1.0, position: 0.000, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 1.0,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitives.count, 1, "Sub-epsilon jitter must not spawn reversals")
        guard case .idleHold(let hold) = primitives[0] else {
            return XCTFail("Expected IdleHold, got \(primitives[0])")
        }
        XCTAssertEqual(hold.startTime, 0.0, accuracy: 1e-9)
        XCTAssertEqual(hold.endTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(hold.positionLow, 0.000, accuracy: 1e-12)
        XCTAssertEqual(hold.positionHigh, 0.001, accuracy: 1e-12)
    }

    // MARK: - Cusp vs round classification

    func testRoundReversalWhenSpeedsBelowCuspThreshold() {
        // Speeds = 0.5 unit/s on both sides; we explicitly raise the
        // cusp threshold so the reversal must classify as round.
        let parameters = GrammarParameters(
            idleVelocityEpsilon: 0.02,
            minimumIdleDwell: 0.05,
            cuspVelocityThreshold: 1.0
        )
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.00, confidence: 1.0),
            PlatterPositionSample(time: 0.1, position: 0.05, confidence: 1.0),
            PlatterPositionSample(time: 0.2, position: 0.00, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 0.2,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: parameters)
        XCTAssertEqual(primitives.count, 3)
        guard case .reversal(let reversal) = primitives[1] else {
            return XCTFail("Expected reversal at index 1, got \(primitives[1])")
        }
        XCTAssertEqual(reversal.kind, .round,
                       "Speeds below cuspVelocityThreshold must classify as round")
    }

    func testRoundReversalThroughIdleHold() {
        // Direction → idle hold (≥ dwell) → opposite direction. The
        // reversal must classify round and sit between the idle hold
        // and the opening direction segment in the output stream.
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0,   confidence: 1.0),
            PlatterPositionSample(time: 0.1, position: 0.5,   confidence: 1.0),
            // Idle dwell: ~0.2 s wide, position barely changes.
            PlatterPositionSample(time: 0.2, position: 0.500, confidence: 1.0),
            PlatterPositionSample(time: 0.3, position: 0.501, confidence: 1.0),
            PlatterPositionSample(time: 0.4, position: 0.500, confidence: 1.0),
            // Reverse run.
            PlatterPositionSample(time: 0.5, position: 0.0,   confidence: 1.0),
            PlatterPositionSample(time: 0.6, position: -0.5,  confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 0.6,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitives.count, 4,
                       "Expected fwd, idle, reversal, rev; got \(primitives)")
        guard case .directionSegment(let seg0) = primitives[0],
              case .idleHold(_)                = primitives[1],
              case .reversal(let reversal)     = primitives[2],
              case .directionSegment(let seg1) = primitives[3]
        else {
            return XCTFail("Unexpected primitive ordering: \(primitives)")
        }
        XCTAssertEqual(seg0.direction, .forward)
        XCTAssertEqual(seg1.direction, .reverse)
        XCTAssertEqual(reversal.kind, .round,
                       "Reversal bracketed by an idle hold must classify as round")
        // Reversal time is the midpoint of the bracketing IdleHold:
        // (samples[1].time + samples[4].time) / 2 = (0.1 + 0.4) / 2.
        XCTAssertEqual(reversal.time, 0.25, accuracy: 1e-9)
    }

    // MARK: - Confidence aggregation

    func testSegmentConfidenceIsMinimumOfContributingSamples() {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0,  confidence: 1.00),
            PlatterPositionSample(time: 0.1, position: 0.25, confidence: 0.42),
            PlatterPositionSample(time: 0.2, position: 0.50, confidence: 0.80),
            PlatterPositionSample(time: 0.3, position: 0.75, confidence: 0.91),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 0.3,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitives.count, 1)
        guard case .directionSegment(let segment) = primitives[0] else {
            return XCTFail("Expected DirectionSegment")
        }
        XCTAssertEqual(segment.minimumConfidence, 0.42, accuracy: 1e-12,
                       "Segment confidence must be the minimum across contributing samples")
    }

    // MARK: - Codable round-trip / determinism

    func testCodableRoundTripIsIdentityAndDeterministic() throws {
        let samples = [
            PlatterPositionSample(time: 0.0, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.1, position: 0.5, confidence: 1.0),
            PlatterPositionSample(time: 0.2, position: 0.0, confidence: 1.0),
            PlatterPositionSample(time: 0.3, position: -0.5, confidence: 1.0),
        ]
        let timeline = PlatterPositionTimeline(
            source: .coachAuthored,
            startTime: 0.0,
            endTime: 0.3,
            samples: samples
        )!
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertFalse(primitives.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let first = try encoder.encode(primitives)
        let decoded = try decoder.decode([NotationPrimitive].self, from: first)
        XCTAssertEqual(decoded, primitives)

        let second = try encoder.encode(decoded)
        XCTAssertEqual(first, second,
                       "Encode → decode → encode must be byte-identical")

        // Determinism across repeated derivation invocations.
        let primitivesAgain = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(primitivesAgain, primitives)
    }
}
