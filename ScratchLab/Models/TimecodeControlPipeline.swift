import Foundation
import Combine
import QuartzCore

#if DEBUG

/// DEBUG-only shared trace for correlating a single DVS drive update across all
/// scheduling layers.
///
/// `claimNext()` is called once per tick from MacAnalyzerView (main thread) before
/// `flushDecode()` and `forwardTimecodeDrive()`. All downstream layers read `current`
/// to attach the same sequence number to their log lines.
public enum DVSTrace {
    private static let lock = NSLock()
    private static var _next: Int = 0
    public private(set) static var current: Int = 0
    public static let isEnabled =
        ProcessInfo.processInfo.environment["SCRATCHLAB_DVS_TRACE"] == "1"

    @discardableResult
    public static func claimNext() -> Int {
        guard isEnabled else { return 0 }
        lock.lock()
        _next += 1
        let seq = _next
        lock.unlock()
        current = seq
        return seq
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(message())
    }
}

#endif

/// Thread-safe point-in-time evidence for the non-publishing live-audio
/// ingress. The realtime callback updates these counters without touching
/// SwiftUI-observed state; the main-thread decode flush publishes UI state.
public struct TimecodeLiveIngressDiagnostics: Equatable, Sendable {
    public let totalReceived: Int
    public let totalDroppedForLatency: Int
    public let pendingBuffers: Int
    public let pendingFrames: Int
    public let latestReceivedAt: Date?
}

// MARK: - TimecodeControlCounters

/// Debug counters accumulated by the TimecodeControlPipeline during live
/// (or synthetic) operation.
///
/// These counters are reset when the pipeline mode changes away from
/// `.controlPrototype` or when `resetCounters()` is called.
///
/// **Batch 3:** Control pipeline only. Does not modify Batch 2 decoder
/// types.
public struct TimecodeControlCounters: Equatable, Sendable {

    /// Aggregate signal health label (raw value from `SignalHealth`).
    public var signalHealth: String = SignalHealth.noSignal.rawValue

    /// Total number of stereo buffers pushed into the pipeline.
    public var totalBuffersReceived: Int = 0

    /// Number of buffers that produced valid decoded samples (before
    /// confidence filtering).
    public var decodedSamples: Int = 0

    /// Number of motion samples that passed confidence filtering and
    /// were included in the output platter timeline.
    public var acceptedMotionSamples: Int = 0

    /// Number of buffers dropped because the input was silent.
    public var droppedSilence: Int = 0

    /// Number of buffers dropped because the input was clipping.
    public var droppedClipped: Int = 0

    /// Number of buffers dropped because of channel imbalance / fault.
    public var droppedChannelFault: Int = 0

    /// Number of buffers dropped because signal was too weak.
    public var droppedWeakSignal: Int = 0

    /// Number of decoded frames dropped because confidence was below
    /// the minimum threshold.
    public var droppedLowConfidence: Int = 0

    /// Number of direction changes detected across the decode window.
    public var directionChanges: Int = 0

    /// Current decoded direction as a string (raw value from
    /// `TimecodeDirection`).
    public var currentDirection: String = TimecodeDirection.unknown.rawValue

    /// Current decoded rate in position-units per second.
    public var currentRate: Double = 0

    /// Average confidence across all decoded frames.
    public var averageConfidence: Double = 0

    /// Human-readable reason for the last dropout. Empty when the last
    /// decode produced valid output.
    public var lastDropReason: String = ""

    /// Source label identifying this pipeline's output
    /// (e.g. `"timecode_live"`).
    public var sourceLabel: String = "timecode_live"

    /// Maximum absolute decoded rate observed during this session.
    public var maxAbsRate: Double = 0

    /// EMA-smoothed rate after the most recent stability filter pass.
    public var smoothedRate: Double = 0

    /// True when the stability filter updated the EMA this flush.
    public var smoothingActive: Bool = false

    /// Total frames rejected by the stability filter as rate spikes or
    /// low-confidence this session.
    public var rejectedSpikeCount: Int = 0

    /// Number of flush windows where the dropout duration was within the
    /// short-hold window (≥ shortDropoutHoldMs, < longDropoutFailMs).
    public var heldDropoutCount: Int = 0

    /// Number of flush windows where the dropout duration exceeded
    /// longDropoutFailMs (filter failed closed and reset EMA state).
    public var longDropoutCount: Int = 0

    /// Human-readable label for the most recent spike or confidence rejection.
    public var lastSpikeReason: String = ""

    /// Duration of the current (or most recently cleared) dropout window in
    /// milliseconds.
    public var lastDropoutDuration: Double = 0

    /// Maximum absolute smoothed rate observed across all decode windows.
    public var maxAbsSmoothedRate: Double = 0

    // MARK: - Acceptance-gate diagnostics (DEBUG investigation aid)
    //
    // These fields make the confidence-acceptance path directly observable:
    // where frames are lost (decoder never forming a frame vs. the stability
    // filter rejecting a formed frame), and what threshold was actually in
    // effect, so a live capture can be checked without guessing.

    /// `pipeline.minConfidence` at the time of the most recent flush.
    public var minConfidenceRuntime: Double = 0

    /// The stability filter's `config.minConfidenceForUpdate` at the time of
    /// the most recent flush. Must equal `minConfidenceRuntime` — if it
    /// doesn't, the UI setting is not reaching the acceptance gate.
    public var stabilityMinConfidenceRuntime: Double = 0

    /// Number of valid (phase-locked) per-buffer confidence samples the
    /// decoder saw in the most recent flush — this is `decodedSamples` for
    /// that flush specifically, before any frame/delta is formed.
    public var decodedFrameCount: Int = 0

    /// Number of frames the decoder actually formed (needs ≥2 valid buffers
    /// in the same flush window) before the stability filter runs.
    public var preFilterFrameCount: Int = 0

    /// Number of frames the stability filter accepted, before the (separate)
    /// `TimecodePlatterAdapter` confidence filter runs.
    public var postFilterFrameCount: Int = 0

    /// Minimum per-buffer confidence in the most recent flush.
    public var frameConfidenceMin: Double = 0

    /// Maximum per-buffer confidence in the most recent flush.
    public var frameConfidenceMax: Double = 0

    /// Of the most recent flush's formed frames, how many had confidence
    /// ≥ `minConfidenceRuntime`.
    public var framesAboveMinConfidence: Int = 0

    /// Of the most recent flush's formed frames, how many had confidence
    /// < `minConfidenceRuntime`.
    public var framesBelowMinConfidence: Int = 0

    /// Cumulative count of frames rejected specifically for low confidence
    /// (subset of the session's total rejected-spike count).
    public var lowConfidenceRejectCount: Int = 0

    /// Cumulative count of frames rejected specifically for an excessive
    /// rate delta (subset of the session's total rejected-spike count).
    public var rateSpikeRejectCount: Int = 0

    /// The rejection reason for the first rejected frame in the most recent
    /// flush (empty if nothing was rejected that flush).
    public var firstRejectReasonThisFlush: String = ""

    // MARK: - Per-frame stage trace (DEBUG investigation aid)
    //
    // The published `currentDirection`/`currentRate` (and the snapshot's
    // "Rate (raw)") are the stability filter's EMA-smoothed output, not the
    // decoder's actual per-buffer decode. There was previously no way to see
    // the decoder's real per-frame direction/velocity before calibration
    // (invert/rate-scale) or before smoothing, which makes it impossible to
    // tell whether a lost/delayed reversal originates in the decoder, the
    // invert step, or the EMA. These two fields expose that directly.

    /// Compact "direction/velocity" trace for every frame the decoder formed
    /// this flush, before calibration (invert/rateScale) or the stability
    /// filter's EMA. Empty when the flush formed no frames.
    public var rawDecodeTrace: String = ""

    /// Same trace after calibration (invert/rateScale applied), still before
    /// the stability filter's EMA. Compares directly against
    /// `rawDecodeTrace` to isolate whether invert/rateScale changed anything
    /// beyond sign/magnitude, and against `smoothedRate`/`currentDirection`
    /// to isolate what the EMA did to it.
    public var calibratedTrace: String = ""

    public init() {}
}

// MARK: - TimecodeControlPipeline

/// Orchestrates the timecode diagnostics → decoder → adapter chain behind
/// an explicit mode gate.
///
/// ## Modes
///
/// - `.disabled`: All input is dropped silently. No diagnostics, no decoder,
///   no platter motion output.
/// - `.diagnosticsOnly`: Runs signal diagnostics and publishes health /
///   counters, but does NOT run the decoder or emit platter motion.
/// - `.controlPrototype`: Runs the full chain — diagnostics, decoder,
///   calibration, platter adapter — and publishes a `PlatterPositionTimeline?`
///   with `.timecodeLive` source for trusted decoded motion. Bad signal
///   fails closed.
///
/// ## Calibration
///
/// Calibration values are `@Published` so a UI can bind directly to them.
/// They are applied on each `flushDecode()` call:
/// - `invertDirection` flips the sign of all position deltas.
/// - `rateScale` multiplies position deltas (and thus velocities) by a
///   configurable factor.
/// - `inputChannel` selects which channel(s) to pass to the decoder.
///   Only `.stereo` produces meaningful phase-delta output.
///
/// ## Usage (tests)
///
/// ```swift
/// let pipeline = TimecodeControlPipeline()
/// pipeline.mode = .controlPrototype
/// for buffer in syntheticBuffers {
///     pipeline.pushStereoBuffer(left: buffer.left, right: buffer.right,
///                               sampleRate: 44100)
/// }
/// pipeline.flushDecode()
/// let timeline = pipeline.latestPlatterTimeline
/// ```
///
/// **Batch 3:** Control pipeline only. Does NOT wire to AVCaptureSession,
/// MacCaptureEngine, HandDirectionTracker, or any recording/notation path.
public final class TimecodeControlPipeline: ObservableObject, @unchecked Sendable {

    // MARK: - Mode

