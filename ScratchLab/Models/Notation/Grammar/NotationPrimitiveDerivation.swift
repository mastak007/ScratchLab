import Foundation

// MARK: - Public entry point

/// Pure, deterministic derivation of motion primitives from a
/// `PlatterPositionTimeline`.
///
/// Same input + same `parameters` → byte-identical output. The function
/// is referentially transparent: no clocks, no randomness, no I/O.
///
/// Confidence aggregation is strictly conservative — every primitive's
/// `minimumConfidence` is the minimum confidence of any contributing
/// sample. Confidence is never averaged upward and never boosted.
///
/// Output ordering matches the temporal ordering of the underlying
/// samples: a `Reversal` always sits between the closing
/// `DirectionSegment` and the opening one, optionally separated by an
/// `IdleHold` when the bracket is a round-through-idle reversal.
func derivePrimitives(
    from timeline: PlatterPositionTimeline,
    parameters: GrammarParameters = .standard
) -> [NotationPrimitive] {
    let samples = timeline.samples
    guard samples.count >= 2 else { return [] }

    let intervals = classifyIntervals(samples: samples,
                                      epsilon: parameters.idleVelocityEpsilon)
    let rawRuns = groupRuns(intervals: intervals)
    let runs = mergeShortIdleRuns(rawRuns,
                                  samples: samples,
                                  minimumIdleDwell: parameters.minimumIdleDwell)
    return emitPrimitives(runs: runs,
                          samples: samples,
                          cuspVelocityThreshold: parameters.cuspVelocityThreshold)
}

// MARK: - Interval classification

private enum IntervalState {
    case forward
    case reverse
    case idle
}

private struct ClassifiedInterval {
    let state: IntervalState
    /// |velocity| over the interval, in position-units / second.
    let speed: Double
}

private func classifyIntervals(
    samples: [PlatterPositionSample],
    epsilon: Double
) -> [ClassifiedInterval] {
    var out: [ClassifiedInterval] = []
    out.reserveCapacity(samples.count - 1)
    for i in 0..<(samples.count - 1) {
        let dt = samples[i + 1].time - samples[i].time
        let dp = samples[i + 1].position - samples[i].position
        let velocity = dt > 0 ? dp / dt : 0
        let speed = abs(velocity)
        let state: IntervalState
        if speed <= epsilon {
            state = .idle
        } else if velocity > 0 {
            state = .forward
        } else {
            state = .reverse
        }
        out.append(ClassifiedInterval(state: state, speed: speed))
    }
    return out
}

// MARK: - Run grouping

/// A contiguous span of same-state intervals.
///
/// `startSample` ... `endSample` (inclusive) indexes into the source
/// `samples` array. `maxSpeed` is the peak |velocity| over the run's
/// contributing intervals.
private struct Run {
    var state: IntervalState
    var startSample: Int
    var endSample: Int
    var maxSpeed: Double
}

private func groupRuns(intervals: [ClassifiedInterval]) -> [Run] {
    guard !intervals.isEmpty else { return [] }
    var runs: [Run] = []
    var current = Run(state: intervals[0].state,
                      startSample: 0,
                      endSample: 1,
                      maxSpeed: intervals[0].speed)
    for i in 1..<intervals.count {
        let interval = intervals[i]
        if interval.state == current.state {
            current.endSample = i + 1
            if interval.speed > current.maxSpeed { current.maxSpeed = interval.speed }
        } else {
            runs.append(current)
            current = Run(state: interval.state,
                          startSample: i,
                          endSample: i + 1,
                          maxSpeed: interval.speed)
        }
    }
    runs.append(current)
    return runs
}

// MARK: - Short-idle merging

/// Merge idle runs whose duration falls below `minimumIdleDwell` into
/// their neighbours so that sub-dwell jitter does not spawn an
/// `IdleHold` or split same-direction motion.
private func mergeShortIdleRuns(
    _ runs: [Run],
    samples: [PlatterPositionSample],
    minimumIdleDwell: TimeInterval
) -> [Run] {
    var merged: [Run] = []
    var i = 0
    while i < runs.count {
        let run = runs[i]
        let duration = samples[run.endSample].time - samples[run.startSample].time
        let isShortIdle = run.state == .idle && duration < minimumIdleDwell
        if !isShortIdle {
            merged.append(run)
            i += 1
            continue
        }
        let prev = merged.last
        let next: Run? = (i + 1 < runs.count) ? runs[i + 1] : nil
        if let p = prev, let n = next, p.state == n.state, p.state != .idle {
            var combined = p
            combined.endSample = n.endSample
            combined.maxSpeed = max(combined.maxSpeed, max(run.maxSpeed, n.maxSpeed))
            merged.removeLast()
            merged.append(combined)
            i += 2
        } else if let p = prev {
            var combined = p
            combined.endSample = run.endSample
            combined.maxSpeed = max(combined.maxSpeed, run.maxSpeed)
            merged.removeLast()
            merged.append(combined)
            i += 1
        } else if let n = next {
            var combined = n
            combined.startSample = run.startSample
            combined.maxSpeed = max(combined.maxSpeed, run.maxSpeed)
            merged.append(combined)
            i += 2
        } else {
            merged.append(run)
            i += 1
        }
    }
    return merged
}

