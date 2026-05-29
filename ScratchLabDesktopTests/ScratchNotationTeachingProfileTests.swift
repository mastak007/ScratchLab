import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationTeachingProfile.project(...)`:
/// a pure, demo-only position reshaper that collapses repeated baby
/// hits into a shallow band and keeps each phrase's tail-forward
/// resolve at full height, while preserving stroke timing and
/// direction exactly so the phrase gate / attack markers / beat grid
/// stay untouched.
final class ScratchNotationTeachingProfileTests: XCTestCase {

    private let repeatCeiling = 0.32
    private let resolveCeiling = 1.0

    // MARK: - Builders

    private func seg(
        _ start: TimeInterval, _ end: TimeInterval,
        _ direction: ScratchMotionDirection,
        _ startPos: Double, _ endPos: Double
    ) -> ScratchNotationPositionTraceSegment {
        ScratchNotationPositionTraceSegment(
            startTime: start, endTime: end,
            startPosition: startPos, endPosition: endPos,
            direction: direction
        )
    }

    private func range(_ start: TimeInterval, _ end: TimeInterval) -> ScratchNotationPhraseRange {
        ScratchNotationPhraseRange(start: start, end: end)
    }

    /// One forward → backward → forward phrase, all full raw sweeps.
    /// The last forward stroke is the resolve.
    private func oneForwardBackForwardPhrase() -> (
        trace: [ScratchNotationPositionTraceSegment],
        ranges: [ScratchNotationPhraseRange]
    ) {
        let trace = [
            seg(0.0, 0.3, .forward, 0.0, 1.0),   // repeat
            seg(0.3, 0.6, .backward, 1.0, 0.0),  // repeat
            seg(0.6, 1.0, .forward, 0.0, 1.0),   // resolve (last forward)
        ]
        return (trace, [range(0.0, 1.0)])
    }

    // MARK: - Repeats / resolve amplitudes

    func testRepeatsStayWithinRepeatCeiling() {
        let (trace, ranges) = oneForwardBackForwardPhrase()
        let out = ScratchNotationTeachingProfile.project(
            trace: trace, phraseRanges: ranges,
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        // First two strokes are repeats: every position in [0, repeatCeiling].
        for s in out.prefix(2) {
            XCTAssertGreaterThanOrEqual(s.startPosition, 0)
            XCTAssertGreaterThanOrEqual(s.endPosition, 0)
            XCTAssertLessThanOrEqual(s.startPosition, repeatCeiling + 1e-9)
            XCTAssertLessThanOrEqual(s.endPosition, repeatCeiling + 1e-9)
        }
        // Repeat forward → 0…repeatCeiling; repeat backward → repeatCeiling…0.
        XCTAssertEqual(out[0].endPosition, repeatCeiling, accuracy: 1e-9)
        XCTAssertEqual(out[1].startPosition, repeatCeiling, accuracy: 1e-9)
    }

    func testExactlyOneResolvePerPhraseReachingResolveCeiling() {
        let (trace, ranges) = oneForwardBackForwardPhrase()
        let out = ScratchNotationTeachingProfile.project(
            trace: trace, phraseRanges: ranges,
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        let resolves = out.filter {
            max($0.startPosition, $0.endPosition) >= resolveCeiling - 1e-9
        }
        XCTAssertEqual(resolves.count, 1, "exactly one resolve per phrase")
        // The resolve is the last forward stroke (index 2): 0 → resolveCeiling.
        XCTAssertEqual(out[2].endPosition, resolveCeiling, accuracy: 1e-9)
    }

    func testResolveIsLastForwardWhenMultipleForwards() {
        // fwd, fwd, back, fwd → only the final forward is the resolve.
        let trace = [
            seg(0.0, 0.2, .forward, 0.0, 1.0),
            seg(0.2, 0.4, .forward, 0.0, 1.0),
            seg(0.4, 0.6, .backward, 1.0, 0.0),
            seg(0.6, 0.9, .forward, 0.0, 1.0),
        ]
        let out = ScratchNotationTeachingProfile.project(
            trace: trace, phraseRanges: [range(0.0, 0.9)],
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        XCTAssertEqual(out[0].endPosition, repeatCeiling, accuracy: 1e-9)
        XCTAssertEqual(out[1].endPosition, repeatCeiling, accuracy: 1e-9)
        XCTAssertEqual(out[3].endPosition, resolveCeiling, accuracy: 1e-9)
        let resolves = out.filter { max($0.startPosition, $0.endPosition) >= resolveCeiling - 1e-9 }
        XCTAssertEqual(resolves.count, 1)
    }

    // MARK: - Timing / direction preserved

    func testTimesAndDirectionsUnchanged() {
        let (trace, ranges) = oneForwardBackForwardPhrase()
        let out = ScratchNotationTeachingProfile.project(
            trace: trace, phraseRanges: ranges,
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        XCTAssertEqual(out.count, trace.count)
        for (o, i) in zip(out, trace) {
            XCTAssertEqual(o.startTime, i.startTime, "startTime must not change")
            XCTAssertEqual(o.endTime, i.endTime, "endTime must not change")
            XCTAssertEqual(o.direction, i.direction, "direction must not change")
        }
    }

    // MARK: - Determinism / empty

    func testDeterministic() {
        let (trace, ranges) = oneForwardBackForwardPhrase()
        let a = ScratchNotationTeachingProfile.project(trace: trace, phraseRanges: ranges)
        let b = ScratchNotationTeachingProfile.project(trace: trace, phraseRanges: ranges)
        XCTAssertEqual(a, b)
    }

    func testEmptyInputSafe() {
        let out = ScratchNotationTeachingProfile.project(
            trace: [], phraseRanges: [range(0, 1)]
        )
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Fallbacks

    func testNoForwardStrokeFallbackAllRepeats() {
        // Phrase with only backward strokes → no resolve; all shallow.
        let trace = [
            seg(0.0, 0.3, .backward, 1.0, 0.0),
            seg(0.3, 0.6, .backward, 1.0, 0.0),
        ]
        let out = ScratchNotationTeachingProfile.project(
            trace: trace, phraseRanges: [range(0.0, 0.6)],
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        for s in out {
            XCTAssertLessThanOrEqual(max(s.startPosition, s.endPosition), repeatCeiling + 1e-9)
        }
        let resolves = out.filter { max($0.startPosition, $0.endPosition) >= resolveCeiling - 1e-9 }
        XCTAssertTrue(resolves.isEmpty, "no forward stroke → no resolve")
    }

    func testSegmentOutsideAnyPhrasePassesThroughUnchanged() {
        let inside = seg(0.0, 0.3, .forward, 0.0, 1.0)
        let outside = seg(5.0, 5.3, .forward, 0.0, 1.0) // beyond the range
        let out = ScratchNotationTeachingProfile.project(
            trace: [inside, outside], phraseRanges: [range(0.0, 0.3)],
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )
        // Out-of-phrase stroke is untouched (still full raw sweep).
        XCTAssertEqual(out[1], outside)
    }

    // MARK: - Bundled-data verification

    func testBundledBabyDataYieldsShallowRepeatsAndOneResolvePerPhrase() {
        let segments = BabyScratchReferenceMotionTimeline.strokeSegments
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        let rawTrace = ScratchNotationRawTrace.build(from: segments)
        let out = ScratchNotationTeachingProfile.project(
            trace: rawTrace, phraseRanges: ranges,
            repeatCeiling: repeatCeiling, resolveCeiling: resolveCeiling
        )

        XCTAssertEqual(ranges.count, 4, "bundled Baby demo has 4 phrases")

        for phrase in ranges {
            let inPhrase = out.enumerated().filter { _, s in
                s.startTime >= phrase.start - 1e-9 && s.endTime <= phrase.end + 1e-9
            }
            XCTAssertFalse(inPhrase.isEmpty)

            let resolves = inPhrase.filter { _, s in
                max(s.startPosition, s.endPosition) >= resolveCeiling - 1e-9
            }
            XCTAssertEqual(resolves.count, 1, "one tall resolve per phrase")
            // The resolve is a forward stroke.
            XCTAssertEqual(resolves.first?.element.direction, .forward)

            // Every non-resolve stroke in the phrase is shallow.
            let resolveIdx = resolves.first!.offset
            for (idx, s) in inPhrase where idx != resolveIdx {
                XCTAssertLessThanOrEqual(
                    max(s.startPosition, s.endPosition), repeatCeiling + 1e-9,
                    "repeats must stay in the low band"
                )
            }
        }
    }
}
