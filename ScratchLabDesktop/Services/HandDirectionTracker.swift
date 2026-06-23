import CoreGraphics
import QuartzCore

/// Stateful Baby Scratch direction tracker.
///
/// Pure Swift — no Vision or UI dependencies — so it can be unit-tested
/// without the capture pipeline.
///
/// Feed raw (unsmoothed) Vision hand points via `recordObservation(rawPoint:at:)`
/// and missed frames via `recordMiss()`. Both return the Direction to display.
///
/// Detection strategy:
///   - Keeps a rolling window of recent samples.
///   - Computes recency-weighted velocity across consecutive samples.
///   - Requires net window displacement so back-and-forth jitter stays idle.
///   - Requires `commitFrames` consecutive agreeing frames before a new direction
///     is committed (hysteresis).
///   - Holds the last committed direction for `holdFrames` missed frames before
///     dropping to `.idle`.
///   - After `resetFrames` consecutive misses, resets fully to `.searching`.
final class HandDirectionTracker {

    // MARK: - Tuning constants

    /// Minimum windowed velocity (normalized units/second) to classify as moving.
    static let velocityThreshold: CGFloat = 0.10
    /// Minimum net displacement across the window to reject micro-jitter.
    static let displacementThreshold: CGFloat = 0.010
    /// Consecutive agreeing frames before committing a new active direction.
    static let commitFrames = 2
    /// Missed frames before dropping the held direction to `.idle`.
    static let holdFrames = 3
    /// Missed frames before resetting fully to `.searching`.
    static let resetFrames = 8
    /// Rolling window size for velocity estimation.
    static let historyCapacity = 4

    // MARK: - Direction

    enum Direction: Equatable {
        /// Hand moving in the positive-X (rightward) direction in unmirrored camera space.
        /// MacCaptureEngine normalizes this camera-space direction into semantic
        /// record-motion forward/backward cues for capture and notation.
        case movingForward
        /// Hand moving in the negative-X (leftward) direction in unmirrored camera space.
        case movingBackward
        /// Hand visible but below motion threshold.
        case idle
        /// Hand not seen for an extended period; coach should prompt user.
        case searching
    }

    // MARK: - Idle reason diagnostics (read-only, set by computeRawDirection)

    enum IdleReason: String {
        case insufficientHistory     // history.count < 2
        case displacementTooSmall    // abs(netDisplacement) < threshold
        case velocityTooLow          // abs(velocity) <= threshold
        case none                    // direction is movingForward/movingBackward
    }

    private(set) var lastIdleReason: IdleReason = .none
    private(set) var lastNetDisplacement: CGFloat = 0
    private(set) var lastWeightedVelocity: CGFloat = 0
    /// History count at the time computeRawDirection last ran.
    private(set) var lastHistoryCount: Int = 0

    // MARK: - Commit-latency diagnostics (read-only accumulators)

    /// Times a raw moving-forward or moving-backward direction first appeared
    /// (pending reset from a non-moving direction to either moving direction).
    private(set) var rawDirectionAppearedMoving = 0
    /// Times committed direction successfully changed to a moving direction.
    private(set) var committedDirectionChanges = 0
    /// Times a moving pending direction was abandoned before commitFrames was
    /// reached (raw flipped to idle or the opposite direction before commit).
    private(set) var pendingRawDirectionResetBeforeCommit = 0
    /// Committed a moving direction after 1 consecutive raw observation.
    private(set) var commitLatency1 = 0
    /// Committed a moving direction after 2 consecutive raw observations.
    private(set) var commitLatency2 = 0
    /// Committed a moving direction after 3+ consecutive raw observations.
    private(set) var commitLatency3Plus = 0

    // MARK: - Displacement/velocity distribution diagnostics (read-only accumulators)

    private(set) var displacementAbsMin: CGFloat = .infinity
    private(set) var displacementAbsMax: CGFloat = 0
    private(set) var velocityAbsMin: CGFloat = .infinity
    private(set) var velocityAbsMax: CGFloat = 0
    private(set) var dispBucketBelow002 = 0
    private(set) var dispBucket002to005 = 0
    private(set) var dispBucket005to010 = 0
    private(set) var dispBucket010to020 = 0
    private(set) var dispBucketAbove020 = 0
    private(set) var velBucketBelow003 = 0
    private(set) var velBucket003to006 = 0
    private(set) var velBucket006to010 = 0
    private(set) var velBucket010to020 = 0
    private(set) var velBucketAbove020 = 0
    private(set) var historyCount1 = 0
    private(set) var historyCount2 = 0
    private(set) var historyCount3 = 0
    private(set) var historyCount4 = 0
    private(set) var trackedPointXMin: CGFloat = .infinity
    private(set) var trackedPointXMax: CGFloat = 0
    private(set) var trackedPointYMin: CGFloat = .infinity
    private(set) var trackedPointYMax: CGFloat = 0