    /// Whether the live audio tap is enabled. Default is `false`.
    /// When false, the callback in MacAnalyzerView short-circuits before
    /// calling `pushStereoBuffer`. Test-feed buttons in the debug host
    /// bypass this gate.
    ///
    /// Backed by `ConfigurationState` (see that section below), not
    /// `@Published` — its getter/setter go through the same
    /// `configurationLock`-guarded atomic snapshot as the other seven
    /// configuration values below, so a pipeline operation that captures
    /// its configuration once at its boundary can never observe this
    /// property mid-write.
    public var liveTapEnabled: Bool {
        get { currentConfigurationSnapshot().liveTapEnabled }
        set { updateConfiguration { $0.liveTapEnabled = newValue } }
    }

    /// Current timecode control mode. Default is `.disabled`.
    ///
    /// Unlike the other seven configuration properties, a mode assignment
    /// does not go through the lightweight `updateConfiguration(_:)` path.
    /// It acquires `processingLock` *first* — before the configuration
    /// value is even written — so the whole transition (write + any
    /// leaving-`.controlPrototype` cleanup) is one operation fully
    /// serialized against `pushStereoBuffer`/`flushDecode`, which now also
    /// capture their `ConfigurationState` snapshot only after acquiring
    /// `processingLock` (see `captureConfigurationForOperation()`'s doc
    /// comment). This closes two ordering bugs a purely memory-race-safe
    /// (but not linearized) design still allowed:
    /// 1. A `pushStereoBuffer`/`flushDecode` operation that captured mode
    ///    while it was still `.controlPrototype`, got delayed, and only
    ///    resumed *after* a concurrent transition to `.disabled` had
    ///    already published the new mode and cleared the accumulator —
    ///    the delayed operation would still append/decode using its stale
    ///    captured mode, leaking audio into a session that was supposed to
    ///    have been cleared.
    /// 2. A mode transition that published its new value *before* waiting
    ///    for `processingLock`, then got delayed before its cleanup ran,
    ///    while a second, later transition (e.g. an immediate re-enable)
    ///    completed in between — the first transition's delayed cleanup
    ///    would then run *after* the second transition and incorrectly
    ///    wipe the new session's already-accumulated data.
    /// Because mode's entire write-plus-cleanup now happens inside one
    /// `processingLock` critical section, and every operation that mutates
    /// the ingestion state it clears also holds `processingLock` (or, for
    /// the callback-safe `enqueueLiveStereoBuffer`, holds `configurationLock`
    /// for its whole check-then-append — see that method's doc comment),
    /// neither ordering above is possible: two mode transitions can never
    /// interleave, and a transactional operation either completes entirely
    /// before a transition starts or entirely after it finishes cleaning up.
    /// `mode` therefore remains at its old value for the whole duration a
    /// transition is blocked behind an in-flight transaction — this is a
    /// deliberate correctness trade against the same bounded, occasional
    /// writer-vs-writer contention already accepted for the other three
    /// transactional methods, not a race left in place.
    public var mode: TimecodeControlMode {
        get { currentConfigurationSnapshot().mode }
        set {
            processingLock.lock()

            configurationLock.lock()
            let old = _publishedConfiguration
            guard old.mode != newValue else {
                configurationLock.unlock()
                processingLock.unlock()
                return
            }
            var config = old
            config.mode = newValue
            _publishedConfiguration = config
            configurationLock.unlock()

#if DEBUG
            // Fires here — after the configuration write, before the
            // ingestion-lock cleanup, still holding `processingLock` — so a
            // test can deterministically pause a transition mid-flight and
            // prove a concurrent second transition cannot interleave (it
            // would need `processingLock` too, which this transition holds
            // for its entire write-plus-cleanup).
            debugPostConfigurationCaptureHook?()
#endif

            // Leaving `.controlPrototype`: clear every piece of queued
            // control audio that could otherwise be decoded later —
            // both the direct-push accumulator and the live-ingress
            // pending queue/bookkeeping, all under the same ingestion
            // `lock` transactional methods already use. Lifetime
            // diagnostic totals (`totalLiveReceivedCount`,
            // `totalLiveDroppedForLatencyCount`, `latestLiveBufferReceivedAt`)
            // are intentionally preserved — only `reset()` clears those.
            if old.mode == .controlPrototype {
                lock.lock()
                accumulatedStereoInputs.removeAll(keepingCapacity: true)
                pendingLiveStereoInputs.removeAll(keepingCapacity: true)
                pendingLiveFrameCount = 0
                pendingLiveReceivedCount = 0
                lock.unlock()
                cumulativePlatterPosition = 0
            }

            processingLock.unlock()
            sendChangeNotification()
        }
    }

    // MARK: - Calibration

    /// When true, the sign of all position deltas is flipped before
    /// producing platter output.
    public var invertDirection: Bool {
        get { currentConfigurationSnapshot().invertDirection }
        set { updateConfiguration { $0.invertDirection = newValue } }
    }

    /// Multiplier applied to position deltas (and velocities). 1.0 = no
    /// scaling, 0.5 = half speed, 2.0 = double speed.
    public var rateScale: Double {
        get { currentConfigurationSnapshot().rateScale }
        set { updateConfiguration { $0.rateScale = newValue } }
    }

    /// Which channel(s) of the stereo input to use.
    /// Only `.stereo` produces meaningful phase-delta output for decoding;
    /// `.left` and `.right` are provided for channel-level diagnostics.
    public var inputChannel: TimecodeInputChannel {
        get { currentConfigurationSnapshot().inputChannel }
        set { updateConfiguration { $0.inputChannel = newValue } }
    }

    /// Minimum confidence for a decoded frame to be included in platter
    /// output.
    public var minConfidence: Double {
        get { currentConfigurationSnapshot().minConfidence }
        set { updateConfiguration { $0.minConfidence = newValue } }
    }

    /// Maximum absolute velocity allowed in position-units per second.
    /// Velocities exceeding this are clamped.
    public var maxRate: Double {
        get { currentConfigurationSnapshot().maxRate }
        set { updateConfiguration { $0.maxRate = newValue } }
    }

    /// RMS below this value is considered silence by the signal
    /// diagnostics stage.
    public var signalThresholdRMS: Float {
        get { currentConfigurationSnapshot().signalThresholdRMS }
        set { updateConfiguration { $0.signalThresholdRMS = newValue } }
    }

    /// Dead-band around zero for `currentDirection` sign decisions, in the
    /// same position-units/second domain as `currentRate`. Below this
    /// magnitude, the previous `currentDirection` is held rather than
    /// re-derived, so near-stationary noise cannot flip direction. Matches
    /// `TimecodePhaseDecoder.stationaryVelocityEpsilon` and the "stopped"
    /// threshold already used by `DVSControlVinylPanel`.
    private static let directionDeadband: Double = 0.05

    /// Minimum consecutive same-direction accepted frames at the end of a
    /// flush's batch, opposite to the currently-published direction, needed
    /// to trust that trailing run immediately instead of waiting for the
    /// EMA-smoothed rate to cross `directionDeadband`. `1` would react to a
    /// single noisy blip (the exact case
    /// `testTrailingNoisyReversalFrameDoesNotFlip{Forward,Backward}Direction`
    /// guards against); `2` requires the reversal to actually persist for at
    /// least one more frame while still reacting far faster than the EMA.
    private static let reversalConfirmFrameCount = 2

    /// Scans `accepted` from the end and, if the trailing run is known,
    /// differs from `currentDirection`, and is at least `minimumRun` frames
    /// long, returns that direction plus the run's mean velocity — a
    /// sustained reversal the decoder has already confirmed, not a single
    /// noisy sample. Returns `nil` when no such confirmed reversal exists in
    /// this batch, leaving the caller to fall back to the EMA-smoothed
    /// dead-band check.
    ///
    /// The mean velocity matters as much as the direction: `currentRate` —
    /// not `currentDirection` — is what actually drives playback scheduling
    /// (`TimecodePlaybackDrive.rate` → `TimecodeDriveStepConverter`'s
    /// accumulated steps → `ScratchSamplePlaybackController`'s
    /// `schedulingDirection`, which is derived from the step delta's sign,
    /// not from any direction label — see the comment at that call site).
    /// Flipping only the label while leaving the EMA-smoothed rate to coast
    /// through zero on its own does not change what actually gets scheduled.
    private static func trailingConfirmedReversal(
        in accepted: [TimecodeDecodedFrame],
        differentFrom currentDirection: TimecodeDirection,
        minimumRun: Int
    ) -> (direction: TimecodeDirection, rate: Double)? {
        guard let last = accepted.last?.direction, last != .unknown, last != currentDirection else {
            return nil
        }
        var run: [TimecodeDecodedFrame] = []
        for frame in accepted.reversed() {
            guard frame.direction == last else { break }
            run.append(frame)
        }
        guard run.count >= minimumRun else { return nil }
        let meanVelocity = run.reduce(0) { $0 + $1.velocity } / Double(run.count)
        return (last, meanVelocity)
    }

    // MARK: - Configuration state

    /// The eight pipeline-configuration values (`liveTapEnabled`, `mode`,
    /// `invertDirection`, `rateScale`, `inputChannel`, `minConfidence`,
    /// `maxRate`, `signalThresholdRMS`) published as one coherent unit,
    /// mirroring `OutputState` below. `pushStereoBuffer` and `flushDecode`
    /// capture this exactly once via `captureConfigurationForOperation()`
    /// — *after* acquiring `processingLock`, never before — and use only
    /// that captured value for their entire body. `makeValidationSnapshot`
    /// (a pure reader, no ingestion-state mutation) captures it the same
    /// way but without `processingLock`. `enqueueLiveStereoBuffer` reads it
    /// directly under `configurationLock`, held for its whole check-then-
    /// append (see that method's doc comment) rather than through
    /// `captureConfigurationForOperation()`. None of the four re-reads a
    /// property getter mid-operation, which could observe a different,
    /// concurrently installed generation partway through.
    private struct ConfigurationState: Equatable {
        var liveTapEnabled: Bool = false
        var mode: TimecodeControlMode = .disabled
        var invertDirection: Bool = false
        var rateScale: Double = 1.0
        var inputChannel: TimecodeInputChannel = .stereo
        var minConfidence: Double = 0.3
        var maxRate: Double = 5.0
        var signalThresholdRMS: Float = 0.001
    }

