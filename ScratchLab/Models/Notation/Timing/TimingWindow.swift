import Foundation

// MARK: - TimingWindow

/// A tolerance band around a target time, in seconds. Asymmetric by
/// construction: `earlyTolerance` bounds how far before the target a
/// drift is still considered "within window," and `lateTolerance`
/// bounds how far after.
///
/// Both tolerances are finite and `>= 0`. A symmetric window passes
/// the same value for both. A window with both tolerances zero matches
/// only exact-time hits (drift == 0).
///
/// `contains(drift:)` is closed on both ends:
///
///     window.contains(drift: -window.earlyTolerance) == true
///     window.contains(drift:  window.lateTolerance)  == true
///
/// `TimingWindow` carries no musical metadata — no BPM, no grid
/// reference, no beat fraction. It is purely a band on a number line
/// of seconds. Mapping a `GridPosition` onto an expected time and then
/// comparing it against an actual primitive time is the evaluator's
/// job; the window itself is grid-agnostic.
struct TimingWindow: Equatable, Sendable, Codable {
    let earlyTolerance: TimeInterval
    let lateTolerance: TimeInterval

    init?(earlyTolerance: TimeInterval, lateTolerance: TimeInterval) {
        guard earlyTolerance.isFinite, earlyTolerance >= 0 else { return nil }
        guard lateTolerance.isFinite, lateTolerance >= 0 else { return nil }
        self.earlyTolerance = earlyTolerance
        self.lateTolerance = lateTolerance
    }

    func contains(drift: TimeInterval) -> Bool {
        guard drift.isFinite else { return false }
        return drift >= -earlyTolerance && drift <= lateTolerance
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case earlyTolerance, lateTolerance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let early = try container.decode(TimeInterval.self, forKey: .earlyTolerance)
        let late = try container.decode(TimeInterval.self, forKey: .lateTolerance)
        guard early.isFinite, early >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .earlyTolerance,
                in: container,
                debugDescription: "earlyTolerance must be finite and ≥ 0, got \(early)"
            )
        }
        guard late.isFinite, late >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .lateTolerance,
                in: container,
                debugDescription: "lateTolerance must be finite and ≥ 0, got \(late)"
            )
        }
        self.earlyTolerance = early
        self.lateTolerance = late
    }
}

// MARK: - TimingDrift

/// A per-primitive drift measurement: how far the primitive's actual
/// start time strayed from its expected time, and whether that drift
/// landed within a `TimingWindow`.
///
/// `drift == actualTime - expectedTime` by construction. Negative drift
/// means the primitive arrived early; positive means late.
///
/// The decoder enforces non-negative `primitiveIndex` and finite
/// `expectedTime`, `actualTime`, `drift`. The evaluator does not
/// throw, so a hand-crafted JSON is the only way to introduce
/// non-finite values — and the decoder rejects those.
struct TimingDrift: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let expectedTime: TimeInterval
    let actualTime: TimeInterval
    let drift: TimeInterval
    let isWithinWindow: Bool

    init(primitiveIndex: Int,
         expectedTime: TimeInterval,
         actualTime: TimeInterval,
         drift: TimeInterval,
         isWithinWindow: Bool) {
        self.primitiveIndex = primitiveIndex
        self.expectedTime = expectedTime
        self.actualTime = actualTime
        self.drift = drift
        self.isWithinWindow = isWithinWindow
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case primitiveIndex, expectedTime, actualTime, drift, isWithinWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primitiveIndex = try container.decode(Int.self, forKey: .primitiveIndex)
        guard primitiveIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .primitiveIndex,
                in: container,
                debugDescription: "primitiveIndex must be ≥ 0, got \(primitiveIndex)"
            )
        }
        let expectedTime = try container.decode(TimeInterval.self, forKey: .expectedTime)
        guard expectedTime.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .expectedTime,
                in: container,
                debugDescription: "expectedTime must be finite, got \(expectedTime)"
            )
        }
        let actualTime = try container.decode(TimeInterval.self, forKey: .actualTime)
        guard actualTime.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .actualTime,
                in: container,
                debugDescription: "actualTime must be finite, got \(actualTime)"
            )
        }
        let drift = try container.decode(TimeInterval.self, forKey: .drift)
        guard drift.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .drift,
                in: container,
                debugDescription: "drift must be finite, got \(drift)"
            )
        }
        let isWithinWindow = try container.decode(Bool.self, forKey: .isWithinWindow)
        self.primitiveIndex = primitiveIndex
        self.expectedTime = expectedTime
        self.actualTime = actualTime
        self.drift = drift
        self.isWithinWindow = isWithinWindow
    }
}

// MARK: - TimingWindowEvaluator

/// Pure, deterministic projection of `(annotations, primitives,
/// expectedStartTimes, window)` to a `[TimingDrift]` stream.
///
/// One `TimingDrift` is emitted per annotation that satisfies all of:
///
/// - `annotation.primitiveIndex` is in `0 ..< primitives.count`.
/// - `expectedStartTimes[annotation.primitiveIndex]` is non-nil.
///
/// Annotations that fail either condition are silently skipped — the
/// evaluator never throws and never produces a partial / sentinel
/// `TimingDrift` for missing data. Output preserves annotation order.
///
/// `drift = actualTime − expectedTime`, where `actualTime` is the
/// primitive's `startTime` (point primitives like `Reversal` use their
/// `time` field). `isWithinWindow = window.contains(drift:)`. No
/// rounding, no snap-to-grid, no scoring percentages.
enum TimingWindowEvaluator {

    static func evaluate(
        annotations: [GridAnnotation],
        primitives: [NotationPrimitive],
        expectedStartTimes: [Int: TimeInterval],
        window: TimingWindow
    ) -> [TimingDrift] {
        var output: [TimingDrift] = []
        output.reserveCapacity(annotations.count)
        for annotation in annotations {
            let index = annotation.primitiveIndex
            guard primitives.indices.contains(index) else { continue }
            guard let expected = expectedStartTimes[index] else { continue }
            let actual = startTime(of: primitives[index])
            let drift = actual - expected
            let isWithin = window.contains(drift: drift)
            output.append(
                TimingDrift(primitiveIndex: index,
                             expectedTime: expected,
                             actualTime: actual,
                             drift: drift,
                             isWithinWindow: isWithin)
            )
        }
        return output
    }

    // MARK: Primitive start-time extraction

    /// `DirectionSegment` / `IdleHold` use their `startTime`.
    /// `Reversal` is a point event — its `time` serves as both start
    /// and the value used for drift. Implemented as a private switch
    /// so Section 1 types stay byte-identical.
    private static func startTime(of primitive: NotationPrimitive) -> TimeInterval {
        switch primitive {
        case .directionSegment(let segment): return segment.startTime
        case .reversal(let reversal):        return reversal.time
        case .idleHold(let hold):            return hold.startTime
        }
    }
}
