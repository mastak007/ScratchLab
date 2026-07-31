import Foundation

// MARK: - TimecodeSignedRateSignalState

/// Explicit signal availability supplied with each signed-rate sample.
///
/// This state is intentionally independent of absolute-position lock. A valid
/// signed rate may contribute direction evidence whether or not any separate
/// position decoder is locked.
public enum TimecodeSignedRateSignalState: Equatable, Sendable {
    case available
    case noSignal
    case unknown
}

// MARK: - TimecodeSignedRateSample

/// One platform-agnostic normalized signed-rate observation.
public struct TimecodeSignedRateSample: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let signedRate: Double
    public let signalState: TimecodeSignedRateSignalState

    public init(
        timestamp: TimeInterval,
        signedRate: Double,
        signalState: TimecodeSignedRateSignalState
    ) {
        self.timestamp = timestamp
        self.signedRate = signedRate
        self.signalState = signalState
    }
}

// MARK: - TimecodeSignedRateExcursionConfiguration

/// Injectable confirmation limits for signed-rate reversal excursions.
public struct TimecodeSignedRateExcursionConfiguration: Equatable, Sendable {
    /// Integrated absolute opposite-direction rate required to commit a
    /// reversal, measured in normalized-rate seconds.
    public var reversalAreaThreshold: Double

    /// Largest elapsed interval that may contribute to an integral. A larger
    /// interval is treated as a discontinuity and starts fresh evidence at the
    /// current sample, preventing a scheduling gap from manufacturing area.
    public var maximumIntegrationGap: TimeInterval

    public init(
        reversalAreaThreshold: Double,
        maximumIntegrationGap: TimeInterval
    ) {
        self.reversalAreaThreshold = reversalAreaThreshold
        self.maximumIntegrationGap = maximumIntegrationGap
    }

    public var isValid: Bool {
        reversalAreaThreshold.isFinite
            && reversalAreaThreshold > 0
            && maximumIntegrationGap.isFinite
            && maximumIntegrationGap > 0
    }
}

// MARK: - TimecodeSignedRateReversal

/// A single confirmed committed-direction change.
public struct TimecodeSignedRateReversal: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let previousDirection: TimecodeDirection
    public let direction: TimecodeDirection

    public init(
        timestamp: TimeInterval,
        previousDirection: TimecodeDirection,
        direction: TimecodeDirection
    ) {
        self.timestamp = timestamp
        self.previousDirection = previousDirection
        self.direction = direction
    }
}

// MARK: - TimecodeSignedRateExcursionResult

/// Deterministic outcome of consuming one observation.
public enum TimecodeSignedRateExcursionResult: Equatable, Sendable {
    case noChange
    case reversal(TimecodeSignedRateReversal)
    case signalUnavailable
    case invalidSample
    case nonMonotonicTimestamp
    case integrationGap
    case invalidConfiguration
}

// MARK: - TimecodeSignedRateExcursionStabilizer

/// Pure signed-rate reversal confirmation state machine.
///
/// Opposite-direction evidence is integrated with the trapezoidal rule over
/// real sample intervals. The committed direction changes only when that
/// excursion reaches the configured area threshold. Position lock, playback,
/// capture, notation, persistence, and UI are deliberately outside this type.
public struct TimecodeSignedRateExcursionStabilizer: Equatable, Sendable {
    public let configuration: TimecodeSignedRateExcursionConfiguration

    public private(set) var committedDirection: TimecodeDirection = .unknown
    public private(set) var pendingDirection: TimecodeDirection = .unknown
    public private(set) var pendingIntegratedArea: Double = 0
    public private(set) var signalState: TimecodeSignedRateSignalState = .unknown

    /// Honest direction for the current observation. A remembered committed
    /// direction is not reported as live motion while signal is unavailable.
    public var reportedDirection: TimecodeDirection {
        signalState == .available ? committedDirection : .unknown
    }

    private var lastTimestamp: TimeInterval?
    private var previousPendingRateMagnitude: Double?

    public init(configuration: TimecodeSignedRateExcursionConfiguration) {
        self.configuration = configuration
    }

    /// Consume one sample and return at most one confirmed reversal.
    public mutating func consume(
        _ sample: TimecodeSignedRateSample
    ) -> TimecodeSignedRateExcursionResult {
        guard configuration.isValid else {
            failClosed()
            return .invalidConfiguration
        }

        guard sample.timestamp.isFinite,
              sample.timestamp >= 0,
              sample.signedRate.isFinite else {
            failClosed()
            return .invalidSample
        }

        guard sample.signalState == .available else {
            signalState = sample.signalState
            clearPendingEvidence()
            lastTimestamp = nil
            return .signalUnavailable
        }

        signalState = .available

        if let lastTimestamp, sample.timestamp <= lastTimestamp {
            clearPendingEvidence()
            self.lastTimestamp = nil
            signalState = .unknown
            return .nonMonotonicTimestamp
        }

        let elapsed = lastTimestamp.map { sample.timestamp - $0 }
        self.lastTimestamp = sample.timestamp
        let observedDirection = direction(for: sample.signedRate)

        if committedDirection == .unknown {
            if observedDirection != .unknown {
                committedDirection = observedDirection
            }
            clearPendingEvidence()
            return .noChange
        }

        if let elapsed, elapsed > configuration.maximumIntegrationGap {
            clearPendingEvidence()
            beginPendingIfOpposite(
                observedDirection: observedDirection,
                rateMagnitude: abs(sample.signedRate)
            )
            return .integrationGap
        }

        guard observedDirection != .unknown else {
            previousPendingRateMagnitude = pendingDirection == .unknown
                ? nil
                : abs(sample.signedRate)
            return .noChange
        }

        guard observedDirection != committedDirection else {
            clearPendingEvidence()
            return .noChange
        }

        let rateMagnitude = abs(sample.signedRate)
        guard pendingDirection == observedDirection else {
            pendingDirection = observedDirection
            pendingIntegratedArea = 0
            previousPendingRateMagnitude = rateMagnitude
            return .noChange
        }

        if let elapsed, let previousPendingRateMagnitude {
            pendingIntegratedArea += 0.5
                * (previousPendingRateMagnitude + rateMagnitude)
                * elapsed
        }
        self.previousPendingRateMagnitude = rateMagnitude

        guard pendingIntegratedArea >= configuration.reversalAreaThreshold else {
            return .noChange
        }

        let previousDirection = committedDirection
        committedDirection = observedDirection
        clearPendingEvidence()
        return .reversal(TimecodeSignedRateReversal(
            timestamp: sample.timestamp,
            previousDirection: previousDirection,
            direction: observedDirection
        ))
    }

    public mutating func reset() {
        committedDirection = .unknown
        signalState = .unknown
        clearPendingEvidence()
        lastTimestamp = nil
    }

    private func direction(for signedRate: Double) -> TimecodeDirection {
        if signedRate > 0 { return .forward }
        if signedRate < 0 { return .backward }
        return .unknown
    }

    private mutating func beginPendingIfOpposite(
        observedDirection: TimecodeDirection,
        rateMagnitude: Double
    ) {
        guard observedDirection != .unknown,
              observedDirection != committedDirection else {
            return
        }
        pendingDirection = observedDirection
        previousPendingRateMagnitude = rateMagnitude
    }

    private mutating func clearPendingEvidence() {
        pendingDirection = .unknown
        pendingIntegratedArea = 0
        previousPendingRateMagnitude = nil
    }

    private mutating func failClosed() {
        signalState = .unknown
        clearPendingEvidence()
        lastTimestamp = nil
    }
}