    /// Guards the single published `_publishedConfiguration` snapshot.
    ///
    /// **Lock order for this class, in full:** `processingLock` →
    /// `configurationLock` → the ingestion `lock`, for anything that
    /// touches more than one. `outputLock` is independent of all three —
    /// its critical section never itself acquires any other lock, and
    /// nothing else is ever held while acquiring it except the brief
    /// `processingLock` window each transactional method's `defer` already
    /// uses to swap in its result.
    ///
    /// Two call patterns use `configurationLock`:
    /// - **Transactional (`mode`'s setter, `pushStereoBuffer`,
    ///   `flushDecode`):** already hold `processingLock` (or, for `mode`'s
    ///   setter, acquire it first) before touching `configurationLock`,
    ///   and release `configurationLock` again before touching the
    ///   ingestion `lock` — the three are never all held at once, only
    ///   ever in that relative order, which is sufficient to prevent a
    ///   cycle: a transactional operation's *entire* body, including
    ///   whichever of `configurationLock`/`lock` it touches, is already
    ///   serialized against every other transactional operation by
    ///   `processingLock` alone.
    /// - **Callback-safe (`enqueueLiveStereoBuffer`):** never touches
    ///   `processingLock` at all (a real-time audio callback must not
    ///   block behind DSP work). It holds `configurationLock` continuously
    ///   from its mode check through its ingestion-`lock`-guarded append —
    ///   a `configurationLock` → `lock` nesting, still consistent with the
    ///   global order above. This is what makes a live-ingress callback
    ///   linearize correctly against a mode transition's cleanup of the
    ///   same pending-ingress state: whichever of the two acquires
    ///   `configurationLock` first (the callback's whole check-and-append,
    ///   or the transition's brief config swap) is guaranteed to complete
    ///   before the other can proceed, so a callback that observed the old
    ///   mode either finishes its append before a concurrent disable's
    ///   cleanup can start, or never starts appending because it acquires
    ///   `configurationLock` afterward and observes the new mode.
    ///
    /// `configurationLock`'s own critical sections are always trivial — a
    /// struct copy, a swap, or (for `enqueueLiveStereoBuffer`) a small
    /// bounded array append/trim — never DSP/decode work, so nothing that
    /// only needs `configurationLock` (the plain property getters,
    /// `makeValidationSnapshot`) ever waits through a transaction.
    private let configurationLock = NSLock()
    private var _publishedConfiguration = ConfigurationState()

#if DEBUG
    /// Test-only hook invoked synchronously, once per pipeline operation,
    /// immediately after that operation reads or writes its
    /// `ConfigurationState` — before any further work that read/write is
    /// meant to linearize against. Blocking in this closure lets a test
    /// deterministically pause an operation mid-flight and control the
    /// exact interleaving with a concurrent second operation, rather than
    /// racing and hoping to catch a violation. Fires while holding
    /// whichever lock that operation's capture happens under:
    /// - `processingLock` for `pushStereoBuffer`/`flushDecode` (via
    ///   `captureConfigurationForOperation()`, called after
    ///   `processingLock.lock()`) and for `mode`'s setter (fires after the
    ///   configuration write, before the leaving-`.controlPrototype`
    ///   cleanup, still holding `processingLock` for the whole operation).
    /// - `configurationLock` for `enqueueLiveStereoBuffer` (held through
    ///   its whole check-then-append).
    /// - Neither, for the pure-reader `makeValidationSnapshot`.
    /// Always `nil` outside tests.
    public var debugPostConfigurationCaptureHook: (() -> Void)?
#endif

    /// Reads the currently published configuration snapshot. Cheap: only
    /// takes `configurationLock` for the duration of a struct copy. Used
    /// directly by the eight property getters above (each an independent,
    /// internally-coherent read, exactly like the `OutputState` getters
    /// below) and by `captureConfigurationForOperation()`.
    private func currentConfigurationSnapshot() -> ConfigurationState {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return _publishedConfiguration
    }

    /// Captures the configuration snapshot for one whole pipeline
    /// operation's transaction and fires `debugPostConfigurationCaptureHook`
    /// (DEBUG only, always `nil` in production). Call this exactly once
    /// per operation, at its boundary, and use the returned value for that
    /// operation's entire body. `pushStereoBuffer`/`flushDecode` call this
    /// only *after* acquiring `processingLock`, so the capture — and every
    /// subsequent use of it, including any ingestion-`lock`-guarded
    /// mutation — is fully serialized against `mode` transitions, which
    /// also hold `processingLock` for their entire write-plus-cleanup (see
    /// `mode`'s setter doc comment). `makeValidationSnapshot` calls this
    /// without `processingLock`, since it only reads and never mutates
    /// ingestion state.
    private func captureConfigurationForOperation() -> ConfigurationState {
        let config = currentConfigurationSnapshot()
#if DEBUG
        debugPostConfigurationCaptureHook?()
#endif
        return config
    }

    /// Atomically reads the current configuration, applies `mutate` to a
    /// local copy, and — if anything actually changed — swaps it in and
    /// sends `objectWillChange`. The read, mutation, and swap all happen
    /// under one `configurationLock` acquisition, so two concurrent
    /// writers to different fields (e.g. a `rateScale` slider drag racing
    /// an `applyCalibrationBatch` call) can never lose one another's
    /// update — each sees the other's already-published change rather
    /// than computing its own new value from a stale read. The
    /// notification is always sent only after `configurationLock` has
    /// been released, never while it is held; an assignment that doesn't
    /// actually change anything never notifies. Used by the seven
    /// configuration properties other than `mode` and by
    /// `applyCalibrationBatch` — `mode`'s setter has its own
    /// `processingLock`-first implementation (see its doc comment) because
    /// its leaving-`.controlPrototype` cleanup must linearize with
    /// `pushStereoBuffer`/`flushDecode`, which none of these other seven
    /// properties need.
    private func updateConfiguration(_ mutate: (inout ConfigurationState) -> Void) {
        configurationLock.lock()
        let old = _publishedConfiguration
        var config = old
        mutate(&config)
        let changed = config != old
        _publishedConfiguration = config
        configurationLock.unlock()
        if changed { sendChangeNotification() }
    }

    /// Atomically applies the five calibration values a
    /// `TimecodePrototypeProfile` controls (`inputChannel`,
    /// `invertDirection`, `rateScale`, `minConfidence`, `maxRate`) as a
    /// single configuration swap, matching `TimecodePrototypeProfile.
    /// apply(to:)`'s "atomically" documentation — which five sequential
    /// `@Published` assignments did not actually provide, since each was
    /// independently visible and independently notified the instant it
    /// was set. A pipeline operation that captures its configuration
    /// snapshot concurrently therefore observes either the complete old
    /// set of five values or the complete new set, never a mixture (e.g.
    /// one profile's `invertDirection` paired with another profile's
    /// `minConfidence`). Does not touch `mode` or `liveTapEnabled`,
    /// matching `apply(to:)`'s existing scope.
    public func applyCalibrationBatch(
        inputChannel: TimecodeInputChannel,
        invertDirection: Bool,
        rateScale: Double,
        minConfidence: Double,
        maxRate: Double
    ) {
        updateConfiguration {
            $0.inputChannel = inputChannel
            $0.invertDirection = invertDirection
            $0.rateScale = rateScale
            $0.minConfidence = minConfidence
            $0.maxRate = maxRate
        }
    }

    // MARK: - Published output

    /// The ten decoded-output values published as one coherent unit. A
    /// transaction (`pushStereoBuffer`/`flushDecode`/`reset`/
    /// `resetCounters`) computes a whole new value of this type locally —
    /// untouched by `outputLock` — and publishes it in one atomic swap only
    /// once processing has fully finished. Readers therefore only ever see
    /// a complete pre-transaction or complete post-transaction value, never
    /// a partially-applied one.
    private struct OutputState: Equatable {
        var latestPlatterTimeline: PlatterPositionTimeline?
        var latestDecodeResult: TimecodeDecodeResult?
        var latestDiagnosis: TimecodeSignalDiagnostics.Diagnosis?
        var latestClassification: TimecodeSignalDiagnostics.Diagnosis?
        var counters: TimecodeControlCounters = TimecodeControlCounters()
        var currentDirection: TimecodeDirection = .unknown
        var currentRate: Double = 0
        var lastDropReason: TimecodeDropoutReason?
        var signalHealth: SignalHealth = .noSignal
        var lastBufferReceivedAt: Date?
    }

    /// Guards only the single published `_publishedOutput` snapshot below.
    /// Acquired only for the trivial read at the start of a transaction,
    /// the trivial swap-in at the end of one, and public getter reads — it
    /// is never held across decode/diagnostics/filter/adapt/recorder work
    /// or `objectWillChange` delivery, so a SwiftUI getter never waits
    /// through that work. See `processingLock` for the lock that actually
    /// serializes pipeline writers and the internal state a transaction
    /// mutates alongside its output.
    private let outputLock = NSLock()
    private var _publishedOutput = OutputState()

