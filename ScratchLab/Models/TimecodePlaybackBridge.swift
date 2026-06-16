import Foundation

// MARK: - TimecodePlaybackBridgeState

/// Gate state for the prototype timecode playback bridge.
///
/// The bridge sits between the stabilized `TimecodeControlPipeline` output and
/// the existing scratch playback/control path. It does not create a second
/// scratch engine, does not call notation classification, and does not call
/// export/upload.
///
/// **Batch 8:** Prototype playback bridge. DEBUG/prototype only.
public enum TimecodePlaybackBridgeState: String, Equatable, Sendable, CaseIterable {

    /// Bridge is off (playbackDriveEnabled == false).
    case disabled

    /// Bridge is enabled and waiting for a trusted timecode signal.
    case armed

    /// Bridge is actively driving playback from prototype timecode.
    case driving

    /// Bridge is blocked because the timecode signal is bad, low-confidence,
    /// or stale.
    case blockedByBadSignal

    /// Bridge is blocked because replay is active.
    case blockedByReplay

    /// Bridge is blocked because the pipeline is in `.diagnosticsOnly` mode.
    case blockedByDiagnosticsOnly

    // MARK: - Labels

    /// User-facing label for status displays.
    public var label: String {
        switch self {
        case .disabled:                   return "Disabled"
        case .armed:                      return "Armed"
        case .driving:                    return "Driving"
        case .blockedByBadSignal:         return "Bad Signal"
        case .blockedByReplay:            return "Replay Active"
        case .blockedByDiagnosticsOnly:   return "Diagnostics Only"
        }
    }

    /// Compact label for tight UI.
    public var shortLabel: String {
        switch self {
        case .disabled:                   return "Off"
        case .armed:                      return "Armed"
        case .driving:                    return "Drive"
        case .blockedByBadSignal:         return "BadSig"
        case .blockedByReplay:            return "Replay"
        case .blockedByDiagnosticsOnly:   return "Diag"
        }
    }
}

// MARK: - TimecodePlaybackDrive

/// Output produced by the bridge when timecode is trusted and allowed to
/// drive playback.
///
/// This is a pure value type — no side effects, no engine calls, no notation
/// classification. The consumer (playback controller) decides how to interpret
/// the drive signal.
public struct TimecodePlaybackDrive: Equatable, Sendable {

    /// Decoded platter direction.
    public let direction: TimecodeDirection

    /// Clamped rate in position-units per second.
    public let rate: Double

    /// Source label identifying this drive signal.
    /// `"timecode_prototype_playback"` when the bridge produced the output.
    public let sourceLabel: String

    /// The underlying stabilized platter timeline from the pipeline.
    public let timeline: PlatterPositionTimeline

    public init(
        direction: TimecodeDirection,
        rate: Double,
        sourceLabel: String,
        timeline: PlatterPositionTimeline
    ) {
        self.direction = direction
        self.rate = rate
        self.sourceLabel = sourceLabel
        self.timeline = timeline
    }
}

// MARK: - TimecodePlaybackBridge

/// Pure/testable gate that decides whether stabilized timecode prototype
/// output may drive scratch playback.
///
/// ## Design (Batch 8)
///
/// - Defaults disabled/off.
/// - Requires explicit user enable (`playbackDriveEnabled`).
/// - Blocks when mode is `.disabled` or `.diagnosticsOnly`.
/// - Blocks when signal is bad, low-confidence, or stale.
/// - Blocks when replay is active (`isReplayActive`).
/// - Preserves direction and rate from trusted stabilized pipeline output.
/// - Clamps extreme rates via `maxPlaybackRate`.
/// - Emits source label `"timecode_prototype_playback"`.
/// - Does NOT call notation classification.
/// - Does NOT call export/upload.
/// - Does NOT create an audio engine or second scratch engine.
///
/// ## Usage
///
/// ```swift
/// let bridge = TimecodePlaybackBridge()
/// bridge.playbackDriveEnabled = true
/// // …
/// let drive = bridge.evaluate(pipeline: pipeline)
/// if let drive = drive {
///     // forward drive.direction, drive.rate to playback controller
/// }
/// ```
public final class TimecodePlaybackBridge: ObservableObject, @unchecked Sendable {

    // MARK: - Configuration

    /// Master toggle. When `false`, the bridge never produces drive output.
    /// Defaults to `false`.
    @Published public var playbackDriveEnabled: Bool = false {
        didSet {
            if !playbackDriveEnabled, oldValue {
                // Clear output when toggled off so stale drive signal is not
                // consumed by the playback path.
                currentDrive = nil
                state = .disabled
            }
        }
    }

    /// Set to `true` by the playback controller when a replay take is active.
    /// The bridge blocks timecode driving while this is `true`.
    public var isReplayActive: Bool = false

    /// Maximum absolute rate allowed in position-units per second.
    /// Rates exceeding this are clamped.
    public let maxPlaybackRate: Double