// MARK: - Primitive emission

private func emitPrimitives(
    runs: [Run],
    samples: [PlatterPositionSample],
    cuspVelocityThreshold: Double
) -> [NotationPrimitive] {
    var output: [NotationPrimitive] = []
    output.reserveCapacity(runs.count * 2)
    // Reversals are staged with an anchor index so they can be spliced
    // in after the closing direction segment (and any intervening idle
    // hold) have been appended. Building them up-front and inserting at
    // the end keeps the function pure and deterministic.
    var pending: [(anchor: Int, reversal: Reversal)] = []

    for (idx, run) in runs.enumerated() {
        switch run.state {
        case .forward, .reverse:
            let direction: Direction = (run.state == .forward) ? .forward : .reverse
            let segment = DirectionSegment(
                direction: direction,
                startTime: samples[run.startSample].time,
                endTime: samples[run.endSample].time,
                startPosition: samples[run.startSample].position,
                endPosition: samples[run.endSample].position,
                minimumConfidence: minConfidence(samples,
                                                 from: run.startSample,
                                                 through: run.endSample)
            )
            output.append(.directionSegment(segment))
        case .idle:
            let band = positionBand(samples,
                                    from: run.startSample,
                                    through: run.endSample)
            let hold = IdleHold(
                startTime: samples[run.startSample].time,
                endTime: samples[run.endSample].time,
                positionLow: band.low,
                positionHigh: band.high,
                minimumConfidence: minConfidence(samples,
                                                  from: run.startSample,
                                                  through: run.endSample)
            )
            output.append(.idleHold(hold))
        }

        guard run.state != .idle else { continue }
        let lookahead = nextDirectionRun(in: runs, after: idx)
        guard let next = lookahead.run, next.state != run.state else { continue }
        let intermediateIdle = lookahead.intermediateIdle
        let reversal = buildReversal(samples: samples,
                                      closingRun: run,
                                      intermediateIdle: intermediateIdle,
                                      openingRun: next,
                                      cuspVelocityThreshold: cuspVelocityThreshold)
        let anchor = output.count + (intermediateIdle != nil ? 1 : 0)
        pending.append((anchor: anchor, reversal: reversal))
    }

    for entry in pending.reversed() {
        output.insert(.reversal(entry.reversal), at: entry.anchor)
    }

    return output
}

private func buildReversal(
    samples: [PlatterPositionSample],
    closingRun: Run,
    intermediateIdle: Run?,
    openingRun: Run,
    cuspVelocityThreshold: Double
) -> Reversal {
    let bracketTime: TimeInterval
    let bracketPosition: Double
    let kind: ReversalKind
    if let idle = intermediateIdle {
        bracketTime = (samples[idle.startSample].time + samples[idle.endSample].time) / 2.0
        bracketPosition = (samples[idle.startSample].position + samples[idle.endSample].position) / 2.0
        kind = .round
    } else {
        let boundary = closingRun.endSample
        bracketTime = samples[boundary].time
        bracketPosition = samples[boundary].position
        kind = (closingRun.maxSpeed > cuspVelocityThreshold
                && openingRun.maxSpeed > cuspVelocityThreshold) ? .cusp : .round
    }
    let confidence = reversalMinConfidence(samples: samples,
                                            closingRun: closingRun,
                                            intermediateIdle: intermediateIdle,
                                            openingRun: openingRun)
    return Reversal(kind: kind,
                    time: bracketTime,
                    position: bracketPosition,
                    minimumConfidence: confidence)
}

// MARK: - Helpers

private func nextDirectionRun(in runs: [Run], after index: Int)
    -> (run: Run?, intermediateIdle: Run?) {
    var idle: Run? = nil
    var i = index + 1
    if i < runs.count, runs[i].state == .idle {
        idle = runs[i]
        i += 1
    }
    if i < runs.count, runs[i].state != .idle {
        return (runs[i], idle)
    }
    return (nil, nil)
}

private func minConfidence(
    _ samples: [PlatterPositionSample],
    from start: Int,
    through end: Int
) -> Double {
    var minimum = samples[start].confidence
    if end > start {
        for i in (start + 1)...end {
            if samples[i].confidence < minimum {
                minimum = samples[i].confidence
            }
        }
    }
    return minimum
}

private func positionBand(
    _ samples: [PlatterPositionSample],
    from start: Int,
    through end: Int
) -> (low: Double, high: Double) {
    var low = samples[start].position
    var high = samples[start].position
    if end > start {
        for i in (start + 1)...end {
            let p = samples[i].position
            if p < low { low = p }
            if p > high { high = p }
        }
    }
    return (low, high)
}

private func reversalMinConfidence(
    samples: [PlatterPositionSample],
    closingRun: Run,
    intermediateIdle: Run?,
    openingRun: Run
) -> Double {
    var minimum = samples[closingRun.endSample].confidence
    if let idle = intermediateIdle {
        for i in idle.startSample...idle.endSample {
            if samples[i].confidence < minimum {
                minimum = samples[i].confidence
            }
        }
    }
    if samples[openingRun.startSample].confidence < minimum {
        minimum = samples[openingRun.startSample].confidence
    }
    return minimum
}