    // MARK: - State

    private struct Sample {
        let position: CGPoint
        let time: CFTimeInterval
    }

    private var history: [Sample] = []
    private var committed: Direction = .idle
    private var pending: Direction = .idle
    private var pendingCount = 0
    private(set) var missedCount = 0

    // MARK: - Published state

    private(set) var direction: Direction = .idle

    /// Fraction in [0, 1] indicating how confidently the current direction is held.
    var confidence: Double {
        switch direction {
        case .movingForward, .movingBackward:
            guard pending == direction else { return 0.5 }
            return min(1.0, Double(pendingCount) / Double(max(1, Self.commitFrames)))
        default:
            return 0
        }
    }

    // MARK: - Public API

    /// Process a successful hand observation.
    ///
    /// - Parameters:
    ///   - rawPoint: The unsmoothed Vision hand point in normalized image coordinates.
    ///   - time: `CACurrentMediaTime()` at the time of the observation.
    /// - Returns: The direction to display immediately.
    @discardableResult
    func recordObservation(rawPoint: CGPoint, at time: CFTimeInterval) -> Direction {
        ScratchLabPerformanceSignpost.event("HandDirectionAnalyze")
        trackedPointXMin = min(trackedPointXMin, rawPoint.x)
        trackedPointXMax = max(trackedPointXMax, rawPoint.x)
        trackedPointYMin = min(trackedPointYMin, rawPoint.y)
        trackedPointYMax = max(trackedPointYMax, rawPoint.y)
        missedCount = 0
        history.append(Sample(position: rawPoint, time: time))
        if history.count > Self.historyCapacity {
            history.removeFirst()
        }
        let raw = computeRawDirection()
        updateCommitted(with: raw)
        direction = committed
        return direction
    }

    /// Process a missed frame (no hand observation returned).
    ///
    /// - Returns: The direction to display, including hold behaviour.
    @discardableResult
    func recordMiss() -> Direction {
        missedCount += 1

        if missedCount >= Self.resetFrames {
            reset()
            direction = .searching
            return .searching
        }

        if missedCount <= Self.holdFrames {
            // Keep the last committed direction while the hand briefly disappears.
            direction = committed
            return direction
        }

        // Between holdFrames and resetFrames: drop to idle but keep position.
        direction = .idle
        return .idle
    }

    /// Hard-reset all state. Call when the session restarts or the user resets calibration.
    func reset() {
        history.removeAll()
        committed = .idle
        pending = .idle
        pendingCount = 0
        missedCount = 0
        direction = .idle
        // Reset diagnostic accumulators
        lastIdleReason = .none
        lastNetDisplacement = 0
        lastWeightedVelocity = 0
        lastHistoryCount = 0
        rawDirectionAppearedMoving = 0
        committedDirectionChanges = 0
        pendingRawDirectionResetBeforeCommit = 0
        commitLatency1 = 0
        commitLatency2 = 0
        commitLatency3Plus = 0
        displacementAbsMin = .infinity
        displacementAbsMax = 0
        velocityAbsMin = .infinity
        velocityAbsMax = 0
        dispBucketBelow002 = 0
        dispBucket002to005 = 0
        dispBucket005to010 = 0
        dispBucket010to020 = 0
        dispBucketAbove020 = 0
        velBucketBelow003 = 0
        velBucket003to006 = 0
        velBucket006to010 = 0
        velBucket010to020 = 0
        velBucketAbove020 = 0
        historyCount1 = 0
        historyCount2 = 0
        historyCount3 = 0
        historyCount4 = 0
        trackedPointXMin = .infinity
        trackedPointXMax = 0
        trackedPointYMin = .infinity
        trackedPointYMax = 0
    }

    // MARK: - Private

