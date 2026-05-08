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
    }

    // MARK: - Private

    private func computeRawDirection() -> Direction {
        guard history.count >= 2 else { return .idle }

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
        guard totalWeight > 0, abs(netDisplacement) >= Self.displacementThreshold else {
            return .idle
        }

        let velocity = weightedVelocity / totalWeight

        if velocity > Self.velocityThreshold {
            return .movingForward
        } else if velocity < -Self.velocityThreshold {
            return .movingBackward
        }
        return .idle
    }

    private func updateCommitted(with raw: Direction) {
        if raw == pending {
            pendingCount += 1
        } else {
            pending = raw
            pendingCount = 1
        }

        switch raw {
        case .idle:
            // Idle commits immediately — stops showing stale direction.
            committed = .idle
        case .movingForward, .movingBackward:
            if pendingCount >= Self.commitFrames {
                committed = raw
            }
        case .searching:
            committed = .searching
        }
    }
}