    /// Serializes pipeline writers (`pushStereoBuffer`, `flushDecode`,
    /// `reset`, `resetCounters`) and the pipeline-internal state a
    /// transaction mutates alongside its output (`stabilityFilterState`,
    /// `cumulativePlatterPosition`, `pendingDiagnosticsBufferCount`,
    /// `lastDiagnosticsPublishAudioTime`, `decodeSessionStartDate`, the
    /// `diagnosticsTap`/`diagnosticsEngine`). Only one transaction runs at
    /// a time; each builds its result into a local `OutputState` value and
    /// swaps it in once, atomically, through `outputLock`
    /// (`swapPublishedOutput(_:)`), still while holding `processingLock` —
    /// only released afterward — so a second transaction can never start
    /// from a stale snapshot and silently clobber the first transaction's
    /// published update. The `objectWillChange` notification itself is
    /// sent separately, only *after* `processingLock` has been released
    /// (see `sendChangeNotification()`'s doc comment) — never while either
    /// lock is held. Readers never observe a partially-applied transaction
    /// and never block on `outputLock` through a decode.
    ///
    /// **Lock ordering:** `processingLock` is always acquired before the
    /// ingestion `lock` when a transaction needs both (the accumulator
    /// drain at the top of `flushDecode`/`reset`); `lock` is never held
    /// while acquiring `processingLock`. `outputLock` is independent of
    /// both — it is only ever touched by the brief read-then-release at
    /// the start of a transaction and the brief swap-then-release at the
    /// end, and its critical section never itself acquires `lock` or
    /// `processingLock`, so it cannot participate in a cycle with either.
    /// `enqueueLiveStereoBuffer`/`liveIngressDiagnostics` only ever take
    /// `lock` alone and never participate in this ordering.
    private let processingLock = NSLock()

#if DEBUG
    /// Test-only hook invoked synchronously, once per transaction,
    /// immediately before the computed `OutputState` is published — after
    /// all decode/diagnostics/filter/adapt work for that transaction has
    /// finished. Blocking in this closure lets a test deterministically
    /// pause a transaction mid-flight (holding `processingLock` but not
    /// `outputLock`) to prove readers only ever observe the pre- or
    /// post-transaction snapshot, that output getters do not block while
    /// paused, and that `reset`/`resetCounters` publish one complete state.
    /// Always `nil` outside tests.
    public var debugPrePublishHook: (() -> Void)?
#endif

    /// Reads the currently published output snapshot. Cheap: only takes
    /// `outputLock` for the duration of a struct copy.
    private func currentOutputSnapshot() -> OutputState {
        outputLock.lock()
        defer { outputLock.unlock() }
        return _publishedOutput
    }

    /// Atomically swaps `newState` in as the single visible output
    /// snapshot and returns whether it differs from the previous one.
    /// `outputLock` is held only for the swap-in and equality check — this
    /// method never itself calls `sendChangeNotification()`. Callers use
    /// this while still holding `processingLock` (see the four
    /// transactional methods' `defer` blocks) and only invoke
    /// `sendChangeNotification()` afterward, once `processingLock` has
    /// also been released, so `objectWillChange` is never delivered while
    /// either lock is held.
    private func swapPublishedOutput(_ newState: OutputState) -> Bool {
#if DEBUG
        debugPrePublishHook?()
#endif
        outputLock.lock()
        let changed = newState != _publishedOutput
        _publishedOutput = newState
        outputLock.unlock()
        return changed
    }

    /// Each getter below independently calls `currentOutputSnapshot()` and
    /// returns immediately: the value it returns is exactly one complete,
    /// atomically-swapped `OutputState` generation, never a torn read.
    /// But two *separate* getter calls made back-to-back are two separate
    /// snapshot reads — if a transaction publishes in the gap between them,
    /// the second call legitimately observes a newer, equally complete
    /// generation than the first. That is expected, not a bug: nothing
    /// promises cross-call agreement between independent getters, only that
    /// each individual call is internally coherent. A caller that needs
    /// several fields to agree with each other from the same generation
    /// (`makeValidationSnapshot` is the example already in this file) must
    /// capture `currentOutputSnapshot()` once itself and derive every field
    /// from that one captured value, rather than calling multiple getters
    /// and assuming they landed on the same transaction.
    ///
    /// The most recent platter position timeline produced by the pipeline,
    /// or `nil` when no trusted motion has been decoded.
    public var latestPlatterTimeline: PlatterPositionTimeline? { currentOutputSnapshot().latestPlatterTimeline }

    /// The most recent raw decode result, if any.
    public var latestDecodeResult: TimecodeDecodeResult? { currentOutputSnapshot().latestDecodeResult }

    /// The most recent signal diagnosis.
    public var latestDiagnosis: TimecodeSignalDiagnostics.Diagnosis? { currentOutputSnapshot().latestDiagnosis }

    /// The most recent signal modulation classification (Batch 13).
    public var latestClassification: TimecodeSignalDiagnostics.Diagnosis? { currentOutputSnapshot().latestClassification }

    /// Aggregate debug counters.
    public var counters: TimecodeControlCounters { currentOutputSnapshot().counters }

    /// Current decoded direction.
    public var currentDirection: TimecodeDirection { currentOutputSnapshot().currentDirection }

    /// Current decoded rate in position-units per second.
    public var currentRate: Double { currentOutputSnapshot().currentRate }

    /// Reason for the most recent dropout, or `nil` when the last decode
    /// was successful.
    public var lastDropReason: TimecodeDropoutReason? { currentOutputSnapshot().lastDropReason }

    /// Aggregate signal health from the most recent diagnostics pass.
    public var signalHealth: SignalHealth { currentOutputSnapshot().signalHealth }

    /// Wall-clock time of the most recently received live audio buffer,
    /// or `nil` when no buffer has been received since the last reset.
    public var lastBufferReceivedAt: Date? { currentOutputSnapshot().lastBufferReceivedAt }

    /// The internal diagnostics tap, exposed for UI binding (e.g.
    /// `TimecodeInputStatusCard`). Updated on each `pushStereoBuffer()`
    /// call.
    public let diagnosticsTap: TimecodeInputTap

    // MARK: - Internal state

    /// Guards only the ingestion accumulator/queue below (`accumulatedStereoInputs`,
    /// `pendingLiveStereoInputs`, and their bookkeeping counters). See
    /// `processingLock`'s doc comment above for the lock-ordering contract
    /// between the two.
    private let lock = NSLock()
    private var accumulatedStereoInputs: [TimecodePhaseDecoder.StereoInput] = []
    private var pendingLiveStereoInputs: [TimecodePhaseDecoder.StereoInput] = []
    private var pendingLiveFrameCount = 0
    private var pendingLiveReceivedCount = 0
    private var totalLiveReceivedCount = 0
    private var totalLiveDroppedForLatencyCount = 0
    private var latestLiveBufferReceivedAt: Date?
    private var latestAudioInputEndRelativeTime: TimeInterval?
    private var latestAudioInputReceivedAt: Date?
    private var decodeSessionStartDate: Date = Date()
    private var accumulatedAudioFrameCount: Int64 = 0
    private var pendingDiagnosticsBufferCount = 0
    private var lastDiagnosticsPublishAudioTime: TimeInterval = -.infinity
    private let diagnosticsEngine = TimecodeSignalDiagnostics()
    /// Built from the `minConfidence` captured in a pipeline operation's
    /// own `ConfigurationState` snapshot (never the live property getter,
    /// so the whole operation stays on one configuration generation — see
    /// `ConfigurationState`'s doc comment). Previously this read the live
    /// `minConfidence` property directly from a `let` built once from the
    /// static `.conservative` config, whose `minConfidenceForUpdate` (0.3)
    /// never tracked `minConfidence` — so lowering the UI's confidence
    /// threshold had no effect on the gate that actually rejects frames.
    private func stabilityFilter(minConfidence: Double) -> TimecodeMotionStabilityFilter {
        TimecodeMotionStabilityFilter(
            config: TimecodeStabilityConfig(minConfidenceForUpdate: minConfidence)
        )
    }
    private var stabilityFilterState = TimecodeStabilityFilterState()
    /// Last trusted position emitted by the adapter. Held across empty or
    /// rejected flushes so a genuine signal gap remains a gap rather than a
    /// silent jump back to zero when decoding resumes.
    private var cumulativePlatterPosition: Double = 0
    private let liveDiagnosticsPublishInterval: TimeInterval = 0.1
    /// Prevent a delayed SwiftUI/main run loop from replaying old control
    /// audio. Eight small callbacks preserve normal 60 Hz batching; the
    /// 200 ms frame cap keeps the Rane's observed 4,800-frame callbacks below
    /// the bridge's 500 ms stale threshold.
    private static let maximumPendingLiveBufferCount = 8
    private static let maximumPendingLiveAudioDuration: TimeInterval = 0.2

    /// Internal decoder instance, built from the `signalThresholdRMS`
    /// captured in a pipeline operation's own `ConfigurationState`
    /// snapshot (never the live property getter — see `ConfigurationState`'s
    /// doc comment).
    private func decoder(signalThresholdRMS: Float) -> TimecodePhaseDecoder {
        TimecodePhaseDecoder(
            carrierFrequency: 1000,
            silenceThresholdRMS: signalThresholdRMS,
            clippingThreshold: 0.999,
            minCorrelationMagnitude: 0.1
        )
    }

    // MARK: - Prototype recorder (DEBUG only)

#if DEBUG
    /// In-memory recorder for trusted `timecode_live` prototype takes.
    /// Defaults idle/empty. Controlled via `startRecording` / `stopRecording` /
    /// `clearTake`. Only receives samples when `mode == .controlPrototype` and
    /// `flushDecode()` produces a trusted timeline.
    public let prototypeRecorder = TimecodePrototypeRecorder()
#endif

    // MARK: - Init

    /// `notificationClock` back the flush-notification coalescing below —
    /// injectable so tests can pin elapsed time deterministically instead
    /// of depending on how long a test's own synthetic decode work
    /// happens to take on the machine running it. Defaults to the real
    /// monotonic clock for production use.
    public init(
        sampleRate: Double = 44100,
        channelCount: Int = 2,
        notificationClock: @escaping () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.diagnosticsTap = TimecodeInputTap(sampleRate: sampleRate, channelCount: channelCount)
        self.notificationClock = notificationClock
    }

    // MARK: - Buffer input

