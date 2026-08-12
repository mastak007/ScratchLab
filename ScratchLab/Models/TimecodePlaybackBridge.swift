import Foundation
import QuartzCore

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

    /// Bridge is blocked because the live audio tap is not enabled.
    case blockedByLiveTapOff

    /// Bridge is blocked because validation has not passed and the user
    /// has not explicitly overridden the validation requirement.
    case blockedByValidationRequired

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
        case .blockedByLiveTapOff:        return "Live Tap Off"
        case .blockedByValidationRequired: return "Validation Required"
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
        case .blockedByLiveTapOff:        return "TapOff"
        case .blockedByValidationRequired: return "NoVal"
        }
    }
}

/// Exact result of the most recent bridge evaluation.
///
/// `blockedByBadSignal` intentionally groups several fail-closed conditions
/// for the compact status UI. This value preserves the individual gate so
/// hardware debugging does not depend on ephemeral Xcode console output.
public enum TimecodePlaybackBridgeDecision: String, Equatable, Hashable, Sendable {
    case notEvaluated
    case disabled
    case pipelineDisabled
    case diagnosticsOnly
    case replayActive
    case liveTapOff
    case unusableSignalHealth
    case staleSignal
    case lowConfidence
    case missingTimeline
    case unknownDirection
    case validationRequired
    case driving