    private func computeRawDirection() -> Direction {
        lastHistoryCount = history.count
        // History count distribution
        switch history.count {
        case 1: historyCount1 += 1
        case 2: historyCount2 += 1
        case 3: historyCount3 += 1
        default: historyCount4 += 1
        }
        guard history.count >= 2 else {
            lastIdleReason = .insufficientHistory
            lastNetDisplacement = 0
            lastWeightedVelocity = 0
            return .idle
        }

        // Compute a recency-weighted mean of consecutive-pair velocities.
        // This correctly handles direction reversals and doesn't drift on jitter.
        var weightedVelocity: CGFloat = 0
        var totalWeight: CGFloat = 0

        for i in 1..<history.count {
            let dt = max(history[i].time - history[i - 1].time, 0.001)
            let dx = history[i].position.x - history[i - 1].position.x
            let stepVelocity = dx / CGFloat(dt)
            let weight = CGFloat(i)  // more recent pairs get higher weight
            weightedVelocity += stepVelocity * weight
            totalWeight += weight
        }

        let netDisplacement = history[history.count - 1].position.x - history[0].position.x
        lastNetDisplacement = netDisplacement
        let velocity = weightedVelocity / totalWeight
        lastWeightedVelocity = velocity

        // Accumulate displacement distribution
        let absDisp = abs(netDisplacement)
        if absDisp < .infinity { displacementAbsMin = min(displacementAbsMin, absDisp) }
        displacementAbsMax = max(displacementAbsMax, absDisp)
        if absDisp < 0.002        { dispBucketBelow002 += 1 }
        else if absDisp < 0.005   { dispBucket002to005 += 1 }
        else if absDisp < 0.010   { dispBucket005to010 += 1 }
        else if absDisp < 0.020   { dispBucket010to020 += 1 }
        else                       { dispBucketAbove020 += 1 }

        // Accumulate velocity distribution
        let absVel = abs(velocity)
        if absVel < .infinity { velocityAbsMin = min(velocityAbsMin, absVel) }
        velocityAbsMax = max(velocityAbsMax, absVel)
        if absVel < 0.03          { velBucketBelow003 += 1 }
        else if absVel < 0.06     { velBucket003to006 += 1 }
        else if absVel < 0.10     { velBucket006to010 += 1 }
        else if absVel < 0.20     { velBucket010to020 += 1 }
        else                       { velBucketAbove020 += 1 }

        guard totalWeight > 0, absDisp >= Self.displacementThreshold else {
            lastIdleReason = .displacementTooSmall
            return .idle
        }

        if velocity > Self.velocityThreshold {
            lastIdleReason = .none
            return .movingForward
        } else if velocity < -Self.velocityThreshold {
            lastIdleReason = .none
            return .movingBackward
        }
        lastIdleReason = .velocityTooLow
        return .idle
    }

    private func updateCommitted(with raw: Direction) {
        let wasPendingMoving = (pending == .movingForward || pending == .movingBackward)

        if raw == pending {
            pendingCount += 1
        } else {
            // Pending direction reset — if the old pending was a moving direction
            // that never reached commitFrames, it was abandoned before commit.
            if wasPendingMoving && pendingCount < Self.commitFrames && committed != pending {
                pendingRawDirectionResetBeforeCommit += 1
            }
            pending = raw
            pendingCount = 1
        }

        switch raw {
        case .idle:
            // Idle commits immediately — stops showing stale direction.
            committed = .idle
        case .movingForward, .movingBackward:
            // Count new raw-direction appearances (pending just reset to this
            // moving direction with count 1 and wasn't already committed).
            if pendingCount == 1 {
                rawDirectionAppearedMoving += 1
            }
            if pendingCount >= Self.commitFrames {
                if committed != raw {
                    committedDirectionChanges += 1
                }
                committed = raw
            }
        case .searching:
            committed = .searching
        }

        // Record commit latency when a moving direction is first committed.
        // Tracked on the call where pendingCount reaches commitFrames AND
        // committed just changed to this raw direction. This avoids counting
        // sustained commits where pendingCount keeps growing.
        if raw == pending, (raw == .movingForward || raw == .movingBackward),
           pendingCount == Self.commitFrames {
            switch pendingCount {
            case 1:  commitLatency1 += 1
            case 2:  commitLatency2 += 1
            default: commitLatency3Plus += 1
            }
        }
    }
}