    /// Push a raw stereo audio buffer into the pipeline.
    ///
    /// - Behavior by mode:
    ///   - `.disabled`: Drops the buffer silently.
    ///   - `.diagnosticsOnly`: Runs signal diagnostics, publishes health
    ///     and counters, but does NOT decode or emit platter motion.
    ///   - `.controlPrototype`: Runs diagnostics, accumulates the buffer,
    ///     and decodes/adapts on the next `flushDecode()` call.
    ///
    /// - Parameters:
    ///   - left: Left-channel samples, normalised to [-1, +1].
    ///   - right: Right-channel samples, normalised to [-1, +1].
    ///   - sampleRate: Sample rate in Hz (e.g. 44100, 48000).
    ///   - hostTime: Optional host-clock timestamp.
    public func pushStereoBuffer(
        left: [Float],
        right: [Float],
        sampleRate: Double = 44100,
        hostTime: UInt64? = nil,
        frameCount: Int? = nil
    ) {
        processingLock.lock()
        // Captured only after acquiring `processingLock`, not before — see
        // `captureConfigurationForOperation()`'s doc comment. This is what
        // linearizes this whole operation (including the ingestion-`lock`-
        // guarded accumulate below) against a concurrent `mode` transition,
        // which also holds `processingLock` for its entire write-plus-
        // cleanup: either this call's mode capture and accumulation happen
        // entirely before the transition starts, or entirely after it has
        // already finished clearing the accumulator.
        let config = captureConfigurationForOperation()
        var state = currentOutputSnapshot()
        defer {
            let changed = swapPublishedOutput(state)
            processingLock.unlock()
            if changed { sendChangeNotification() }
        }

        switch config.mode {
        case .disabled:
            // Silently drop — no diagnostics, no accumulation, no motion.
            return

        case .diagnosticsOnly:
            state.lastBufferReceivedAt = Date()
            runDiagnostics(
                into: &state,
                left: left,
                right: right,
                sampleRate: sampleRate,
                hostTime: hostTime,
                frameCount: frameCount,
                bufferIncrement: 1,
                mode: config.mode
            )
            // Do NOT accumulate or decode.

        case .controlPrototype:
            let relativeTime = accumulateStereoInput(
                left: left,
                right: right,
                sampleRate: sampleRate,
                hostTime: hostTime,
                frameCount: frameCount,
                channel: config.inputChannel
            )
            pendingDiagnosticsBufferCount += 1

            guard relativeTime - lastDiagnosticsPublishAudioTime >= liveDiagnosticsPublishInterval else {
                return
            }
            lastDiagnosticsPublishAudioTime = relativeTime
            state.lastBufferReceivedAt = Date()
            runDiagnostics(
                into: &state,
                left: left,
                right: right,
                sampleRate: sampleRate,
                hostTime: hostTime,
                frameCount: frameCount,
                bufferIncrement: pendingDiagnosticsBufferCount,
                mode: config.mode
            )
            pendingDiagnosticsBufferCount = 0
        }
    }

    /// Deposit a live callback into the control pipeline without publishing
    /// observable state or running diagnostics on the audio callback thread.
    ///
    /// The newest bounded audio window is retained. If the main run loop is
    /// delayed, older callbacks are intentionally discarded so recovery uses
    /// current platter motion instead of replaying a stale queue.
    ///
    /// Deliberately never touches `processingLock` — a real-time audio
    /// callback must not block behind a `flushDecode()`'s DSP work.
    /// Instead it holds `configurationLock` continuously from its mode
    /// check through the ingestion-`lock`-guarded append below (a
    /// `configurationLock` → `lock` nesting, consistent with this class's
    /// documented lock order — see `configurationLock`'s doc comment).
    /// That is what linearizes this callback against a concurrent `mode`
    /// transition's cleanup of `pendingLiveStereoInputs`: whichever of the
    /// two acquires `configurationLock` first completes entirely before
    /// the other can proceed, so a callback that observed the old mode
    /// either finishes appending before a disable's cleanup can start, or
    /// never starts appending because by the time it acquires
    /// `configurationLock` the new mode is already published.
    public func enqueueLiveStereoBuffer(
        left: [Float],
        right: [Float],
        sampleRate: Double = 44100,
        hostTime: UInt64? = nil,
        frameCount: Int? = nil,
        receivedAt: Date = Date()
    ) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        let config = _publishedConfiguration
#if DEBUG
        debugPostConfigurationCaptureHook?()
#endif
        guard config.mode != .disabled else { return }

        let safeSampleRate = sampleRate > 0 ? sampleRate : diagnosticsTap.sampleRate
        let frames = max(0, min(frameCount ?? min(left.count, right.count), min(left.count, right.count)))
        guard frames > 0 else { return }
        let (effectiveLeft, effectiveRight) = applyChannelSelection(left: left, right: right, channel: config.inputChannel)

        lock.lock()
        let relativeTime = Double(accumulatedAudioFrameCount) / safeSampleRate
        accumulatedAudioFrameCount += Int64(frames)
        latestAudioInputEndRelativeTime = relativeTime + Double(frames) / safeSampleRate
        latestAudioInputReceivedAt = receivedAt
        pendingLiveStereoInputs.append(
            TimecodePhaseDecoder.StereoInput(
                left: effectiveLeft,
                right: effectiveRight,
                sampleRate: safeSampleRate,
                hostTime: hostTime,
                relativeTime: relativeTime
            )
        )
        pendingLiveFrameCount += frames
        pendingLiveReceivedCount += 1
        totalLiveReceivedCount += 1
        latestLiveBufferReceivedAt = receivedAt