    public var label: String {
        switch self {
        case .notEvaluated:         return "Not evaluated yet"
        case .disabled:             return "Playback bridge disabled"
        case .pipelineDisabled:     return "Timecode pipeline disabled"
        case .diagnosticsOnly:      return "Diagnostics-only mode"
        case .replayActive:         return "Replay is active"
        case .liveTapOff:           return "Live timecode tap is off"
        case .unusableSignalHealth: return "Signal health is not usable"
        case .staleSignal:          return "Latest input buffer is stale"
        case .lowConfidence:        return "Confidence is below bridge minimum"
        case .missingTimeline:      return "No trusted platter timeline"
        case .unknownDirection:     return "Platter direction is unknown"
        case .validationRequired:   return "Validation has not passed"
        case .driving:              return "All gates passed"
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

    /// `evaluate` runs on the dedicated DVS control queue while SwiftUI reads
    /// diagnostics — and mutates gate configuration (`playbackDriveEnabled`,
    /// `validationOverride`, `isReplayActive`, `validationRequired`) — on the
    /// main thread. Keep the complete output transaction, every public output
    /// read, and every gate-input value `evaluate` consults behind one
    /// recursive lock. Recursive locking is required because evaluation
    /// captures/publishes snapshots through the same locked computed
    /// properties.
    private let outputLock = NSRecursiveLock()
    private var storedState: TimecodePlaybackBridgeState = .disabled
    private var storedCurrentDrive: TimecodePlaybackDrive?
    private var storedLastDecision: TimecodePlaybackBridgeDecision = .notEvaluated
    private var storedDecisionCounts: [TimecodePlaybackBridgeDecision: Int] = [:]

    /// Lock-protected mirror of `playbackDriveEnabled`, kept current by that
    /// property's `didSet`. `evaluate` reads this instead of the raw
    /// `@Published` storage, which SwiftUI can mutate on the main thread
    /// concurrently with evaluation on the DVS control queue.
    private var storedPlaybackDriveEnabled: Bool = false
    /// Lock-protected mirror of `validationOverride`, kept current by that
    /// property's `didSet`, for the same reason as `storedPlaybackDriveEnabled`.
    private var storedValidationOverride: Bool = false
    /// Lock-protected backing storage for `isReplayActive`.
    private var storedIsReplayActive: Bool = false
    /// Lock-protected backing storage for `validationRequired`.
    private var storedValidationRequired: Bool = true

    // MARK: - Configuration

    /// Master toggle. When `false`, the bridge never produces drive output.
    /// Defaults to `false`.
    @Published public var playbackDriveEnabled: Bool = false {
        didSet {
            outputLock.lock()
            storedPlaybackDriveEnabled = playbackDriveEnabled
            outputLock.unlock()
            if !playbackDriveEnabled, oldValue {
                outputLock.lock()
                defer { outputLock.unlock() }
                // Clear output when toggled off so stale drive signal is not
                // consumed by the playback path.
                currentDrive = nil
                state = .disabled
                lastDecision = .disabled
            }
        }
    }

    /// Set to `true` by the playback controller when a replay take is active.
    /// The bridge blocks timecode driving while this is `true`.
    public var isReplayActive: Bool {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedIsReplayActive
        }
        set {
            outputLock.lock()
            storedIsReplayActive = newValue
            outputLock.unlock()
        }
    }

    /// When `true`, the user has explicitly overridden the validation
    /// requirement gate. This allows playback to drive even when the
    /// prototype validation status is not `.usablePrototypeControl`.
    ///
    /// Defaults to `false`. Must be explicitly toggled by the user after
    /// confirming they understand the risks.
    @Published public var validationOverride: Bool = false {
        didSet {
            outputLock.lock()
            storedValidationOverride = validationOverride
            outputLock.unlock()
        }
    }

    /// When `true`, the bridge requires `validationStatus == .usablePrototypeControl`
    /// before allowing playback. Set by the active profile.
    ///
    /// Defaults to `true` — validation is required unless the profile
    /// explicitly sets it to `false` (e.g., manual mode).
    public var validationRequired: Bool {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedValidationRequired
        }
        set {
            outputLock.lock()
            storedValidationRequired = newValue
            outputLock.unlock()
        }
    }

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
    public private(set) var state: TimecodePlaybackBridgeState {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedState
        }
        set {
            outputLock.lock()
            storedState = newValue
            outputLock.unlock()
        }
    }

    /// Most recent drive output, or `nil` when the bridge is not driving.
    public private(set) var currentDrive: TimecodePlaybackDrive? {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedCurrentDrive
        }
        set {
            outputLock.lock()
            storedCurrentDrive = newValue
            outputLock.unlock()
        }
    }

    /// Exact outcome of the most recent gate evaluation.
    public private(set) var lastDecision: TimecodePlaybackBridgeDecision {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedLastDecision
        }
        set {
            outputLock.lock()
            storedLastDecision = newValue
            outputLock.unlock()
        }
    }

    /// Session counts for every evaluated decision, retained so a transient
    /// reversal-time block remains visible after the platter stops.
    public private(set) var decisionCounts: [TimecodePlaybackBridgeDecision: Int] {
        get {
            outputLock.lock()
            defer { outputLock.unlock() }
            return storedDecisionCounts
        }
        set {
            outputLock.lock()
            storedDecisionCounts = newValue
            outputLock.unlock()
        }
    }

    /// Compact hardware-debug summary of the gates that can interrupt motion.
    public var blockingDecisionSummary: String {
        outputLock.lock()
        defer { outputLock.unlock() }
        return "health \(storedDecisionCounts[.unusableSignalHealth, default: 0]) · " +
        "stale \(storedDecisionCounts[.staleSignal, default: 0]) · " +
        "confidence \(storedDecisionCounts[.lowConfidence, default: 0]) · " +
        "timeline \(storedDecisionCounts[.missingTimeline, default: 0]) · " +
        "direction \(storedDecisionCounts[.unknownDirection, default: 0])"
    }

    /// Source label emitted by this bridge on drive output.
    public static let sourceLabel = "timecode_prototype_playback"

    // MARK: - Init

    /// `notificationClock` backs `evaluate(pipeline:)`'s flush-notification
    /// coalescing (see its doc comment) — injectable so tests can pin
    /// elapsed time deterministically instead of depending on how long a
    /// test's own synthetic decode work happens to take on the machine
    /// running it. Defaults to the real monotonic clock for production use.
    public init(
        playbackDriveEnabled: Bool = false,
        isReplayActive: Bool = false,
        validationRequired: Bool = true,
        validationOverride: Bool = false,
        maxPlaybackRate: Double = 5.0,
        minConfidence: Double = 0.3,
        staleThreshold: TimeInterval = 2.0,
        notificationClock: @escaping () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.maxPlaybackRate = maxPlaybackRate
        self.minConfidence = minConfidence
        self.staleThreshold = staleThreshold
        self.notificationClock = notificationClock
        // Explicitly seed every lock-protected shadow from the initializer
        // argument directly, rather than relying on didSet firing during
        // init. `evaluate` reads only these shadows, so a bridge constructed
        // with e.g. playbackDriveEnabled: true must see that value on its
        // very first evaluation regardless of property-observer timing.
        storedPlaybackDriveEnabled = playbackDriveEnabled
        storedIsReplayActive = isReplayActive
        storedValidationRequired = validationRequired
        storedValidationOverride = validationOverride
        self.playbackDriveEnabled = playbackDriveEnabled
        self.isReplayActive = isReplayActive
        self.validationRequired = validationRequired
        self.validationOverride = validationOverride
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
        outputLock.lock()
        defer { outputLock.unlock() }
        let previousOutput = observableOutputSnapshot
        defer { publishOutputChange(ifDifferentFrom: previousOutput, coalesced: true) }

        // Gate 1: Bridge must be enabled
        // Reads the lock-protected shadow, not the raw @Published storage,
        // since SwiftUI can set playbackDriveEnabled from the main thread
        // concurrently with this evaluation on the DVS control queue.
        guard storedPlaybackDriveEnabled else {
            state = .disabled
            recordDecision(.disabled)
            currentDrive = nil
            return nil
        }

        // Gate 2: Pipeline mode must be controlPrototype
        switch pipeline.mode {
        case .disabled:
            state = .disabled
            recordDecision(.pipelineDisabled)
            currentDrive = nil
            return nil
        case .diagnosticsOnly:
            state = .blockedByDiagnosticsOnly
            recordDecision(.diagnosticsOnly)
            currentDrive = nil
            return nil
        case .controlPrototype:
            break
        }

        // Gate 3: Replay must not be active
        if storedIsReplayActive {
            state = .blockedByReplay
            recordDecision(.replayActive)
            currentDrive = nil
            return nil
        }

        // Gate 4: Live tap must be enabled
        guard pipeline.liveTapEnabled else {
            state = .blockedByLiveTapOff
            recordDecision(.liveTapOff)
            currentDrive = nil
            return nil
        }

        // Gate 5: Signal health must be usable
        guard pipeline.signalHealth == .usable else {
            state = .blockedByBadSignal
            recordDecision(.unusableSignalHealth)
            currentDrive = nil
            return nil
        }

        // Gate 6: Signal must not be stale
        if let lastBuffer = pipeline.lastBufferReceivedAt {
            let age = now.timeIntervalSince(lastBuffer)
            if age > staleThreshold {
                state = .blockedByBadSignal
                recordDecision(.staleSignal)
                currentDrive = nil
                return nil
            }
        }
        // Note: If lastBufferReceivedAt is nil (no buffers received yet),
        // we still allow evaluation — the pipeline may have been fed
        // synthetic data that didn't set lastBufferReceivedAt.

        // Gate 7: Confidence must meet threshold
        guard pipeline.counters.averageConfidence >= minConfidence || pipeline.counters.acceptedMotionSamples > 0 else {
            state = .blockedByBadSignal
            recordDecision(.lowConfidence)
            currentDrive = nil
            return nil
        }

        // Gate 8: Pipeline must have produced a valid timeline
        guard let timeline = pipeline.latestPlatterTimeline,
              !timeline.samples.isEmpty else {
            state = .blockedByBadSignal
            recordDecision(.missingTimeline)
            currentDrive = nil
            return nil
        }

        // Gate 9: Direction must be known
        guard pipeline.currentDirection != .unknown else {
            state = .blockedByBadSignal
            recordDecision(.unknownDirection)
            currentDrive = nil
            return nil
        }

        // Gate 10: Validation status must be usable (or user overrides)
        if storedValidationRequired {
            let snap = pipeline.makeValidationSnapshot(now: now)
            let statusOK = snap.validationStatus == .usablePrototypeControl
            if !statusOK && !storedValidationOverride {
                state = .blockedByValidationRequired
                recordDecision(.validationRequired)
                currentDrive = nil
                return nil
            }
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
        recordDecision(.driving)
        currentDrive = drive
        return drive
    }

    // MARK: - Reset

    /// Reset bridge state and clear the current drive output.
    /// Does not change `playbackDriveEnabled`.
    /// Resets `validationOverride` to `false` for safety.
    public func reset() {
        outputLock.lock()
        defer { outputLock.unlock() }
        let previousOutput = observableOutputSnapshot
        defer { publishOutputChange(ifDifferentFrom: previousOutput) }

        currentDrive = nil
        validationOverride = false
        state = storedPlaybackDriveEnabled ? .armed : .disabled
        lastDecision = storedPlaybackDriveEnabled ? .notEvaluated : .disabled
        decisionCounts.removeAll(keepingCapacity: true)
    }

    private struct ObservableOutputSnapshot: Equatable {
        let state: TimecodePlaybackBridgeState
        let currentDrive: TimecodePlaybackDrive?
        let lastDecision: TimecodePlaybackBridgeDecision
        let decisionCounts: [TimecodePlaybackBridgeDecision: Int]
    }

    private var observableOutputSnapshot: ObservableOutputSnapshot {
        ObservableOutputSnapshot(
            state: state,
            currentDrive: currentDrive,
            lastDecision: lastDecision,
            decisionCounts: decisionCounts
        )
    }

    /// Real monotonic clock by default; injectable so tests can pin
    /// elapsed time deterministically (see `init`).
    private let notificationClock: () -> TimeInterval

    /// Dedicated to the coalescing state below only — independent of
    /// `outputLock`, and never held while calling anything else on this
    /// type, so it cannot interact with `outputLock`'s existing (and, for
    /// `evaluate()`, deliberately still-held-during-publish — see its
    /// `defer` ordering) locking.
    private let evaluateChangeNotificationLock = NSLock()
    private var lastEvaluateChangeNotificationUptime: TimeInterval = -.infinity
    private var evaluateChangeNotificationFlushScheduled = false

    /// Same coalescing rationale as
    /// `TimecodeControlPipeline.sendCoalescedFlushChangeNotification` (see
    /// its doc comment, including the hardware-confirmed caveat that
    /// coalescing alone did not eliminate the SwiftUI render warning — it
    /// only reduced its frequency): `evaluate(pipeline:)` runs once per
    /// ~60 Hz DVS control tick, `currentDrive` (carrying the full platter
    /// timeline) changes on nearly every tick during motion. The actual
    /// fix is that no SwiftUI view observes this bridge directly anymore —
    /// `MacAnalyzerView` and `TimecodeControlCard` both read it as plain
    /// state and re-render on their own bounded, main-actor-only timers.
    /// `TimecodeControlCard`'s bindings (`playbackDriveEnabled`,
    /// `currentDrive`, `lastDecision`, …) read this bridge's plain,
    /// `outputLock`-protected properties directly, not through this
    /// notification, so DVS playback correctness and latency are
    /// unaffected either way — `MacAnalyzerView.handleTimecodeFlushTick`
    /// still forwards every tick's drive to
    /// `captureEngine.forwardTimecodeDrive` regardless of whether this
    /// notification fires. Only `evaluate()` uses the coalesced path
    /// (`coalesced: true`); `reset()` is a discrete, rare, session-
    /// boundary operation and always notifies immediately.
    private static let evaluateChangeNotificationMinInterval: TimeInterval = 1.0 / 20.0

    /// Bridge gates update state, drive, decision, and counters as one
    /// coherent result. Invalidate observers once after that result is
    /// complete instead of once for every field assignment — and, when
    /// `coalesced` (only `evaluate()` passes `true`), no more than
    /// `evaluateChangeNotificationMinInterval` apart even when every tick
    /// changes something.
    private func publishOutputChange(
        ifDifferentFrom previous: ObservableOutputSnapshot,
        coalesced: Bool = false
    ) {
        guard previous != observableOutputSnapshot else { return }

        guard coalesced else {
            deliverChangeNotification()
            return
        }

        let now = notificationClock()
        evaluateChangeNotificationLock.lock()
        let elapsed = now - lastEvaluateChangeNotificationUptime
        if elapsed >= Self.evaluateChangeNotificationMinInterval {
            lastEvaluateChangeNotificationUptime = now
            evaluateChangeNotificationLock.unlock()
            deliverChangeNotification()
            return
        }
        guard !evaluateChangeNotificationFlushScheduled else {
            evaluateChangeNotificationLock.unlock()
            return
        }
        evaluateChangeNotificationFlushScheduled = true
        let delay = Self.evaluateChangeNotificationMinInterval - elapsed
        evaluateChangeNotificationLock.unlock()

        // One-shot: flushes whatever the latest state is when it fires,
        // so the tail end of a gesture is never left stuck on a
        // throttled-away intermediate value. Not a repeating timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.evaluateChangeNotificationLock.lock()
            self.lastEvaluateChangeNotificationUptime = self.notificationClock()
            self.evaluateChangeNotificationFlushScheduled = false
            self.evaluateChangeNotificationLock.unlock()
            print("[SwiftUIStateGuard] publish · source=TimecodePlaybackBridge.publishOutputChange.tailFlush thread=main time=\(String(format: "%.6f", CACurrentMediaTime()))")
            self.objectWillChange.send()
        }
    }

    // Hardware-verification instrumentation: a unique identity per publish
    // call site, immediately before `objectWillChange.send()` — see
    // `TimecodeControlPipeline.sendChangeNotification`'s matching comment.
    private func deliverChangeNotification() {
        print("[SwiftUIStateGuard] publish · source=TimecodePlaybackBridge.deliverChangeNotification thread=\(Thread.isMainThread ? "main" : "background") time=\(String(format: "%.6f", CACurrentMediaTime()))")
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private func recordDecision(_ decision: TimecodePlaybackBridgeDecision) {
        storedLastDecision = decision
        storedDecisionCounts[decision, default: 0] += 1
    }
}
