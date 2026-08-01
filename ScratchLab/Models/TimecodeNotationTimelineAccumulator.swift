import Foundation

/// Pure, value-type accumulator that merges a sequence of trusted
/// `PlatterPositionTimeline` windows — each one admitted by
/// `TimecodeNotationTrustGate` and typically returned by
/// `TimecodeControlPipeline.flushDecode()` — into one continuous,
/// take-relative timeline suitable for `derivePrimitives(from:)` at take
/// finalization.
///
/// Deliberately dumb: it never invents, interpolates, or extrapolates a
/// sample. If the caller only ever appends `.trusted` windows, any real gap
/// between two appended windows (a stale, missing, stopped, or
/// unknown-direction interval the trust gate rejected) survives in the
/// accumulated timeline as an honest time jump between consecutive samples
/// — never filled in.
struct TimecodeNotationTimelineAccumulator: Equatable, Sendable {
    /// Pipeline-clock time (the same time domain as
    /// `PlatterPositionTimeline` sample times) at which the take started
    /// recording. Every accumulated sample's `time` is rebased relative to
    /// this, so the accumulated timeline reads as take-relative seconds
    /// starting near zero rather than an absolute pipeline clock value.
    let takeStartTime: TimeInterval

    private(set) var samples: [PlatterPositionSample] = []

    init(takeStartTime: TimeInterval) {
        self.takeStartTime = takeStartTime
    }

    /// Rebased (take-relative) time of the most recently accumulated
    /// sample, if any. Used as the dedup/monotonicity cutoff for the next
    /// `append(window:)` call.
    var lastAccumulatedTime: TimeInterval? { samples.last?.time }

    /// Merges `window`'s samples into the accumulator, rebased to
    /// `takeStartTime`.
    ///
    /// Only samples whose rebased time is strictly after the last
    /// already-accumulated sample's time are kept. Because
    /// `PlatterPositionTimeline.samples` is itself guaranteed sorted and
    /// non-decreasing, this single cutoff both deduplicates overlapping
    /// pipeline windows (a window that re-reports part of what a previous
    /// window already covered) and guarantees the accumulated timeline
    /// stays strictly monotonic — matching `PlatterPositionTimeline`'s own
    /// invariant. Position and confidence values are carried through
    /// unchanged: never averaged, boosted, or otherwise made more
    /// optimistic than the source sample reported.
    mutating func append(window: PlatterPositionTimeline) {
        guard !window.samples.isEmpty else { return }
        let cutoff = samples.last?.time
        for sample in window.samples {
            let rebasedTime = sample.time - takeStartTime
            if let cutoff, rebasedTime <= cutoff { continue }
            samples.append(
                PlatterPositionSample(
                    time: rebasedTime,
                    position: sample.position,
                    confidence: sample.confidence
                )
            )
        }
    }

    /// Builds the accumulated `.timecodeLive` timeline for
    /// `derivePrimitives(from:)`. `nil` when nothing was ever accumulated.
    func finalizedTimeline() -> PlatterPositionTimeline? {
        guard let first = samples.first, let last = samples.last else { return nil }
        return PlatterPositionTimeline(
            source: .timecodeLive,
            startTime: first.time,
            endTime: last.time,
            samples: samples
        )
    }
}