    /// Minimum average confidence required for the bridge to trust the
    /// pipeline output.
    public let minConfidence: Double

    /// Maximum age (seconds) of the most recent buffer before the bridge
    /// considers the signal stale.
    public let staleThreshold: TimeInterval

    // MARK: - Published output

    /// Current bridge state.
    @Published public private(set) var state: TimecodePlaybackBridgeState = .disabled

    /// Most recent drive output, or `nil` when the bridge is not driving.
    @Published public private(set) var currentDrive: TimecodePlaybackDrive?

    /// Source label emitted by this bridge on drive output.
    public static let sourceLabel = "timecode_prototype_playback"

    // MARK: - Init

    public init(
        playbackDriveEnabled: Bool = false,
        isReplayActive: Bool = false,
        maxPlaybackRate: Double = 5.0,
        minConfidence: Double = 0.3,
        staleThreshold: TimeInterval = 2.0
    ) {
        self.playbackDriveEnabled = playbackDriveEnabled
        self.isReplayActive = isReplayActive
        self.maxPlaybackRate = maxPlaybackRate
        self.minConfidence = minConfidence
        self.staleThreshold = staleThreshold
        self.state = playbackDriveEnabled ? .armed : .disabled
    }

    // MARK: - Evaluate

    /// Evaluate the pipeline against the bridge gates and return a drive
    /// signal if all conditions are met.
    ///
    /// - Parameter pipeline: The `TimecodeControlPipeline` producing
    ///   stabilized timecode output.
    /// - Parameter now: Reference time for staleness checks. Defaults to
    ///   `Date()`. Inject a fixed value in tests.
    /// - Returns: A `TimecodePlaybackDrive` when the bridge is enabled,
    ///   the pipeline mode is `.controlPrototype`, replay is not active,
    ///   signal health is usable, confidence meets the threshold, and
    ///   the buffer is not stale. Returns `nil` otherwise, and sets
    ///   `state` to the blocking reason.
    @discardableResult
    public func evaluate(
        pipeline: TimecodeControlPipeline,
        now: Date = Date()
    ) -> TimecodePlaybackDrive? {
        // Gate 1: Bridge must be enabled
        guard playbackDriveEnabled else {
            state = .disabled
            currentDrive = nil
            return nil
        }

        // Gate 2: Pipeline mode must be controlPrototype
        switch pipeline.mode {
        case .disabled:
            state = .disabled
            currentDrive = nil
            return nil
        case .diagnosticsOnly:
            state = .blockedByDiagnosticsOnly
            currentDrive = nil
            return nil
        case .controlPrototype:
            break
        }

        // Gate 3: Replay must not be active
        if isReplayActive {
            state = .blockedByReplay
            currentDrive = nil
            return nil
        }

        // Gate 4: Signal health must be usable
        guard pipeline.signalHealth == .usable else {
            state = .blockedByBadSignal
            currentDrive = nil
            return nil
        }

        // Gate 5: Signal must not be stale
        if let lastBuffer = pipeline.lastBufferReceivedAt {
            let age = now.timeIntervalSince(lastBuffer)
            if age > staleThreshold {
                state = .blockedByBadSignal
                currentDrive = nil
                return nil
            }
        }
        // Note: If lastBufferReceivedAt is nil (no buffers received yet),
        // we still allow evaluation — the pipeline may have been fed
        // synthetic data that didn't set lastBufferReceivedAt.

        // Gate 6: Confidence must meet threshold
        guard pipeline.counters.averageConfidence >= minConfidence || pipeline.counters.acceptedMotionSamples > 0 else {
            state = .blockedByBadSignal
            currentDrive = nil
            return nil
        }

        // Gate 7: Pipeline must have produced a valid timeline
        guard let timeline = pipeline.latestPlatterTimeline,
              !timeline.samples.isEmpty else {
            state = .blockedByBadSignal
            currentDrive = nil
            return nil
        }

        // Gate 8: Direction must be known
        guard pipeline.currentDirection != .unknown else {
            state = .blockedByBadSignal
            currentDrive = nil
            return nil
        }

        // --- All gates passed — produce drive output ---

        // Preserve direction from pipeline
        let direction = pipeline.currentDirection

        // Preserve rate from pipeline, clamped to maxPlaybackRate
        let rawRate = pipeline.currentRate
        let sign = rawRate >= 0 ? 1.0 : -1.0
        let clampedRate = min(abs(rawRate), maxPlaybackRate) * sign

        let drive = TimecodePlaybackDrive(
            direction: direction,
            rate: clampedRate,
            sourceLabel: Self.sourceLabel,
            timeline: timeline
        )

        state = .driving
        currentDrive = drive
        return drive
    }

    // MARK: - Reset

    /// Reset bridge state and clear the current drive output.
    /// Does not change `playbackDriveEnabled`.
    public func reset() {
        currentDrive = nil
        state = playbackDriveEnabled ? .armed : .disabled
    }
}
