import XCTest
@testable import ScratchLab

/// Real-data validation for the motion-grammar derivation produced by
/// `derivePrimitives(from:parameters:)` against the local-only
/// `baby_platter.json` fixture. Assertions are shape-level invariants
/// of the output (non-empty, plausibility band, structural ceiling,
/// alternation, in-span, monotone, confidence bounds, determinism)
/// rather than exact counts — the synthetic-only `NotationGrammarTests`
/// already pin algorithmic behaviour to specific numbers; this suite
/// catches "thresholds collapse everything to nothing" or "noise
/// explosion" regressions on real platter motion under
/// `GrammarParameters.standard`.
///
/// All tests are env-gated by `BABY_PLATTER_FIXTURE_PATH`, mirroring
/// `BabyPlatterFixtureDecodeTests`. They skip cleanly on machines
/// without the local fixture so the test bundle stays green by default.
///
/// To enable:
///
///     export BABY_PLATTER_FIXTURE_PATH="$PWD/Tests/Fixtures/LocalOnly/baby_platter.json"
final class NotationGrammarFixtureTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BABY_PLATTER_FIXTURE_PATH"], !raw.isEmpty else {
            throw XCTSkip(
                "BABY_PLATTER_FIXTURE_PATH is unset; export it to the local baby_platter.json to enable"
            )
        }
        let url = URL(fileURLWithPath: raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "BABY_PLATTER_FIXTURE_PATH points at a non-existent file: \(raw)"
            )
        }
        return url
    }

    private func loadFixture() throws -> PlatterPositionTimeline {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PlatterPositionTimeline.self, from: data)
    }

    private func derive() throws -> (PlatterPositionTimeline, [NotationPrimitive]) {
        let timeline = try loadFixture()
        let primitives = derivePrimitives(from: timeline, parameters: .standard)
        return (timeline, primitives)
    }

    private func startTime(of primitive: NotationPrimitive) -> TimeInterval {
        switch primitive {
        case .directionSegment(let s): return s.startTime
        case .reversal(let r):         return r.time
        case .idleHold(let h):         return h.startTime
        }
    }

    private func endTime(of primitive: NotationPrimitive) -> TimeInterval {
        switch primitive {
        case .directionSegment(let s): return s.endTime
        case .reversal(let r):         return r.time
        case .idleHold(let h):         return h.endTime
        }
    }

    private func minimumConfidence(of primitive: NotationPrimitive) -> Double {
        switch primitive {
        case .directionSegment(let s): return s.minimumConfidence
        case .reversal(let r):         return r.minimumConfidence
        case .idleHold(let h):         return h.minimumConfidence
        }
    }

    private func reversalCount(in primitives: [NotationPrimitive]) -> Int {
        primitives.reduce(into: 0) { acc, p in
            if case .reversal = p { acc += 1 }
        }
    }

    // MARK: - Tests

    /// Catches the "thresholds swallow the signal" regression: real
    /// platter motion must produce at least one primitive.
    func testFixture_DerivationProducesNonEmptyOutput() throws {
        let (_, primitives) = try derive()
        XCTAssertFalse(primitives.isEmpty,
                       "derivePrimitives produced no primitives for the baby_platter fixture")
    }

    /// Reversal count must fall within a meaningful plausibility band
    /// at the tuned `GrammarParameters.standard` defaults:
    ///
    /// - Lower bound (10): catches "thresholds collapsed the signal".
    ///   At the tuned epsilon, real baby-scratch motion produces dozens
    ///   of derivative-sign-flips at click-anchor seams.
    /// - Upper bound (samples.count / 5): a fixture-relative sanity
    ///   ceiling — one reversal per ≤ 5 samples is implausibly noisy
    ///   regardless of fixture size, so this catches "noise explosion"
    ///   without baking in this fixture's exact sample count.
    ///
    /// The band intentionally does **not** target any "perceived stroke"
    /// count — see `GrammarParameters` doc for the rationale.
    func testFixture_ReversalCountInPlausibilityBand() throws {
        let (timeline, primitives) = try derive()
        let reversals = reversalCount(in: primitives)
        let ceiling = timeline.samples.count / 5
        XCTAssertGreaterThanOrEqual(
            reversals, 10,
            "expected ≥ 10 reversals at tuned defaults on real baby-scratch motion, got \(reversals)"
        )
        XCTAssertLessThanOrEqual(
            reversals, ceiling,
            "reversal count \(reversals) exceeds the sample-density-relative ceiling \(ceiling)"
        )
    }

    /// Structural invariant independent of any tuning: a reversal can
    /// only occur at the seam between two click-anchored samples (the
    /// fixture's interpolated samples between anchors have constant
    /// velocity, so no sign-flip can land between them). Therefore
    /// `reversalCount` is bounded above by the count of samples whose
    /// `confidence == 1.0`.
    func testFixture_ReversalCountBoundedByAnchorSampleCount() throws {
        let (timeline, primitives) = try derive()
        let reversals = reversalCount(in: primitives)
        let anchors = timeline.samples.filter { $0.confidence == 1.0 }.count
        XCTAssertLessThanOrEqual(
            reversals, anchors,
            "reversal count \(reversals) exceeds click-anchor count \(anchors); reversals can only occur at clicked-sample seams"
        )
    }

    /// Walks the output and asserts the algorithmic invariant under the
    /// **lenient** alternation reading:
    ///
    /// - Two `DirectionSegment`s with **no** primitive between them must
    ///   alternate sign.
    /// - Two `DirectionSegment`s separated only by a `Reversal` must
    ///   alternate sign (this is the reversal's reason for existence).
    /// - Two `DirectionSegment`s separated by an `IdleHold` may share
    ///   the same sign — a pause-and-continue is legitimate motion and
    ///   the idle hold resets the alternation chain.
    ///
    /// Implementation: clear the running `previousDirection` whenever
    /// an `IdleHold` is encountered.
    func testFixture_AdjacentDirectionSegmentsAlternateSign() throws {
        let (_, primitives) = try derive()
        var previousDirection: Direction? = nil
        for (index, primitive) in primitives.enumerated() {
            switch primitive {
            case .idleHold:
                previousDirection = nil
            case .reversal:
                continue
            case .directionSegment(let segment):
                if let previous = previousDirection {
                    XCTAssertNotEqual(
                        segment.direction,
                        previous,
                        "DirectionSegment at index \(index) repeats direction \(segment.direction) with no intervening IdleHold; adjacent direction segments not separated by an IdleHold must alternate"
                    )
                }
                previousDirection = segment.direction
            }
        }
    }

    /// Every emitted primitive's time(s) must fall inside the source
    /// timeline's span. Catches off-by-one or interpolation drift in
    /// the derivation.
    func testFixture_AllPrimitivesInsideTimelineSpan() throws {
        let (timeline, primitives) = try derive()
        for (index, primitive) in primitives.enumerated() {
            let start = startTime(of: primitive)
            let end = endTime(of: primitive)
            XCTAssertGreaterThanOrEqual(
                start, timeline.startTime,
                "primitive \(index) start \(start) before timeline.startTime \(timeline.startTime)"
            )
            XCTAssertLessThanOrEqual(
                end, timeline.endTime,
                "primitive \(index) end \(end) after timeline.endTime \(timeline.endTime)"
            )
        }
    }

    /// The output stream is in time-monotonic order: each primitive's
    /// start time is at least the previous primitive's start time, and
    /// each primitive ends at or after it starts. Catches reversal
    /// splice-index regressions.
    func testFixture_PrimitiveTimesAreMonotonicallyOrdered() throws {
        let (_, primitives) = try derive()
        var lastStart: TimeInterval = -.infinity
        for (index, primitive) in primitives.enumerated() {
            let start = startTime(of: primitive)
            let end = endTime(of: primitive)
            XCTAssertGreaterThanOrEqual(
                start, lastStart,
                "primitive \(index) start \(start) is earlier than previous start \(lastStart)"
            )
            XCTAssertGreaterThanOrEqual(
                end, start,
                "primitive \(index) end \(end) is earlier than its own start \(start)"
            )
            lastStart = start
        }
    }

    /// Every primitive's `minimumConfidence` must lie in `[0, 1]`. The
    /// derivation must preserve the per-sample confidence bounds
    /// asserted by `BabyPlatterFixtureDecodeTests.testFixtureConfidenceBounds`.
    func testFixture_AllConfidencesInUnitInterval() throws {
        let (_, primitives) = try derive()
        for (index, primitive) in primitives.enumerated() {
            let confidence = minimumConfidence(of: primitive)
            XCTAssertGreaterThanOrEqual(
                confidence, 0.0,
                "primitive \(index) minimumConfidence \(confidence) below 0"
            )
            XCTAssertLessThanOrEqual(
                confidence, 1.0,
                "primitive \(index) minimumConfidence \(confidence) above 1"
            )
        }
    }

    /// Two back-to-back invocations of `derivePrimitives` on the same
    /// fixture must produce equal output. Real-data complement to the
    /// synthetic determinism check in `NotationGrammarTests`.
    func testFixture_DerivationIsDeterministicAcrossInvocations() throws {
        let timeline = try loadFixture()
        let first = derivePrimitives(from: timeline, parameters: .standard)
        let second = derivePrimitives(from: timeline, parameters: .standard)
        XCTAssertEqual(first, second,
                       "derivePrimitives must be deterministic on identical input")
    }
}