        let maximumPendingFrames = max(frames, Int(safeSampleRate * Self.maximumPendingLiveAudioDuration))
        while pendingLiveStereoInputs.count > Self.maximumPendingLiveBufferCount ||
                (pendingLiveFrameCount > maximumPendingFrames && pendingLiveStereoInputs.count > 1) {
            let removed = pendingLiveStereoInputs.removeFirst()
            pendingLiveFrameCount -= min(removed.left.count, removed.right.count)
            totalLiveDroppedForLatencyCount += 1
        }
        lock.unlock()
    }

    /// Snapshot of live-ingress health for DEBUG diagnostics and tests.
    public var liveIngressDiagnostics: TimecodeLiveIngressDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return TimecodeLiveIngressDiagnostics(
            totalReceived: totalLiveReceivedCount,
            totalDroppedForLatency: totalLiveDroppedForLatencyCount,
            pendingBuffers: pendingLiveStereoInputs.count,
            pendingFrames: pendingLiveFrameCount,
            latestReceivedAt: latestLiveBufferReceivedAt
        )
    }

    // MARK: - Decode flush

    /// Run the decoder → calibration → adapter chain on all accumulated
    /// stereo buffers, publish the resulting platter timeline, and clear
    /// the accumulator.
    ///
    /// Has no effect in `.disabled` or `.diagnosticsOnly` modes (the
    /// accumulator is always empty in those modes).
    @discardableResult
    public func flushDecode(now: Date = Date()) -> PlatterPositionTimeline? {
        processingLock.lock()
        // Captured only after acquiring `processingLock` — see
        // `pushStereoBuffer`'s matching comment and
        // `captureConfigurationForOperation()`'s doc comment. This
        // linearizes the accumulator drain below against a concurrent
        // `mode` transition's own `processingLock`-held cleanup: this
        // flush either drains/decodes entirely before the transition
        // starts, or entirely after the transition has already cleared
        // the accumulator (in which case it correctly sees nothing to
        // decode).
        let config = captureConfigurationForOperation()
        var state = currentOutputSnapshot()
        defer {
            let changed = swapPublishedOutput(state)
            processingLock.unlock()
            if changed { sendCoalescedFlushChangeNotification() }
        }

        lock.lock()
        let liveInputs = pendingLiveStereoInputs
        let inputs = accumulatedStereoInputs + liveInputs
        let liveReceivedCount = pendingLiveReceivedCount
        let liveReceivedAt = latestLiveBufferReceivedAt
        let latestAudioEndTime = latestAudioInputEndRelativeTime
        let latestAudioReceipt = latestAudioInputReceivedAt
        accumulatedStereoInputs.removeAll(keepingCapacity: true)
        pendingLiveStereoInputs.removeAll(keepingCapacity: true)
        pendingLiveFrameCount = 0
        pendingLiveReceivedCount = 0
        lock.unlock()

        guard config.mode != .disabled else {
            return nil
        }

        if let liveReceivedAt {
            state.lastBufferReceivedAt = liveReceivedAt
        }
        if liveReceivedCount > 0 {
            pendingDiagnosticsBufferCount += liveReceivedCount
            if let latest = liveInputs.last,
               latest.relativeTime - lastDiagnosticsPublishAudioTime >= liveDiagnosticsPublishInterval {
                lastDiagnosticsPublishAudioTime = latest.relativeTime
                runDiagnostics(
                    into: &state,
                    left: latest.left,
                    right: latest.right,
                    sampleRate: latest.sampleRate,
                    hostTime: latest.hostTime,
                    frameCount: min(latest.left.count, latest.right.count),
                    bufferIncrement: pendingDiagnosticsBufferCount,
                    mode: config.mode
                )
                pendingDiagnosticsBufferCount = 0
            }
        }
        publishPendingDiagnosticsBufferCount(into: &state)

        guard config.mode == .controlPrototype else {
            return nil
        }

        // When no buffers arrived this window the decoder is skipped, but the
        // stability filter must still run so the dropout clock advances.
        guard !inputs.isEmpty else {
            // Stay in the same relative-audio clock domain used by decoded
            // frames. Comparing that clock with wall time since pipeline init
            // made a tap enabled minutes later look instantly >1 s stale on
            // every empty 60 Hz tick between 100 ms Rane callbacks.
            let flushTime: TimeInterval
            if let latestAudioEndTime, let latestAudioReceipt {
                flushTime = latestAudioEndTime + max(0, now.timeIntervalSince(latestAudioReceipt))
            } else {
                flushTime = now.timeIntervalSince(decodeSessionStartDate)
            }
            let filterResult = stabilityFilter(minConfidence: config.minConfidence).filter(
                frames: [],
                state: stabilityFilterState,
                flushRelativeTime: flushTime
            )
            stabilityFilterState = filterResult.state
            var c = state.counters
            c.smoothedRate = filterResult.metrics.smoothedRate
            c.smoothingActive = false
            c.heldDropoutCount += filterResult.metrics.heldDropoutCount
            c.longDropoutCount += filterResult.metrics.longDropoutCount
            c.lastDropoutDuration = filterResult.metrics.lastDropoutDuration
            // A long dropout (no incoming audio at all) must fail closed the
            // same way the "decoder ran but produced zero accepted frames"
            // path below does — otherwise `currentRate`/`currentDirection`/
            // `latestPlatterTimeline` stay frozen on stale motion data
            // indefinitely while real audio input is missing, instead of
            // reporting no signal. Short gaps intentionally hold state (audio
            // buffers routinely arrive slower than the 60 Hz flush tick).
            if filterResult.metrics.longDropoutCount > 0 {
                state.currentDirection = .unknown
                state.currentRate = 0
                state.latestPlatterTimeline = nil
                c.currentDirection = state.currentDirection.rawValue
                c.currentRate = state.currentRate
            }
            state.counters = c
            return nil
        }

        // Run decoder
        let decoderInstance = decoder(signalThresholdRMS: config.signalThresholdRMS)
        let decodeResult = decoderInstance.decode(inputs)

        // Transfer decoder counters into pipeline counters
        var c = state.counters
        c.decodedSamples += decodeResult.counters.decodedSamples
        c.droppedSilence += decodeResult.counters.droppedSilence
        c.droppedClipped += decodeResult.counters.droppedClipped
        c.directionChanges += decodeResult.counters.directionChanges
        c.signalHealth = decodeResult.signalHealth.rawValue
        state.signalHealth = decodeResult.signalHealth

        // Acceptance-gate diagnostics for this flush (see field docs on
        // TimecodeControlCounters for what each one proves).
        c.minConfidenceRuntime = config.minConfidence
        c.stabilityMinConfidenceRuntime = config.minConfidence
        c.decodedFrameCount = decodeResult.counters.decodedSamples
        c.preFilterFrameCount = decodeResult.frames.count
        c.frameConfidenceMin = decodeResult.counters.frameConfidenceMin
        c.frameConfidenceMax = decodeResult.counters.frameConfidenceMax
        c.framesAboveMinConfidence = decodeResult.frames.filter { $0.confidence >= config.minConfidence }.count
        c.framesBelowMinConfidence = decodeResult.frames.filter { $0.confidence < config.minConfidence }.count
        c.rawDecodeTrace = decodeResult.frames.map {
            "\($0.direction.rawValue.prefix(1))/\(String(format: "%.2f", $0.velocity))"
        }.joined(separator: " ")

        // Record per-decode-window drop reason from the decoder
        if decodeResult.frames.isEmpty, let reason = decodeResult.dropoutReason {
            c.lastDropReason = reason.rawValue
            state.lastDropReason = reason
            switch reason {
            case .silence:          c.droppedSilence += 1
            case .clipped:          c.droppedClipped += 1
            case .lowConfidence:    c.droppedLowConfidence += 1
            case .channelFault:     c.droppedChannelFault += 1
            case .noPhaseLock:      c.droppedWeakSignal += 1
            }
        }

        // Apply calibration (rate scale, invert) to decoded frames
        var calibratedFrames = decodeResult.frames
        if !calibratedFrames.isEmpty && (config.rateScale != 1.0 || config.invertDirection) {
            var cumulativePosition: Double = 0
            for i in 0..<calibratedFrames.count {
                var frame = calibratedFrames[i]
                let sign: Double = config.invertDirection ? -1.0 : 1.0
                let scaledDelta = frame.deltaPosition * config.rateScale * sign
                let scaledVelocity = frame.velocity * config.rateScale * sign
                cumulativePosition += scaledDelta
                frame = TimecodeDecodedFrame(
                    hostTime: frame.hostTime,
                    relativeTime: frame.relativeTime,
                    position: cumulativePosition,
                    deltaPosition: scaledDelta,
                    velocity: scaledVelocity,
                    direction: config.invertDirection ? frame.direction.inverted : frame.direction,
                    confidence: frame.confidence
                )
                calibratedFrames[i] = frame
            }
        }
        c.calibratedTrace = calibratedFrames.map {
            "\($0.direction.rawValue.prefix(1))/\(String(format: "%.2f", $0.velocity))"
        }.joined(separator: " ")

        // Apply stability filter (runs even on empty batch to track dropout timing)
        let flushTime = inputs.last?.relativeTime ?? 0
        let filterResult = stabilityFilter(minConfidence: config.minConfidence).filter(
            frames: calibratedFrames,
            state: stabilityFilterState,
            flushRelativeTime: flushTime
        )
        stabilityFilterState = filterResult.state

        // Accumulate stability counters
        c.smoothedRate = filterResult.metrics.smoothedRate
        c.smoothingActive = filterResult.metrics.smoothingActive
        c.rejectedSpikeCount += filterResult.metrics.rejectedSpikeCount
        c.heldDropoutCount += filterResult.metrics.heldDropoutCount
        c.longDropoutCount += filterResult.metrics.longDropoutCount
        if !filterResult.metrics.lastSpikeReason.isEmpty {
            c.lastSpikeReason = filterResult.metrics.lastSpikeReason
        }
        c.lastDropoutDuration = filterResult.metrics.lastDropoutDuration
        c.maxAbsSmoothedRate = max(c.maxAbsSmoothedRate, filterResult.metrics.maxAbsSmoothedRate)

        // Acceptance-gate diagnostics (see field docs on TimecodeControlCounters)
        c.postFilterFrameCount = filterResult.accepted.count
        c.lowConfidenceRejectCount += filterResult.metrics.lowConfidenceRejectCount
        c.rateSpikeRejectCount += filterResult.metrics.rateSpikeRejectCount
        c.firstRejectReasonThisFlush = filterResult.metrics.firstRejectReason

        // No trusted output (decoder empty, spike-rejected, or dropout)?
        guard !filterResult.accepted.isEmpty else {
            if filterResult.metrics.rejectedSpikeCount > 0 && !decodeResult.frames.isEmpty {
                c.lastDropReason = filterResult.metrics.lastSpikeReason
            }
            c.averageConfidence = decodeResult.averageConfidence
            state.counters = c
            state.latestPlatterTimeline = nil
            state.currentDirection = .unknown
            state.currentRate = 0
#if DEBUG
            let dropReason = decodeResult.dropoutReason?.rawValue
                ?? (filterResult.metrics.rejectedSpikeCount > 0 ? "rejected_spike" : "no_trusted_frames")
            prototypeRecorder.recordDrop(reason: dropReason)
#endif
            return nil
        }

        // Build adapter with current calibration thresholds
        let adapter = TimecodePlatterAdapter(
            minConfidence: config.minConfidence,
            maxRate: config.maxRate,
            source: .timecodeLive
        )

        // Wrap stabilized frames for the adapter
        let stabilizedResult = TimecodeDecodeResult(
            frames: filterResult.accepted,
            averageConfidence: decodeResult.averageConfidence,
            signalHealth: decodeResult.signalHealth,
            dropoutReason: decodeResult.dropoutReason,
            counters: decodeResult.counters
        )
        state.latestDecodeResult = stabilizedResult

        // Update current direction/rate from the stability filter's
        // EMA-smoothed rate, not the last accepted frame's raw per-sample
        // value. The filter deliberately lets a single direction-flipping
        // sample bypass spike rejection (`isGenuineReversal`) so real
        // reversals aren't lost as noise — but that means the *last frame
        // in a batch* can be exactly one such noisy sample rather than the
        // batch's dominant direction, so deriving direction from it flips
        // F/B/F/B on steady one-direction motion. The smoothed rate's sign
        // (with a dead-band near zero so near-stationary noise can't flip
        // it) tracks the batch's real trend and still detects a genuine
        // reversal once enough opposite-direction samples pull the EMA
        // across zero.
        //
        // On real hardware this EMA-only path measurably lags: a validated
        // reversal shows the reported rate coasting down through zero over
        // several accepted frames before the smoothed sign actually flips,
        // and a fast back-stroke can complete (several reversals) within a
        // single flush's accumulated batch, so only the *last* reversal's
        // settled EMA state ever reaches `currentDirection` — the earlier
        // ones are silently dropped, not just delayed. The decoder's own
        // per-frame direction is already correct and immediate (see
        // TimecodeLiveIntegrationTests' stage-trace regressions), so a
        // sustained trailing run of same-direction accepted frames — at
        // least `reversalConfirmFrameCount`, deliberately more than one so a
        // single noisy blip can't flip it (see
        // testTrailingNoisyReversalFrameDoesNotFlip{Forward,Backward}Direction)
        // — is trusted immediately instead of waiting for the EMA.
        if !filterResult.accepted.isEmpty {
            let smoothed = filterResult.metrics.smoothedRate
            state.currentRate = smoothed
            if let confirmed = Self.trailingConfirmedReversal(
                in: filterResult.accepted,
                differentFrom: state.currentDirection,
                minimumRun: Self.reversalConfirmFrameCount
            ) {
                // Snap both the published rate and the persisted EMA state
                // to the confirmed reversal — `currentRate`'s sign, not
                // `currentDirection`, is what actually drives playback
                // scheduling (see the doc comment on
                // `trailingConfirmedReversal`), and leaving the persisted
                // EMA untouched would just have it coast back toward the
                // old direction on the next flush.
                state.currentDirection = confirmed.direction
                state.currentRate = confirmed.rate
                stabilityFilterState.smoothedRate = confirmed.rate
            } else if smoothed > Self.directionDeadband {
                state.currentDirection = .forward
            } else if smoothed < -Self.directionDeadband {
                state.currentDirection = .backward
            }
            // else: hold the previous currentDirection.
        }
        c.currentDirection = state.currentDirection.rawValue
        c.currentRate = state.currentRate
        c.maxAbsRate = max(c.maxAbsRate, abs(state.currentRate))

        // Adapt to platter timeline
        let timeline = adapter.adapt(
            stabilizedResult,
            startingPosition: cumulativePlatterPosition
        )
        if let lastPosition = timeline?.samples.last?.position {
            cumulativePlatterPosition = lastPosition
        }
        state.latestPlatterTimeline = timeline

#if DEBUG
        if DVSTrace.current > 0 {
            DVSTrace.log("[DVS-TRACE:1] pipeline motionPub seq=\(DVSTrace.current) monotonic=\(String(format: "%.6f", CACurrentMediaTime())) dir=\(state.currentDirection.rawValue) rate=\(String(format: "%.3f", state.currentRate)) confidence=\(String(format: "%.2f", decodeResult.averageConfidence)) health=\(decodeResult.signalHealth.rawValue) samples=\(timeline?.samples.count ?? 0) thread=\(Thread.isMainThread ? "main" : "bg")")
        }
#endif

        // Update counters
        c.acceptedMotionSamples += timeline?.samples.count ?? 0
        c.droppedLowConfidence += max(0, filterResult.accepted.count - (timeline?.samples.count ?? 0))
        c.averageConfidence = decodeResult.averageConfidence
        c.lastDropReason = ""
        c.signalHealth = decodeResult.signalHealth.rawValue
        state.lastDropReason = nil
        state.counters = c

#if DEBUG
        if let tl = timeline {
            prototypeRecorder.accept(timeline: tl)
        } else {
            prototypeRecorder.recordDrop(reason: TimecodeDropoutReason.lowConfidence.rawValue)
        }
#endif

        return timeline
    }

    // MARK: - Validation snapshot

    /// Build a point-in-time validation snapshot from current pipeline state.
    ///
    /// The snapshot is a pure value — it does not subscribe to any stream and
    /// does not update after creation. Call this from a SwiftUI view body or
    /// a test to get the current prototype health summary.
    ///
    /// **Generation-coherent, unlike chaining the public getters.** This
    /// method captures `currentOutputSnapshot()` exactly once and derives
    /// every field below from that single value, so the whole result is
    /// guaranteed to come from one transaction generation. Calling several
    /// of the public getters (`counters`, `currentDirection`, etc.) back to
    /// back instead does not give that guarantee — each is its own
    /// independent snapshot read, and a transaction may legitimately
    /// publish between two such calls (see the doc comment above
    /// `latestPlatterTimeline`).
    ///
    /// - Parameter now: The reference time for computing buffer age. Defaults
    ///   to `Date()`. Inject a fixed value in tests.
    public func makeValidationSnapshot(now: Date = Date()) -> TimecodeValidationSnapshot {
        // Captured once so every field below derives from the same
        // transaction generation — never a mix of a pre- and a
        // post-transaction value from two separately-locked reads.
        let output = currentOutputSnapshot()
        let config = captureConfigurationForOperation()
        let counters = output.counters
        let bufferAge = output.lastBufferReceivedAt.map { now.timeIntervalSince($0) }
        let hasRecent = bufferAge.map { $0 < TimecodeValidationSnapshot.staleThreshold } ?? false
        let diag = output.latestDiagnosis

        let classifiedStatus = TimecodeValidationSnapshot.classify(
            hasRecentBuffer: hasRecent,
            lastBufferAge: bufferAge,
            signalHealth: output.signalHealth,
            acceptedMotionSamples: counters.acceptedMotionSamples,
            droppedSilence: counters.droppedSilence,
            droppedClipped: counters.droppedClipped,
            droppedChannelFault: counters.droppedChannelFault,
            droppedWeakSignal: counters.droppedWeakSignal,
            droppedLowConfidence: counters.droppedLowConfidence
        )
        // Accepted decoder frames are not sufficient for control: identical
        // channels can produce a zero-velocity frame with unknown direction.
        // Keep validation fail-closed until quadrature establishes a usable
        // forward or backward direction.
        let status: TimecodeValidationStatus =
            classifiedStatus == .usablePrototypeControl && output.currentDirection == .unknown
            ? .receivingButNoDecode
            : classifiedStatus

#if DEBUG
        let recordedSamples = prototypeRecorder.acceptedSampleCount
#else
        let recordedSamples = 0
#endif

        let cls = output.latestClassification

        // In diagnosticsOnly mode the decoder is never called by design.
        // Only override .receivingButNoDecode — the status that means "healthy
        // signal, nothing decoded."  Unhealthy statuses (noSignal, clipped,
        // channelFault) must pass through so the UI reflects actual signal
        // quality rather than masking faults as "receiving."
        let finalStatus: TimecodeValidationStatus = (config.mode == .diagnosticsOnly && status == .receivingButNoDecode)
            ? .diagnosticsOnlyReceiving
            : status

#if ENABLE_TIMECODE_LIVE_TAP
        let adapterDiagnostic = TimecodeCMSampleBufferAdapter.lastDiagnostic
        let ingress = liveIngressDiagnostics
        let ingressAge = ingress.latestReceivedAt.map {
            String(format: "%.1fms", max(0, now.timeIntervalSince($0)) * 1_000)
        } ?? "n/a"
        let captureDeviceDebugInfo = TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo
            + " | DVS pipeline ingress: received=\(ingress.totalReceived)"
            + " dropped=\(ingress.totalDroppedForLatency)"
            + " pending=\(ingress.pendingBuffers)/\(ingress.pendingFrames)f"
            + " age=\(ingressAge)"
#else
        let adapterDiagnostic = ""
        let captureDeviceDebugInfo = ""
#endif

        return TimecodeValidationSnapshot(
            mode: config.mode.rawValue,
            liveTapEnabled: config.liveTapEnabled,
            hasRecentBuffer: hasRecent,
            lastBufferAge: bufferAge,
            signalHealth: output.signalHealth,
            leftRMS: diag?.leftRMS ?? 0,
            rightRMS: diag?.rightRMS ?? 0,
            leftPeak: diag?.leftPeak ?? 0,
            rightPeak: diag?.rightPeak ?? 0,
            decodedDirection: output.currentDirection.rawValue,
            decodedRate: output.currentRate,
            decoderConfidence: counters.averageConfidence,
            invertDirectionActive: config.invertDirection,
            acceptedMotionSamples: counters.acceptedMotionSamples,
            recordedSamples: recordedSamples,
            droppedSilence: counters.droppedSilence,
            droppedClipped: counters.droppedClipped,
            droppedChannelFault: counters.droppedChannelFault,
            droppedWeakSignal: counters.droppedWeakSignal,
            droppedLowConfidence: counters.droppedLowConfidence,
            directionChanges: counters.directionChanges,
            maxAbsRate: counters.maxAbsRate,
            averageConfidence: counters.averageConfidence,
            lastDropReason: counters.lastDropReason,
            sourceLabel: counters.sourceLabel,
            smoothedRate: counters.smoothedRate,
            smoothingActive: counters.smoothingActive,
            rejectedSpikeCount: counters.rejectedSpikeCount,
            heldDropoutCount: counters.heldDropoutCount,
            longDropoutCount: counters.longDropoutCount,
            lastSpikeReason: counters.lastSpikeReason,
            lastDropoutDuration: counters.lastDropoutDuration,
            maxAbsSmoothedRate: counters.maxAbsSmoothedRate,
            adapterDiagnostic: adapterDiagnostic,
            captureDeviceDebugInfo: captureDeviceDebugInfo,
            signalClass: cls?.signalClass.rawValue ?? SignalClass.unknown.rawValue,
            channelCorrelation: cls?.channelCorrelation,
            zcrFrequencyEstimateLeft: cls?.zcrFrequencyEstimateLeft,
            zcrFrequencyEstimateRight: cls?.zcrFrequencyEstimateRight,
            zeroCrossingRateLeft: cls?.zeroCrossingRateLeft ?? 0,
            zeroCrossingRateRight: cls?.zeroCrossingRateRight ?? 0,
            estimatedPhaseOffset: cls?.estimatedPhaseOffset,
            isQuadratureLike: cls?.isQuadratureLike ?? false,
            isFrequencyDisparate: cls?.isFrequencyDisparate ?? false,
            decoderRejectionNote: cls?.decoderRejectionNote ?? "",
            classificationSampleRate: cls?.classificationSampleRate ?? 0,
            minConfidenceRuntime: counters.minConfidenceRuntime,
            stabilityMinConfidenceRuntime: counters.stabilityMinConfidenceRuntime,
            decodedFrameCount: counters.decodedFrameCount,
            preFilterFrameCount: counters.preFilterFrameCount,
            postFilterFrameCount: counters.postFilterFrameCount,
            frameConfidenceMin: counters.frameConfidenceMin,
            frameConfidenceMax: counters.frameConfidenceMax,
            framesAboveMinConfidence: counters.framesAboveMinConfidence,
            framesBelowMinConfidence: counters.framesBelowMinConfidence,
            lowConfidenceRejectCount: counters.lowConfidenceRejectCount,
            rateSpikeRejectCount: counters.rateSpikeRejectCount,
            firstRejectReasonThisFlush: counters.firstRejectReasonThisFlush,
            rawDecodeTrace: counters.rawDecodeTrace,
            calibratedTrace: counters.calibratedTrace,
            validationStatus: finalStatus
        )
    }

    // MARK: - Reset

    /// Reset all accumulated state, counters, and published output.
    public func reset() {
        processingLock.lock()
        let state = OutputState()
        defer {
            let changed = swapPublishedOutput(state)
            processingLock.unlock()
            if changed { sendChangeNotification() }
        }

        lock.lock()
        accumulatedStereoInputs.removeAll(keepingCapacity: true)
        pendingLiveStereoInputs.removeAll(keepingCapacity: true)
        pendingLiveFrameCount = 0
        pendingLiveReceivedCount = 0
        totalLiveReceivedCount = 0
        totalLiveDroppedForLatencyCount = 0
        latestLiveBufferReceivedAt = nil
        latestAudioInputEndRelativeTime = nil
        latestAudioInputReceivedAt = nil
        accumulatedAudioFrameCount = 0
        lock.unlock()
        diagnosticsTap.reset()
        decodeSessionStartDate = Date()
        pendingDiagnosticsBufferCount = 0
        lastDiagnosticsPublishAudioTime = -.infinity
        stabilityFilterState = TimecodeStabilityFilterState()
        cumulativePlatterPosition = 0
        // `state` is already the all-defaults `OutputState()` seeded above —
        // reset publishes one complete, fully-defaulted snapshot rather than
        // clearing fields one at a time.
    }

    /// Reset only the debug counters (not calibration or mode).
    public func resetCounters() {
        processingLock.lock()
        var state = currentOutputSnapshot()
        defer {
            let changed = swapPublishedOutput(state)
            processingLock.unlock()
            if changed { sendChangeNotification() }
        }

        state.counters = TimecodeControlCounters()
        state.lastDropReason = nil
    }

    // MARK: - Private helpers

    /// A decode flush updates a coherent set of related fields. Publishing
    /// every assignment separately makes SwiftUI re-enter the same view
    /// graph repeatedly while the flush is still applying its result.
    /// Each transactional method instead computes one fully-formed
    /// `OutputState`, swaps it in atomically via `swapPublishedOutput(_:)`
    /// (which reports whether anything actually changed), releases
    /// `processingLock`, and only *then* — with neither `outputLock` nor
    /// `processingLock` held — calls this method once, if that swap found
    /// a real change. `objectWillChange` must never be delivered while a
    /// lock is held.
    ///
    /// Used by every transactional method EXCEPT `flushDecode()` — mode
    /// changes, calibration batches, and resets are discrete, infrequent,
    /// user/session-driven operations that should always notify
    /// immediately. `flushDecode()` alone runs at the ~60 Hz DVS
    /// control-worker rate and uses the separate, coalesced
    /// `sendCoalescedFlushChangeNotification()` below instead — see its
    /// doc comment for why that one specific path needs throttling and
    /// this one does not.
    private func sendChangeNotification() {
        // Hardware-verification instrumentation: a unique identity per
        // publish call site, immediately before `objectWillChange.send()`,
        // so a live session's console log can be correlated directly
        // against "Modifying state during view update" — grep both for
        // `[SwiftUIStateGuard]`. Cheap (main-thread only, never the
        // realtime audio/decode path) and not gated behind
        // SCRATCHLAB_DVS_TRACE since it's needed precisely when tracing a
        // *rendering* problem, not an audio one.
        print("[SwiftUIStateGuard] publish · source=TimecodeControlPipeline.sendChangeNotification thread=\(Thread.isMainThread ? "main" : "background") time=\(String(format: "%.6f", CACurrentMediaTime()))")
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    /// Real monotonic clock by default; injectable so tests can pin
    /// elapsed time deterministically (see `init`).
    private let notificationClock: () -> TimeInterval

    /// Dedicated to the coalescing state below only — never held while
    /// calling into any other method on this type, and nothing else on
    /// this type ever acquires it. Kept fully independent of
    /// `configurationLock`/`outputLock`/`processingLock`/`lock` so this
    /// UI-notification concern can never interact with their carefully
    /// ordered locking (see the doc comments on `mode`'s setter and
    /// `captureConfigurationForOperation()`).
    private let flushChangeNotificationLock = NSLock()
    private var lastFlushChangeNotificationUptime: TimeInterval = -.infinity
    private var flushChangeNotificationFlushScheduled = false

    /// Caps how often `flushDecode()` *tries* to deliver `objectWillChange`,
    /// down from every ~60 Hz tick to at most 20/s. This alone does NOT
    /// eliminate "Modifying state during view update" — a hardware session
    /// after this coalescing landed still showed the warning, just in
    /// smaller, ~20 Hz-periodic clusters instead of a continuous 60 Hz
    /// stream (see `[DVS-TRACE:` correlation notes and
    /// `MacAnalyzerView`'s `@State`/ticker doc comment, which is the actual
    /// fix: this pipeline is no longer observed by any SwiftUI view
    /// directly — `MacAnalyzerView`, `TimecodeControlCard`, and
    /// `DVSControlVinylPanel` all read it as plain state and re-render on
    /// their own bounded, main-actor-only timers instead). What coalescing
    /// here still legitimately provides: it keeps `objectWillChange` traffic
    /// low for any FUTURE observer of this object, and bounds the delay
    /// before the diagnostics recorder in `DVSLiveLogger`-style consumers
    /// see a change. It is a supporting mitigation, not the fix for the
    /// rendering warning.
    ///
    /// This governs only the UI *notification* — every reader of this
    /// pipeline's actual control data (`currentDirection`, `currentRate`,
    /// `latestPlatterTimeline`, `counters`, …, and
    /// `TimecodePlaybackBridge.evaluate(pipeline:)`, which drives DVS
    /// playback) reads those plain, lock-protected properties directly,
    /// not through Combine/`objectWillChange`. Throttling how often
    /// SwiftUI is *told to re-render* therefore cannot add any latency to
    /// DVS control or audio scheduling — the underlying state is already
    /// fully up to date and lock-protected the instant
    /// `swapPublishedOutput` returns, on every single flush, unthrottled;
    /// only the "please redraw" signal is coalesced.
    private static let flushChangeNotificationMinInterval: TimeInterval = 1.0 / 20.0

    private func sendCoalescedFlushChangeNotification() {
        let now = notificationClock()
        flushChangeNotificationLock.lock()
        let elapsed = now - lastFlushChangeNotificationUptime
        if elapsed >= Self.flushChangeNotificationMinInterval {
            lastFlushChangeNotificationUptime = now
            flushChangeNotificationLock.unlock()
            sendChangeNotification()
            return
        }
        guard !flushChangeNotificationFlushScheduled else {
            flushChangeNotificationLock.unlock()
            return
        }
        flushChangeNotificationFlushScheduled = true
        let delay = Self.flushChangeNotificationMinInterval - elapsed
        flushChangeNotificationLock.unlock()

        // Deliberately NOT `Timer`/a repeating source: this is a single
        // one-shot flush of whatever the latest state is by the time it
        // fires, not a recurring UI tick — normal DVS motion re-enters
        // `sendCoalescedFlushChangeNotification()` on its own well before
        // this fires and finds `elapsed >= flushChangeNotificationMinInterval`
        // already true, so the explicit timer only matters for the tail
        // end of a gesture (the very last change before motion stops),
        // ensuring the UI still reflects it instead of staying stuck on a
        // throttled-away intermediate state.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.flushChangeNotificationLock.lock()
            self.lastFlushChangeNotificationUptime = self.notificationClock()
            self.flushChangeNotificationFlushScheduled = false
            self.flushChangeNotificationLock.unlock()
            print("[SwiftUIStateGuard] publish · source=TimecodeControlPipeline.sendCoalescedFlushChangeNotification.tailFlush thread=main time=\(String(format: "%.6f", CACurrentMediaTime()))")
            self.objectWillChange.send()
        }
    }

    private func runDiagnostics(
        into state: inout OutputState,
        left: [Float],
        right: [Float],
        sampleRate: Double,
        hostTime: UInt64?,
        frameCount: Int?,
        bufferIncrement: Int,
        mode: TimecodeControlMode
    ) {
        // Feed internal tap for diagnostics display
        diagnosticsTap.push(
            samplesLeft: left,
            samplesRight: right,
            hostTime: hostTime,
            frameCount: frameCount ?? 0
        )
        _ = diagnosticsTap.drain()
        let diagnosis = diagnosticsTap.diagnose(with: diagnosticsEngine)
        state.latestDiagnosis = diagnosis
        state.signalHealth = diagnosis.health

        // Batch 13: classify signal modulation from raw samples
        let classification = diagnosticsEngine.classifySignal(
            left: left,
            right: right,
            sampleRate: sampleRate,
            health: diagnosis.health,
            isStereo: diagnosis.isStereo
        )
        state.latestClassification = classification

        var c = state.counters
        c.totalBuffersReceived += bufferIncrement
        c.signalHealth = diagnosis.health.rawValue

        // Drop counters represent decoder-derived drops and must only increment
        // when the decoder actually ran.  In diagnosticsOnly mode no decoder
        // runs, so incrementing would fabricate phantom drop evidence.
        if mode == .controlPrototype {
            if diagnosis.isSilent {
                c.droppedSilence += 1
                c.lastDropReason = TimecodeDropoutReason.silence.rawValue
            }
            if diagnosis.isClipping {
                c.droppedClipped += 1
                c.lastDropReason = TimecodeDropoutReason.clipped.rawValue
            }
            if diagnosis.isChannelImbalanced || diagnosis.isMonoSuspect {
                c.droppedChannelFault += 1
                c.lastDropReason = TimecodeDropoutReason.channelFault.rawValue
            }
        }

        state.counters = c
    }

    private func publishPendingDiagnosticsBufferCount(into state: inout OutputState) {
        guard pendingDiagnosticsBufferCount > 0 else { return }
        var c = state.counters
        c.totalBuffersReceived += pendingDiagnosticsBufferCount
        state.counters = c
        pendingDiagnosticsBufferCount = 0
    }

    private func accumulateStereoInput(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        hostTime: UInt64?,
        frameCount: Int?,
        channel: TimecodeInputChannel
    ) -> TimeInterval {
        let safeSampleRate = sampleRate > 0 ? sampleRate : diagnosticsTap.sampleRate
        let frames = max(0, frameCount ?? min(left.count, right.count))
        let (effectiveLeft, effectiveRight) = applyChannelSelection(left: left, right: right, channel: channel)

        lock.lock()
        let relativeTime = Double(accumulatedAudioFrameCount) / safeSampleRate
        accumulatedAudioFrameCount += Int64(frames)
        latestAudioInputEndRelativeTime = relativeTime + Double(frames) / safeSampleRate
        latestAudioInputReceivedAt = Date()
        let input = TimecodePhaseDecoder.StereoInput(
            left: effectiveLeft,
            right: effectiveRight,
            sampleRate: safeSampleRate,
            hostTime: hostTime,
            relativeTime: relativeTime
        )
        accumulatedStereoInputs.append(input)
        lock.unlock()

        return relativeTime
    }

    private func applyChannelSelection(
        left: [Float],
        right: [Float],
        channel: TimecodeInputChannel
    ) -> ([Float], [Float]) {
        switch channel {
        case .stereo:
            return (left, right)
        case .left:
            // Duplicate left channel — no phase delta, no motion.
            // Useful for per-channel diagnostics only.
            return (left, left)
        case .right:
            // Duplicate right channel — no phase delta, no motion.
            return (right, right)
        }
    }
}

// MARK: - TimecodeDirection + inversion

private extension TimecodeDirection {
    /// Return the opposite direction.
    var inverted: TimecodeDirection {
        switch self {
        case .forward:  return .backward
        case .backward: return .forward
        case .unknown:  return .unknown
        }
    }
}
