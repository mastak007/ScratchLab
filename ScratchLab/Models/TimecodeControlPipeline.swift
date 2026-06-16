import Foundation
import Combine

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
    @Published public var liveTapEnabled: Bool = false

    /// Current timecode control mode. Default is `.disabled`.
    @Published public var mode: TimecodeControlMode = .disabled {
        didSet {
            if mode != oldValue, mode != .controlPrototype {
                // Reset decode accumulator on mode change away from control
                accumulatedStereoInputs.removeAll(keepingCapacity: true)
            }
        }
    }

    // MARK: - Calibration

    /// When true, the sign of all position deltas is flipped before
    /// producing platter output.
    @Published public var invertDirection: Bool = false

    /// Multiplier applied to position deltas (and velocities). 1.0 = no
    /// scaling, 0.5 = half speed, 2.0 = double speed.
    @Published public var rateScale: Double = 1.0

    /// Which channel(s) of the stereo input to use.
    /// Only `.stereo` produces meaningful phase-delta output for decoding;
    /// `.left` and `.right` are provided for channel-level diagnostics.
    @Published public var inputChannel: TimecodeInputChannel = .stereo

    /// Minimum confidence for a decoded frame to be included in platter
    /// output.
    @Published public var minConfidence: Double = 0.3

    /// Maximum absolute velocity allowed in position-units per second.
    /// Velocities exceeding this are clamped.
    @Published public var maxRate: Double = 5.0

    /// RMS below this value is considered silence by the signal
    /// diagnostics stage.
    @Published public var signalThresholdRMS: Float = 0.001

    // MARK: - Published output

    /// The most recent platter position timeline produced by the pipeline,
    /// or `nil` when no trusted motion has been decoded.
    @Published public private(set) var latestPlatterTimeline: PlatterPositionTimeline?

    /// The most recent raw decode result, if any.
    @Published public private(set) var latestDecodeResult: TimecodeDecodeResult?

    /// The most recent signal diagnosis.
    @Published public private(set) var latestDiagnosis: TimecodeSignalDiagnostics.Diagnosis?

    /// Aggregate debug counters.
    @Published public private(set) var counters: TimecodeControlCounters = .init()

    /// Current decoded direction.
    @Published public private(set) var currentDirection: TimecodeDirection = .unknown

    /// Current decoded rate in position-units per second.
    @Published public private(set) var currentRate: Double = 0

    /// Reason for the most recent dropout, or `nil` when the last decode
    /// was successful.
    @Published public private(set) var lastDropReason: TimecodeDropoutReason?

    /// Aggregate signal health from the most recent diagnostics pass.
    @Published public private(set) var signalHealth: SignalHealth = .noSignal

    /// Wall-clock time of the most recently received live audio buffer,
    /// or `nil` when no buffer has been received since the last reset.
    @Published public private(set) var lastBufferReceivedAt: Date?

    /// The internal diagnostics tap, exposed for UI binding (e.g.
    /// `TimecodeInputStatusCard`). Updated on each `pushStereoBuffer()`
    /// call.
    public let diagnosticsTap: TimecodeInputTap

    // MARK: - Internal state

    private let lock = NSLock()
    private var accumulatedStereoInputs: [TimecodePhaseDecoder.StereoInput] = []
    private var decodeSessionStartDate: Date = Date()
    private let diagnosticsEngine = TimecodeSignalDiagnostics()
    private let stabilityFilter = TimecodeMotionStabilityFilter()
    private var stabilityFilterState = TimecodeStabilityFilterState()

    /// Internal decoder instance. Recreated when calibration changes
    /// affect decoder configuration.
    private var decoder: TimecodePhaseDecoder {
        TimecodePhaseDecoder(
            carrierFrequency: 1000,
            silenceThresholdRMS: signalThresholdRMS,
            clippingThreshold: 0.999,
            minCorrelationMagnitude: 0.1,
            minConfidence: 0.3
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

    public init(sampleRate: Double = 44100, channelCount: Int = 2) {
        self.diagnosticsTap = TimecodeInputTap(sampleRate: sampleRate, channelCount: channelCount)
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
        hostTime: UInt64? = nil
    ) {
        switch mode {
        case .disabled:
            // Silently drop — no diagnostics, no accumulation, no motion.
            return

        case .diagnosticsOnly:
            lastBufferReceivedAt = Date()
            runDiagnostics(left: left, right: right, sampleRate: sampleRate, hostTime: hostTime)
            // Do NOT accumulate or decode.

        case .controlPrototype:
            lastBufferReceivedAt = Date()
            runDiagnostics(left: left, right: right, sampleRate: sampleRate, hostTime: hostTime)
            accumulateStereoInput(left: left, right: right, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    // MARK: - Decode flush

    /// Run the decoder → calibration → adapter chain on all accumulated
    /// stereo buffers, publish the resulting platter timeline, and clear
    /// the accumulator.
    ///
    /// Has no effect in `.disabled` or `.diagnosticsOnly` modes (the
    /// accumulator is always empty in those modes).
    @discardableResult
    public func flushDecode() -> PlatterPositionTimeline? {
        lock.lock()
        let inputs = accumulatedStereoInputs
        accumulatedStereoInputs.removeAll(keepingCapacity: true)
        lock.unlock()

        guard mode == .controlPrototype else {
            return nil
        }

        // When no buffers arrived this window the decoder is skipped, but the
        // stability filter must still run so the dropout clock advances.
        guard !inputs.isEmpty else {
            let flushTime = Date().timeIntervalSince(decodeSessionStartDate)
            let filterResult = stabilityFilter.filter(
                frames: [],
                state: stabilityFilterState,
                flushRelativeTime: flushTime
            )
            stabilityFilterState = filterResult.state
            var c = counters
            c.smoothedRate = filterResult.metrics.smoothedRate
            c.smoothingActive = false
            c.heldDropoutCount += filterResult.metrics.heldDropoutCount
            c.longDropoutCount += filterResult.metrics.longDropoutCount
            c.lastDropoutDuration = filterResult.metrics.lastDropoutDuration
            counters = c
            return nil
        }

        // Run decoder
        let decoderInstance = decoder
        let decodeResult = decoderInstance.decode(inputs)

        // Transfer decoder counters into pipeline counters
        var c = counters
        c.decodedSamples += decodeResult.counters.decodedSamples
        c.droppedSilence += decodeResult.counters.droppedSilence
        c.droppedClipped += decodeResult.counters.droppedClipped
        c.directionChanges += decodeResult.counters.directionChanges
        c.signalHealth = decodeResult.signalHealth.rawValue
        signalHealth = decodeResult.signalHealth

        // Record per-decode-window drop reason from the decoder
        if decodeResult.frames.isEmpty, let reason = decodeResult.dropoutReason {
            c.lastDropReason = reason.rawValue
            lastDropReason = reason
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
        if !calibratedFrames.isEmpty && (rateScale != 1.0 || invertDirection) {
            var cumulativePosition: Double = 0
            for i in 0..<calibratedFrames.count {
                var frame = calibratedFrames[i]
                let sign: Double = invertDirection ? -1.0 : 1.0
                let scaledDelta = frame.deltaPosition * rateScale * sign
                let scaledVelocity = frame.velocity * rateScale * sign
                cumulativePosition += scaledDelta
                frame = TimecodeDecodedFrame(
                    hostTime: frame.hostTime,
                    relativeTime: frame.relativeTime,
                    position: cumulativePosition,
                    deltaPosition: scaledDelta,
                    velocity: scaledVelocity,
                    direction: invertDirection ? frame.direction.inverted : frame.direction,
                    confidence: frame.confidence
                )
                calibratedFrames[i] = frame
            }
        }

        // Apply stability filter (runs even on empty batch to track dropout timing)
        let flushTime = inputs.last?.relativeTime ?? 0
        let filterResult = stabilityFilter.filter(
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

        // No trusted output (decoder empty, spike-rejected, or dropout)?
        guard !filterResult.accepted.isEmpty else {
            if filterResult.metrics.rejectedSpikeCount > 0 && !decodeResult.frames.isEmpty {
                c.lastDropReason = filterResult.metrics.lastSpikeReason
            }
            c.averageConfidence = decodeResult.averageConfidence
            counters = c
            latestPlatterTimeline = nil
            currentDirection = .unknown
            currentRate = 0
#if DEBUG
            let dropReason = decodeResult.dropoutReason?.rawValue
                ?? (filterResult.metrics.rejectedSpikeCount > 0 ? "rejected_spike" : "no_trusted_frames")
            prototypeRecorder.recordDrop(reason: dropReason)
#endif
            return nil
        }

        // Build adapter with current calibration thresholds
        let adapter = TimecodePlatterAdapter(
            minConfidence: minConfidence,
            maxRate: maxRate,
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
        latestDecodeResult = stabilizedResult

        // Update current direction/rate from last accepted (stabilized) frame
        if let lastFrame = filterResult.accepted.last {
            currentDirection = lastFrame.direction
            currentRate = lastFrame.velocity
        }
        c.currentDirection = currentDirection.rawValue
        c.currentRate = currentRate
        c.maxAbsRate = max(c.maxAbsRate, abs(currentRate))

        // Adapt to platter timeline
        let timeline = adapter.adapt(stabilizedResult)
        latestPlatterTimeline = timeline

        // Update counters
        c.acceptedMotionSamples += timeline?.samples.count ?? 0
        c.droppedLowConfidence += max(0, filterResult.accepted.count - (timeline?.samples.count ?? 0))
        c.averageConfidence = decodeResult.averageConfidence
        c.lastDropReason = ""
        c.signalHealth = decodeResult.signalHealth.rawValue
        lastDropReason = nil
        counters = c

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
    /// - Parameter now: The reference time for computing buffer age. Defaults
    ///   to `Date()`. Inject a fixed value in tests.
    public func makeValidationSnapshot(now: Date = Date()) -> TimecodeValidationSnapshot {
        let bufferAge = lastBufferReceivedAt.map { now.timeIntervalSince($0) }
        let hasRecent = bufferAge.map { $0 < TimecodeValidationSnapshot.staleThreshold } ?? false
        let diag = latestDiagnosis

        let status = TimecodeValidationSnapshot.classify(
            hasRecentBuffer: hasRecent,
            lastBufferAge: bufferAge,
            signalHealth: signalHealth,
            acceptedMotionSamples: counters.acceptedMotionSamples,
            droppedSilence: counters.droppedSilence,
            droppedClipped: counters.droppedClipped,
            droppedChannelFault: counters.droppedChannelFault,
            droppedWeakSignal: counters.droppedWeakSignal,
            droppedLowConfidence: counters.droppedLowConfidence
        )

#if DEBUG
        let recordedSamples = prototypeRecorder.acceptedSampleCount
#else
        let recordedSamples = 0
#endif

        return TimecodeValidationSnapshot(
            mode: mode.rawValue,
            liveTapEnabled: liveTapEnabled,
            hasRecentBuffer: hasRecent,
            lastBufferAge: bufferAge,
            signalHealth: signalHealth,
            leftRMS: diag?.leftRMS ?? 0,
            rightRMS: diag?.rightRMS ?? 0,
            leftPeak: diag?.leftPeak ?? 0,
            rightPeak: diag?.rightPeak ?? 0,
            decodedDirection: currentDirection.rawValue,
            decodedRate: currentRate,
            decoderConfidence: counters.averageConfidence,
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
            validationStatus: status
        )
    }

    // MARK: - Reset

    /// Reset all accumulated state, counters, and published output.
    public func reset() {
        lock.lock()
        accumulatedStereoInputs.removeAll(keepingCapacity: true)
        lock.unlock()
        diagnosticsTap.reset()
        decodeSessionStartDate = Date()
        latestPlatterTimeline = nil
        latestDecodeResult = nil
        latestDiagnosis = nil
        counters = TimecodeControlCounters()
        currentDirection = .unknown
        currentRate = 0
        lastDropReason = nil
        signalHealth = .noSignal
        lastBufferReceivedAt = nil
        stabilityFilterState = TimecodeStabilityFilterState()
    }

    /// Reset only the debug counters (not calibration or mode).
    public func resetCounters() {
        counters = TimecodeControlCounters()
        lastDropReason = nil
    }

    // MARK: - Private helpers

    private func runDiagnostics(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        hostTime: UInt64?
    ) {
        // Feed internal tap for diagnostics display
        diagnosticsTap.push(
            samplesLeft: left,
            samplesRight: right,
            hostTime: hostTime
        )
        _ = diagnosticsTap.drain()
        let diagnosis = diagnosticsTap.diagnose(with: diagnosticsEngine)
        latestDiagnosis = diagnosis
        signalHealth = diagnosis.health

        var c = counters
        c.totalBuffersReceived += 1
        c.signalHealth = diagnosis.health.rawValue

        // Track drops based on diagnostics
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

        counters = c
    }

    private func accumulateStereoInput(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        hostTime: UInt64?
    ) {
        let now = Date()
        let relativeTime = now.timeIntervalSince(decodeSessionStartDate)

        let (effectiveLeft, effectiveRight) = applyChannelSelection(left: left, right: right)

        let input = TimecodePhaseDecoder.StereoInput(
            left: effectiveLeft,
            right: effectiveRight,
            sampleRate: sampleRate,
            hostTime: hostTime,
            relativeTime: relativeTime
        )

        lock.lock()
        accumulatedStereoInputs.append(input)
        lock.unlock()
    }

    private func applyChannelSelection(left: [Float], right: [Float]) -> ([Float], [Float]) {
        switch inputChannel {
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
