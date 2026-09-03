import Foundation
import AVFoundation
import Vision
import SwiftUI
import AppKit
import CoreAudio
import CoreMedia
import AudioToolbox
import CoreMIDI
import Accelerate
import CoreImage
import ImageIO

private enum ScratchLabDesktopDefaultsKey {
    static let selectedAudioDeviceUniqueID = "scratchlab.mac.selectedAudioDeviceUniqueID"
    static let selectedAudioDeviceWasExplicit = "scratchlab.mac.selectedAudioDeviceWasExplicit"
    static let selectedVideoDeviceUniqueID = "scratchlab.mac.selectedVideoDeviceUniqueID"
    static let calibrationLocked = "scratchlab.mac.calibrationLocked"
    static let practiceViewEnabled = "scratchlab.mac.practiceViewEnabled"
    static let useDJPerspective = "scratchlab.mac.useDJPerspective"
    static let manualRigGuideEnabled = "scratchlab.mac.manualRigGuideEnabled"
    static let rigHorizontalOffset = "scratchlab.mac.rigHorizontalOffset"
    static let rigVerticalOffset = "scratchlab.mac.rigVerticalOffset"
    static let rigWidthScale = "scratchlab.mac.rigWidthScale"
    static let rigHeightScale = "scratchlab.mac.rigHeightScale"
    static let mixerWidthRatio = "scratchlab.mac.mixerWidthRatio"
    static let zoneAdjustmentsData = "scratchlab.mac.zoneAdjustmentsData"
    static let crossfaderMIDIMapping = "scratchlab.mac.crossfaderMIDIMapping"
    static let selectedMIDIInputSourceID = "scratchlab.mac.selectedMIDIInputSourceID"
}

/// Converts a `TimecodePlaybackDrive`'s rate + direction into the CC6-step
/// domain `ScratchSamplePlaybackController.positionDidChange` expects.
///
/// `TimecodePlaybackDrive.rate` is a normalized rate where `1.0` corresponds
/// to nominal 33⅓ RPM — the same convention `ScratchSamplePlaybackController`
/// already assumes when it derives `framesPerStep` from `stepsPerRevolution`
/// at that RPM. Integrating rate over elapsed time in that shared convention
/// yields a step count directly comparable to real CC6 ring-counter steps,
/// so DVS-driven and MIDI-driven grains behave the same for the same
/// platter speed.
struct TimecodeDriveStepConverter {
    /// Rane ONE MKII CC6 ring-counter resolution (steps per platter revolution).
    private static let stepsPerRevolution: Double = 3932
    /// Nominal 33⅓ RPM, expressed as seconds per revolution.
    private static let vinylSecondsPerRevolution: Double = 60.0 / (100.0 / 3.0)
    private static let stepsPerSecondAtRate1: Double = stepsPerRevolution / vinylSecondsPerRevolution

    private var accumulatedSteps: Double = 0

    /// Listening-fix #2 (Option 2, uncommitted): continuous fractional
    /// cumulative steps. Returns the running fractional step total so the
    /// scheduler can emit a grain EVERY tick from real (sub-step) motion —
    /// whole-step quantization previously batch-played near-stop motion
    /// (up to ~154ms of audio lag) or skipped it (13ms gap clicks).
    mutating func continuousSteps(
        forRate rate: Double,
        elapsed: TimeInterval
    ) -> Double {
        accumulatedSteps += rate * Self.stepsPerSecondAtRate1 * elapsed
        return accumulatedSteps
    }

    mutating func steps(
        forRate rate: Double,
        direction: TimecodeDirection,
        elapsed: TimeInterval
    ) -> (steps: Int, direction: ScratchPlatterDirection?) {
        accumulatedSteps += rate * Self.stepsPerSecondAtRate1 * elapsed
        let mappedDirection: ScratchPlatterDirection?
        switch direction {
        case .forward:  mappedDirection = .forward
        case .backward: mappedDirection = .backward
        case .unknown:  mappedDirection = nil
        }
        return (Int(accumulatedSteps.rounded()), mappedDirection)
    }
}

enum LowLatencyTimecodeTapFormatChoice: Equatable {
    case unavailable
    case explicitOutput
    case explicitHardwareInput
}

func lowLatencyTimecodeTapFormatChoice(
    hardwareChannelCount: Int,
    hardwareSampleRate: Double,
    outputChannelCount: Int,
    outputSampleRate: Double
) -> LowLatencyTimecodeTapFormatChoice {
    guard hardwareChannelCount >= 2,
          hardwareSampleRate.isFinite,
          hardwareSampleRate > 0 else {
        return .unavailable
    }
    if outputChannelCount >= hardwareChannelCount,
       outputSampleRate.isFinite,
       outputSampleRate > 0 {
        return .explicitOutput
    }
    return .explicitHardwareInput
}

#if DEBUG && ENABLE_TIMECODE_LIVE_TAP
func lowLatencyTimecodeTapHasRequiredChannels(
    actualChannelCount: Int,
    selection: TimecodeCMSampleBufferAdapter.ChannelPairSelection
) -> Bool {
    let requiredChannelCount: Int
    switch selection {
    case .auto:
        requiredChannelCount = 2
    case .pair(let startChannel):
        requiredChannelCount = startChannel + 2
    }
    return actualChannelCount >= requiredChannelCount
}
#endif

struct LowLatencyTimecodeTapHeartbeat: Equatable {
    static let minimumFreshnessInterval: TimeInterval = 0.10
    static let maximumFreshnessInterval: TimeInterval = 0.30
    static let callbackDurationTolerance = 2.5

    private(set) var isInstalled = false
    private(set) var deviceUID = ""
    private(set) var lastCallbackUptime: TimeInterval?
    private(set) var callbackCount = 0
    private(set) var observedChannelCount = 0
    private(set) var observedFrameCount = 0
    private(set) var observedSampleRate: Double = 0
    private(set) var observedFormat = "none"
    private(set) var lastRejection = ""

    mutating func markInstalled(deviceUID: String) {
        isInstalled = true
        self.deviceUID = deviceUID
        lastCallbackUptime = nil
        callbackCount = 0
        observedChannelCount = 0
        observedFrameCount = 0
        observedSampleRate = 0
        observedFormat = "awaiting callback"
        lastRejection = ""
    }

    mutating func recordCallback(
        uptime: TimeInterval,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        format: String
    ) {
        lastCallbackUptime = uptime
        callbackCount += 1
        observedChannelCount = channelCount
        observedFrameCount = frameCount
        observedSampleRate = sampleRate
        observedFormat = format
        lastRejection = ""
    }

    mutating func recordRejection(_ reason: String) {
        lastRejection = reason
    }

    mutating func reset() {
        self = LowLatencyTimecodeTapHeartbeat()
    }

    var freshnessInterval: TimeInterval {
        guard observedFrameCount > 0, observedSampleRate > 0 else {
            return Self.minimumFreshnessInterval
        }
        let observedCallbackDuration =
            TimeInterval(observedFrameCount) / observedSampleRate
        return min(
            Self.maximumFreshnessInterval,
            max(
                Self.minimumFreshnessInterval,
                observedCallbackDuration * Self.callbackDurationTolerance
            )
        )
    }

    func isFresh(at uptime: TimeInterval) -> Bool {
        guard isInstalled, let lastCallbackUptime else { return false }
        let age = max(0, uptime - lastCallbackUptime)
        return age <= freshnessInterval
    }

    func diagnostic(at uptime: TimeInterval) -> String {
        let ageText = lastCallbackUptime.map {
            String(format: "%.1fms", max(0, uptime - $0) * 1_000)
        } ?? "never"
        let freshnessText = String(format: "%.1fms", freshnessInterval * 1_000)
        let route = isFresh(at: uptime) ? "AVAudioEngine" : "AVCapture fallback"
        let rejection = lastRejection.isEmpty ? "" : " rejection=\(lastRejection)"
        return "route=\(route) installed=\(isInstalled) callbacks=\(callbackCount)" +
            " age=\(ageText) budget=\(freshnessText)" +
            " observed=\(observedFormat),\(observedChannelCount)ch," +
            "\(observedFrameCount)f@\(Int(observedSampleRate))Hz\(rejection)"
    }
}

/// Read-only snapshot of the CoreAudio properties that govern the real I/O
/// buffer size an `AVAudioEngine` tap actually receives from a device —
/// `installTap(bufferSize:)` is only a request; the true delivered frame
/// count is whatever the HAL's current buffer configuration produces. Every
/// field is optional because a given device may not support every property
/// (some report no explicit range, some don't expose a nominal sample rate
/// via this call); `nil` means "device didn't answer", never a crash.
struct AudioDeviceBufferFrameSizeDiagnostic: Equatable {
    let currentBufferFrameSize: UInt32?
    let minimumBufferFrameSize: UInt32?
    let maximumBufferFrameSize: UInt32?
    let nominalSampleRate: Double?
    let safetyOffsetFrames: UInt32?
    let deviceLatencyFrames: UInt32?
}

/// Pure formatter — no CoreAudio calls, no state, safe to unit test with
/// hand-constructed values including the all-`nil` "device answered nothing"
/// case.
func formatAudioDeviceBufferDiagnostic(_ diagnostic: AudioDeviceBufferFrameSizeDiagnostic) -> String {
    func describe<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "unavailable"
    }
    return "bufferFrameSize=\(describe(diagnostic.currentBufferFrameSize))" +
        " range=[\(describe(diagnostic.minimumBufferFrameSize))...\(describe(diagnostic.maximumBufferFrameSize))]" +
        " nominalSampleRate=\(describe(diagnostic.nominalSampleRate))" +
        " safetyOffset=\(describe(diagnostic.safetyOffsetFrames))" +
        " deviceLatency=\(describe(diagnostic.deviceLatencyFrames))"
}

/// Defensive `Double` → `UInt32` conversion for `AudioValueRange` bounds.
/// CoreAudio can in principle report a NaN, infinite, negative, or
/// out-of-`UInt32`-range bound for a frame-count property; Swift's
/// `UInt32(Double)` traps on any of those rather than returning an error,
/// so every bound must be checked before converting — never assumed valid
/// just because the property read itself reported `noErr`.
func safeFrameCount(_ value: Double) -> UInt32? {
    guard value.isFinite, value >= 0, value <= Double(UInt32.max) else { return nil }
    return UInt32(value)
}

/// Pure marker replace-or-strip helper — no CoreAudio calls, no shared
/// state, safe to unit test directly against hand-built debug-info strings.
/// Strips any existing `" | HAL buffer: "` segment from `debugInfo` and,
/// only if `diagnostic` is non-`nil`, appends a freshly formatted one — so
/// repeated calls never duplicate the marker, and a `nil` diagnostic
/// (device switched, tap stopped/reset, or a bind that never completed)
/// correctly removes any stale prior device's numbers instead of leaving
/// them attached to debug info that no longer describes that device.
func applyingAudioDeviceBufferDiagnostic(
    to debugInfo: String,
    diagnostic: AudioDeviceBufferFrameSizeDiagnostic?
) -> String {
    let marker = " | HAL buffer: "
    let base = debugInfo.components(separatedBy: marker).first ?? debugInfo
    guard let diagnostic else { return base }
    return base + marker + formatAudioDeviceBufferDiagnostic(diagnostic)
}

// MARK: - Low-latency DVS sink-node ingress (Slice 2)
//
// Replaces `AVAudioNode.installTap` for the feature-gated low-latency DVS
// route with an `AVAudioSinkNode` render-quantum ingress path feeding the
// committed `TimecodeRealtimeIngressRing`/`TimecodeRealtimeIngressWorker`
// (Slice 1, `TimecodeRealtimeIngressRing.swift`). The ordinary
// `AVCaptureAudioDataOutput` capture path is untouched by any of this.

/// Every possible outcome of validating the audio format about to be used
/// for `AVAudioEngine.connect(_:to:format:)` between the input node and the
/// low-latency DVS sink node. Pure — no `AVAudioEngine`/hardware access — so
/// every case is directly testable. Checked once, at bind time, against
/// exactly what `TimecodeRealtimeIngressRing.publish` requires: Float32
/// samples, one non-interleaved buffer per channel, a finite positive
/// sample rate, and a channel count the ring's fixed configuration can
/// actually hold. Fails closed (any non-`.valid` case) rather than starting
/// the engine and discovering the mismatch per-callback.
enum LowLatencySinkFormatValidationOutcome: Equatable {
    case valid
    case rejectedUnsupportedCommonFormat
    case rejectedInterleavedFormat
    case rejectedInvalidSampleRate
    case rejectedChannelCountOutOfRange
}

func validateLowLatencySinkFormat(
    commonFormat: AVAudioCommonFormat,
    isInterleaved: Bool,
    sampleRate: Double,
    channelCount: Int,
    ringConfiguration: TimecodeRealtimeIngressRingConfiguration
) -> LowLatencySinkFormatValidationOutcome {
    guard commonFormat == .pcmFormatFloat32 else {
        return .rejectedUnsupportedCommonFormat
    }
    guard !isInterleaved else {
        return .rejectedInterleavedFormat
    }
    guard sampleRate.isFinite, sampleRate > 0 else {
        return .rejectedInvalidSampleRate
    }
    guard channelCount > 0,
          channelCount <= ringConfiguration.maximumChannelCount,
          channelCount <= Int(Int32.max) else {
        return .rejectedChannelCountOutOfRange
    }
    return .valid
}

/// Realtime-safe, allocation-free `Float64` → `Int64` conversion for
/// `AudioTimeStamp.mSampleTime`. `AudioTimeStampFlags.sampleTimeValid` only
/// promises the render call populated the field — it does not guarantee the
/// value is finite or exactly representable as `Int64`. Swift's
/// `Int64(Double)` initializer traps if the value is NaN, infinite, or
/// rounds (towards zero) outside `Int64`'s range, so every value must be
/// checked before converting, exactly like `safeFrameCount(_:)` above.
/// `9_223_372_036_854_775_808.0` is `2^63`, exactly representable as
/// `Double`; anything in `[-2^63, 2^63)` truncates to a value inside
/// `Int64`'s representable range. Returns `nil` — never traps — for
/// anything outside that range.
func safeSampleTime(_ value: Float64) -> Int64? {
    guard value.isFinite,
          value >= -9_223_372_036_854_775_808.0,
          value < 9_223_372_036_854_775_808.0 else {
        return nil
    }
    return Int64(value)
}

/// Monotonically increasing across one `MacCaptureEngine` instance's
/// lifetime — never reused. Identifies one low-latency DVS sink-node
/// session (one bind-to-teardown cycle of `refreshLowLatencyTimecodeInput`/
/// `stopLowLatencyTimecodeInput`).
typealias LowLatencySinkSessionGeneration = UInt64

/// Bundles one low-latency DVS sink-node session's ring + worker + identity.
/// Deliberately holds no `AVAudioEngine`/`AVAudioSinkNode` reference — those
/// require real hardware to meaningfully exercise, so this type isolates
/// exactly the part of "session lifecycle" Slice 2 can prove
/// deterministically in a plain XCTest, with no hardware dependency:
///
/// - each session gets its own freshly allocated ring and worker;
/// - tearing a session down closes its ring to new writes and guarantees no
///   further consumer delivery once `tearDown()` returns (via
///   `TimecodeRealtimeIngressWorker.stop()`'s existing barrier);
/// - a stale, already-closed session's ring can never be confused with a
///   later session's ring, because they are always genuinely distinct
///   object instances tagged with distinct generations.
///
/// `MacCaptureEngine` is the only production caller; it additionally owns
/// the real `AVAudioSinkNode` whose realtime receiver block captures only
/// this session's `ring` directly (never `self`, never any other mutable
/// property) — so even a render callback somehow still in flight after this
/// session's `tearDown()` has begun can only ever publish into (or be
/// rejected by) *this* session's own ring, never a replacement session's.
final class LowLatencySinkSession {
    let generation: LowLatencySinkSessionGeneration
    let ring: TimecodeRealtimeIngressRing
    let worker: TimecodeRealtimeIngressWorker

    /// Fails only if `drainInterval` is invalid — see
    /// `TimecodeRealtimeIngressWorker.init?`. Never partially constructs: if
    /// the worker fails to initialize, the ring this session would have
    /// owned is simply discarded — never started, never referenced by any
    /// realtime callback.
    init?(
        generation: LowLatencySinkSessionGeneration,
        ringConfiguration: TimecodeRealtimeIngressRingConfiguration = .production,
        drainInterval: TimeInterval = 0.005,
        consumer: @escaping @Sendable (TimecodeRealtimeIngressSlotView) -> Void
    ) {
        let ring = TimecodeRealtimeIngressRing(configuration: ringConfiguration)
        guard let worker = TimecodeRealtimeIngressWorker(
            ring: ring,
            drainInterval: drainInterval,
            consumer: consumer
        ) else {
            return nil
        }
        self.generation = generation
        self.ring = ring
        self.worker = worker
    }

    /// Truthful, deterministic, idempotent teardown: closes the ring to new
    /// writes and synchronously guarantees no further consumer delivery once
    /// this call returns. Safe to call more than once.
    func tearDown() {
        worker.stop()
    }
}

/// Snapshot of the low-latency DVS sink ring's own producer/consumer
/// counters at the moment of a diagnostic publish — surfaces ring-full
/// drop-newest behavior honestly instead of silently discarding it.
struct LowLatencySinkRingDiagnostic: Equatable {
    let publishedCount: UInt64
    let droppedCount: UInt64
    let rejectedCount: UInt64
}

func formatLowLatencySinkRingDiagnostic(_ diagnostic: LowLatencySinkRingDiagnostic) -> String {
    "published=\(diagnostic.publishedCount) dropped=\(diagnostic.droppedCount)" +
        " rejected=\(diagnostic.rejectedCount)"
}

/// Pure marker replace-or-strip helper — mirrors
/// `applyingAudioDeviceBufferDiagnostic`'s pattern exactly, so repeated
/// publishes never duplicate the marker, and a `nil` diagnostic (no active
/// session) strips any stale prior session's counters.
func applyingLowLatencySinkRingDiagnostic(
    to debugInfo: String,
    diagnostic: LowLatencySinkRingDiagnostic?
) -> String {
    let marker = " | DVS sink ring: "
    let base = debugInfo.components(separatedBy: marker).first ?? debugInfo
    guard let diagnostic else { return base }
    return base + marker + formatLowLatencySinkRingDiagnostic(diagnostic)
}

/// Raw evidence of what the worker actually drained from the ring for the
/// most recent slot — updated on *every* delivery, whether or not adapter
/// conversion below succeeds. This exists specifically so real hardware
/// frame-count evidence stays visible even while adapter conversion is
/// failing (e.g. before the `AVAudioPCMBuffer`-construction fix landed,
/// `callbacks=0`/`observed=awaiting callback` left zero visibility into
/// what the sink node itself was actually receiving). Deliberately
/// independent of `LowLatencyTimecodeTapHeartbeat`: recording this must
/// never be confused with — or substitute for — the heartbeat's
/// `recordCallback`, which is the only thing allowed to mark the low-latency
/// route "fresh" and suppress the AVCapture fallback, and which must only
/// fire once full adapter conversion has actually succeeded.
struct LowLatencySinkWorkerObservationDiagnostic: Equatable {
    let frameCount: Int
    let channelCount: Int
    let sampleRate: Double
}

func formatLowLatencySinkWorkerObservationDiagnostic(
    _ diagnostic: LowLatencySinkWorkerObservationDiagnostic
) -> String {
    "\(diagnostic.frameCount)f@\(Int(diagnostic.sampleRate))Hz,\(diagnostic.channelCount)ch"
}

/// Pure marker replace-or-strip helper — mirrors the other diagnostic
/// helpers' pattern exactly.
func applyingLowLatencySinkWorkerObservationDiagnostic(
    to debugInfo: String,
    diagnostic: LowLatencySinkWorkerObservationDiagnostic?
) -> String {
    let marker = " | DVS sink observed: "
    let base = debugInfo.components(separatedBy: marker).first ?? debugInfo
    guard let diagnostic else { return base }
    return base + marker + formatLowLatencySinkWorkerObservationDiagnostic(diagnostic)
}

/// Every stage at which converting a drained ring slot into an
/// `AVAudioPCMBuffer` (for the existing, unmodified
/// `TimecodeCMSampleBufferAdapter.stereoSampleResult(fromPCMBuffer:hostTime:)`
/// entry point) can fail. Distinguishing these mattered in practice: the
/// first sink-node implementation reconstructed a *generic*
/// `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` from only
/// sample rate and channel count, which returns `nil` for channel counts
/// with no standard layout (reproduced deterministically for 14 channels —
/// confirmed via a standalone script, not guessed) — the buffer allocation
/// step was never actually reached on real Rane hardware. The fix passes
/// the exact, already-validated sink connection format (which — like every
/// real `AVAudioIONode` format — carries a proper channel layout) straight
/// through instead of reconstructing one, eliminating that failure mode by
/// construction; the remaining stages stay as defensive fail-closed checks.
enum LowLatencySinkAdapterConversionFailureStage: String {
    case channelCountMismatch
    case bufferAllocation
    case channelDataUnavailable
}

enum LowLatencySinkAdapterConversionOutcome {
    case succeeded(AVAudioPCMBuffer)
    case failed(stage: LowLatencySinkAdapterConversionFailureStage)
}

/// Synthesizes an `AVAudioPCMBuffer` from one drained ring slot, using the
/// exact immutable format the sink connection was validated and bound with
/// — never a freshly reconstructed one. Copies each of the slot's planar
/// Float32 channels verbatim, preserving all original channel indices (so
/// the existing channel-pair selection, including physical pair 3/4, keeps
/// operating on exactly the channels it always has). Does not perform or
/// duplicate any channel-pair selection itself — that remains entirely
/// `TimecodeCMSampleBufferAdapter`'s job, called separately by the caller
/// with the buffer this function returns. Runs on the worker's queue, never
/// the realtime callback: allocation here is expected and safe.
func makeLowLatencySinkPCMBuffer(
    fromSlot slot: TimecodeRealtimeIngressSlotView,
    format: AVAudioFormat
) -> LowLatencySinkAdapterConversionOutcome {
    guard slot.channelCount == Int(format.channelCount) else {
        return .failed(stage: .channelCountMismatch)
    }
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slot.frameCount)) else {
        return .failed(stage: .bufferAllocation)
    }
    guard let floatChannelData = pcmBuffer.floatChannelData else {
        return .failed(stage: .channelDataUnavailable)
    }
    pcmBuffer.frameLength = AVAudioFrameCount(slot.frameCount)
    for channel in 0..<slot.channelCount {
        let source = slot.samples(forChannel: channel)
        if let base = source.baseAddress, source.count > 0 {
            floatChannelData[channel].update(from: base, count: source.count)
        }
    }
    return .succeeded(pcmBuffer)
}

/// Every side-effecting action the low-latency DVS sink-node lifecycle
/// needs to perform against the real audio graph and heartbeat state,
/// extracted as closures. This is the smallest seam necessary to prove the
/// *sequencing* around Slice 2's start/catch/stop path (state transitions,
/// teardown order, idempotency, failed-start cleanup completeness) in a
/// plain XCTest, with no real `AVAudioEngine`/`AVAudioSinkNode`/hardware
/// anywhere in the test. It is not a fake or model of `AVAudioEngine`'s own
/// behavior — whether the Rane ONE MKII actually delivers sub-4,800-frame
/// callbacks through a real graph still requires the hardware acceptance
/// run described in `AI_HANDOFF.md`; this seam only proves
/// `MacCaptureEngine`'s own start/catch/stop code is sequenced correctly.
/// `MacCaptureEngine` supplies real closures wrapping `timecodeInputEngine`
/// and `timecodeInputTapHeartbeat`; tests supply closures that only record
/// what was called, in what order, or simulate failure.
struct LowLatencySinkLifecycleActions {
    /// Attaches the sink node to the engine graph and connects it to the
    /// input node, given this session's ring. Called once, before
    /// `startEngine`.
    var attachAndConnect: (TimecodeRealtimeIngressRing) -> Void
    /// Prepares and starts the engine. Throwing means the start failed —
    /// `LowLatencySinkLifecycle.start` fully unwinds everything
    /// `attachAndConnect` did before returning.
    var startEngine: () throws -> Void
    /// Stops the engine's producer path (safe to call even if the engine
    /// was never successfully started).
    var stopEngine: () -> Void
    /// Disconnects and detaches the sink node from the engine graph. Called
    /// only if `attachAndConnect` actually ran for the session being torn
    /// down.
    var disconnectAndDetach: () -> Void
    /// Resets the engine after it has been stopped.
    var resetEngine: () -> Void
    /// Marks the heartbeat installed for this session's device.
    var markHeartbeatInstalled: () -> Void
    /// Resets the heartbeat and clears any stored buffer diagnostic.
    var resetHeartbeat: () -> Void
}

/// Pure sequencing/state-machine layer for one low-latency DVS sink-node
/// session's start → running → stop lifecycle. Owns exactly the state that
/// must be kept consistent across that lifecycle — the current
/// `LowLatencySinkSession` (ring + worker + generation), whether a sink node
/// is currently considered attached, and whether the heartbeat is
/// considered installed — and drives it through
/// `LowLatencySinkLifecycleActions`'s closures for every side effect that
/// touches the real graph or heartbeat. `MacCaptureEngine` is the only
/// production caller; its `refreshLowLatencyTimecodeInput()`/
/// `stopLowLatencyTimecodeInput()` are thin wrappers that build real
/// `LowLatencySinkLifecycleActions` and call `start`/`stop` here — the exact
/// same sequencing code runs in production and in tests, only the closures
/// differ. No `AVAudioEngine`/`AVAudioSinkNode` reference is held by this
/// type itself, so it is fully constructible and drivable in a plain
/// XCTest.
final class LowLatencySinkLifecycle {
    enum StartOutcome: Equatable {
        case started(generation: LowLatencySinkSessionGeneration)
        case sessionConstructionFailed
        case engineStartFailed
    }

    private(set) var currentSession: LowLatencySinkSession?
    private(set) var isSinkAttached = false
    private(set) var isHeartbeatInstalled = false
    private var nextGeneration: LowLatencySinkSessionGeneration = 0

    /// Runs the full start sequence: allocate a new generation + session,
    /// attach/connect, mark the heartbeat installed, then prepare+start the
    /// engine. On any failure (session construction or engine start), fully
    /// unwinds via `stop(actions:)` before returning — a partially-started
    /// session can never remain attached, accepting writes, heartbeat-
    /// installed, or published as `currentSession`.
    @discardableResult
    func start(
        actions: LowLatencySinkLifecycleActions,
        drainInterval: TimeInterval = 0.005,
        consumer: @escaping @Sendable (TimecodeRealtimeIngressSlotView) -> Void
    ) -> StartOutcome {
        let generation = nextGeneration + 1
        nextGeneration = generation
        guard let session = LowLatencySinkSession(
            generation: generation,
            drainInterval: drainInterval,
            consumer: consumer
        ) else {
            return .sessionConstructionFailed
        }

        actions.attachAndConnect(session.ring)
        isSinkAttached = true
        currentSession = session
        actions.markHeartbeatInstalled()
        isHeartbeatInstalled = true

        do {
            try actions.startEngine()
            return .started(generation: generation)
        } catch {
            stop(actions: actions)
            return .engineStartFailed
        }
    }

    /// Truthful, deterministic, idempotent teardown, in the required order:
    /// (1) close producer acceptance — a `publish` call that had already
    /// passed the ring's accept-writes check before this step may still
    /// complete and write one final slot; this step only guarantees that
    /// any call which *observes* the closed flag afterward is rejected, not
    /// that every racing producer call is (see
    /// `TimecodeRealtimeIngressRing.closeForWriting()`'s own documented
    /// guarantee); (2) stop the engine's producer path; (3) disconnect and
    /// detach the sink node; (4) synchronously stop the worker/consumer —
    /// guarantees no further consumer delivery once this call returns; (5)
    /// clear published session state. Safe to call when nothing is running,
    /// and safe to call more than once.
    func stop(actions: LowLatencySinkLifecycleActions) {
        let session = currentSession
        session?.ring.closeForWriting()
        actions.stopEngine()
        if isSinkAttached {
            actions.disconnectAndDetach()
        }
        session?.tearDown()
        actions.resetEngine()
        actions.resetHeartbeat()

        isSinkAttached = false
        isHeartbeatInstalled = false
        currentSession = nil
    }
}

final class MacCaptureEngine: NSObject, ObservableObject {
    enum LiveRecordDirection: String, Equatable {
        case forward
        case backward
    }

    struct AudioInputDeviceChoice: Equatable {
        let uniqueID: String
        let name: String
    }

    enum AudioSelectionPriority: Equatable {
        case exactSeratoVirtualAudio
        case seratoLike
        case explicitUserSelection
        case raneHardware
        case previousSelection
        case systemDefault
        case firstAvailable
        case noneAvailable
    }

    struct AudioSelectionDecision: Equatable {
        let device: AudioInputDeviceChoice?
        let priority: AudioSelectionPriority
    }

    struct CrossfaderCCMapping: Codable, Equatable {
        let channel: Int
        let controller: Int

        var displayName: String { "CC\(controller) Ch\(channel + 1)" }
    }

    struct MIDIInputSourceChoice: Identifiable, Equatable, Hashable {
        let id: String
        let name: String
    }

    enum MIDILearnState: Equatable {
        case idle
        case listening
        case learned(CrossfaderCCMapping)
        case listeningFor(MIDISemanticAction)
    }

    /// Result of evaluating a CC event against the active MIDI Learn session.
    struct MIDILearnCCConsumeResult: Equatable {
        /// True if this exact event was atomically claimed by an active learn
        /// session (any action). Callers must not also resolve this same
        /// event as a hot-cue press or any other production action.
        let consumedByLearn: Bool
        /// The effective crossfader mapping to use for the rest of this
        /// event's processing — set only when this event just learned the
        /// crossfader specifically.
        let crossfaderMapping: CrossfaderCCMapping?
    }

    private enum DirectCaptureRoute {
        case nativeSeratoVirtualAudio
        case privateProcessTap
    }

    private enum RoutineRecordingError: LocalizedError {
        case missingVideo
        case missingAudio
        case sessionNotReady
        case selectedVideoUnavailable
        case selectedAudioUnavailable
        case missingVideoConnection
        case missingAudioConnection

        var errorDescription: String? {
            switch self {
            case .missingVideo:
                return "Pick a camera before starting a routine recording."
            case .missingAudio:
                return "Pick the routed audio input before starting a routine recording."
            case .sessionNotReady:
                return "The capture session is still starting up. Try recording again in a moment."
            case .selectedVideoUnavailable:
                return "The selected camera is unavailable. Pick the camera again and retry."
            case .selectedAudioUnavailable:
                return "The selected audio input is unavailable. Pick the audio source again and retry."
            case .missingVideoConnection:
                return "ScratchLab could not attach the selected camera for recording. Retry after the preview reconnects."
            case .missingAudioConnection:
                return "ScratchLab could not attach the selected audio input for recording. Retry after the audio route reconnects."
            }
        }
    }

    struct ZoneAdjustment: Equatable {
        var offsetX: Double = 0
        var offsetY: Double = 0
        var widthScale: Double = 1
        var heightScale: Double = 1

        static let identity = ZoneAdjustment()

        var isIdentity: Bool {
            self == .identity
        }
    }

    private struct StoredZoneAdjustment: Codable {
        let role: String
        let offsetX: Double
        let offsetY: Double
        let widthScale: Double
        let heightScale: Double
    }

    private struct PreparedRoutineRecording {
        let mediaURL: URL
        let audioURL: URL
        let sidecarURL: URL
        let sidecar: CaptureCore.LocalRecordingSidecar
    }

    private struct RoutineAudioCaptureDiagnosticsSnapshot {
        let buffersReceived: Int
        let buffersAppended: Int
        let buffersSkipped: Int
        let lastErrorMessage: String?
    }

    enum RoutineMovementRawDropReason: String, CaseIterable {
        case endTimeEqualsStart  // furthestPosition never advanced; check shouldAdvanceExtreme logic
        case durationTooShort
        case deltaTooSmall
    }

    enum RoutineMovementNormalizedDropReason: String, CaseIterable {
        case durationTooShort
        case deltaTooSmall
        case speedTooLow
        case confidenceTooLow
        case movementKindHold
    }

    enum RoutineMovementTrustDropReason: String, CaseIterable {
        case lowConfidence
        case notFused
        case lowAudioOverlap
        /// Replay-only: event passed the replay-source trust gate
        /// (skips live confidence + fusion requirements because the
        /// evidence comes from a deterministic platter timeline, not
        /// from a live uncertain Vision tracker).
        case replaySourceTrusted
    }

    struct RoutineMovementDiagnosticsSnapshot: Codable, Equatable {
        let framesReceived: Int
        let framesAnalyzed: Int
        let handObservationsReceived: Int
        let observationsWithConfidence: Int
        let rawDirectionChanges: Int
        let semanticDirectionChanges: Int
        let builderSamplesReceived: Int
        let rawMovementEventsCreated: Int
        let mergedSegments: Int
        let normalizedMovementEvents: Int
        let fusedMovementEvents: Int
        let trustedDirectionalEvents: Int
        let finalRecordMovementEvents: Int
        let activeMovementStarts: Int
        let activeMovementFinishAttempts: Int
        let builderInputAccepted: Int
        let builderInputRejectedDirection: Int
        let builderRejectedSteady: Int
        let builderRejectedSearching: Int
        let steadyInsufficientHistory: Int
        let steadyDisplacementTooSmall: Int
        let steadyVelocityTooLow: Int
        let builderInputExtended: Int
        let publishHandTrackingCalls: Int
        let publishHandTrackingDedupSkips: Int
        let impossibleJumpRejects: Int
        let platterObserveAttempted: Int
        let platterObserveSkippedNotRecording: Int
        let handPoseIntervalMS: Int
        let rawDropReasons: [String: Int]
        let normalizedDropReasons: [String: Int]
        let trustDropReasons: [String: Int]
        /// Replay-only: number of events trusted via the replay-source
        /// path (not counted as drops because replay evidence is
        /// deterministic).  Always zero for live captures.
        let replaySourceTrusted: Int
        /// Times the hand-anchor identity changed (base↔tip, or a different
        /// joint set). Anatomical joint switching inflates this counter; a
        /// temporally-stable base anchor drives it toward zero.
        var anchorSwitches: Int = 0
        /// The most recent anchor identity, e.g. `base:wrist,indexMCP,middleMCP`
        /// or `tipFallback:indexTip`. Observable proof of which joints form the
        /// anchor and whether the stable base is being used.
        var lastAnchorIdentity: String? = nil
        let recentSamples: [String]
        let recentDirections: [String]
    }

    final class RoutineMovementDebugSession {
        private let sampleLimit = 10
        let handPoseIntervalMS: Int

        var framesReceived = 0
        var framesAnalyzed = 0
        var handObservationsReceived = 0
        var observationsWithConfidence = 0
        var rawDirectionChanges = 0
        var semanticDirectionChanges = 0
        var builderSamplesReceived = 0
        var rawMovementEventsCreated = 0
        var mergedSegments = 0
        var normalizedMovementEvents = 0
        var fusedMovementEvents = 0
        var trustedDirectionalEvents = 0
        var finalRecordMovementEvents = 0
        var activeMovementStarts = 0
        var activeMovementFinishAttempts = 0
        var builderInputAccepted = 0
        var builderInputRejectedDirection = 0
        var builderRejectedSteady = 0
        var builderRejectedSearching = 0
        var steadyInsufficientHistory = 0
        var steadyDisplacementTooSmall = 0
        var steadyVelocityTooLow = 0
        var builderInputExtended = 0
        var publishHandTrackingCalls = 0
        var publishHandTrackingDedupSkips = 0
        var impossibleJumpRejects = 0
        var platterObserveAttempted = 0
        var platterObserveSkippedNotRecording = 0
        var anchorSwitches = 0
        private var lastAnchorIdentity: String?

        private var rawDropReasons: [RoutineMovementRawDropReason: Int] = [:]
        private var normalizedDropReasons: [RoutineMovementNormalizedDropReason: Int] = [:]
        private var trustDropReasons: [RoutineMovementTrustDropReason: Int] = [:]
        private var recentSamples: [String] = []
        private var recentDirections: [String] = []

        init(handPoseInterval: CFTimeInterval) {
            handPoseIntervalMS = Int((handPoseInterval * 1_000).rounded())
        }

        func recordSample(rawPoint: CGPoint?, displayedPoint: CGPoint?, confidence: Double, rawDirection: HandDirectionTracker.Direction, semanticState: HandMotionState) {
            handObservationsReceived += 1
            if confidence > 0 {
                observationsWithConfidence += 1
            }
            let rawDescription = rawPoint.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "--"
            let displayedDescription = displayedPoint.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "--"
            append(&recentSamples, value: "raw[\(rawDescription)] sm[\(displayedDescription)] c=\(String(format: "%.2f", confidence))")
            append(&recentDirections, value: "raw=\(rawDirection.debugName) semantic=\(semanticState.debugName)")
        }

        func recordRawDirectionChange() {
            rawDirectionChanges += 1
        }

        func recordSemanticDirectionChange() {
            semanticDirectionChanges += 1
        }

        func recordBuilderSample(state: HandMotionState, position: CGPoint?, confidence: Double) {
            builderSamplesReceived += 1
            let positionDescription = position.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "--"
            append(&recentSamples, value: "builder[\(state.debugName)] p=\(positionDescription) c=\(String(format: "%.2f", confidence))")
        }

        func recordRawMovementEventCreated() {
            rawMovementEventsCreated += 1
        }

        func recordRawDrop(_ reason: RoutineMovementRawDropReason) {
            rawDropReasons[reason, default: 0] += 1
        }

        func recordNormalizedDrop(_ reason: RoutineMovementNormalizedDropReason) {
            normalizedDropReasons[reason, default: 0] += 1
        }

        /// Records a normalized/confidence rejection with its exact reason and
        /// the confidence before and after the adjustment that rejected it.
        func recordNormalizedDrop(
            _ reason: RoutineMovementNormalizedDropReason,
            confidenceBefore: Double,
            confidenceAfter: Double
        ) {
            normalizedDropReasons[reason, default: 0] += 1
            append(&recentSamples, value: "drop:\(reason.rawValue) conf=\(String(format: "%.3f", confidenceBefore))→\(String(format: "%.3f", confidenceAfter))")
        }

        func recordMerge() {
            mergedSegments += 1
        }

        func recordNormalizedMovementCount(_ count: Int) {
            normalizedMovementEvents = count
        }

        func recordFusedMovementCount(_ count: Int) {
            fusedMovementEvents = count
        }

        func recordTrustedDirectionalCount(_ count: Int) {
            trustedDirectionalEvents = count
        }

        var replaySourceTrusted = 0

        func recordReplaySourceTrusted() {
            replaySourceTrusted += 1
        }

        func recordFinalMovementCount(_ count: Int) {
            finalRecordMovementEvents = count
        }

        func recordActiveMovementStart() {
            activeMovementStarts += 1
        }

        func recordActiveMovementFinishAttempt() {
            activeMovementFinishAttempts += 1
        }

        func recordBuilderInputAccepted() {
            builderInputAccepted += 1
        }

        func recordBuilderInputRejectedDirection(state: HandMotionState) {
            builderInputRejectedDirection += 1
            switch state {
            case .steady:
                builderRejectedSteady += 1
            case .searching:
                builderRejectedSearching += 1
            case .movingLeft, .movingRight:
                break // should not reach here — these pass the guard
            }
        }

        func recordSteadyIdleReason(_ reason: HandDirectionTracker.IdleReason) {
            switch reason {
            case .insufficientHistory:
                steadyInsufficientHistory += 1
            case .displacementTooSmall:
                steadyDisplacementTooSmall += 1
            case .velocityTooLow:
                steadyVelocityTooLow += 1
            case .none:
                break // direction was active, not idle
            }
        }

        func recordBuilderInputExtended() {
            builderInputExtended += 1
        }

        func recordPublishHandTrackingCall() {
            publishHandTrackingCalls += 1
        }

        func recordPublishHandTrackingDedupSkip() {
            publishHandTrackingDedupSkips += 1
        }

        func recordImpossibleJumpReject() {
            impossibleJumpRejects += 1
        }

        func recordPlatterObserveAttempted() {
            platterObserveAttempted += 1
        }

        func recordPlatterObserveSkippedNotRecording() {
            platterObserveSkippedNotRecording += 1
        }

        /// Records the hand-anchor identity for one frame. Increments
        /// `anchorSwitches` whenever the identity changed (base↔tip or a
        /// different joint set), and keeps the latest identity string for the
        /// exported diagnostics.
        func recordAnchorIdentity(jointNames: [String], mode: String, switched: Bool) {
            let identity = "\(mode):\(jointNames.joined(separator: ","))"
            if switched {
                anchorSwitches += 1
            }
            lastAnchorIdentity = identity
        }

        func recordTrustDrop(_ reason: RoutineMovementTrustDropReason) {
            trustDropReasons[reason, default: 0] += 1
        }

        func snapshot() -> RoutineMovementDiagnosticsSnapshot {
            RoutineMovementDiagnosticsSnapshot(
                framesReceived: framesReceived,
                framesAnalyzed: framesAnalyzed,
                handObservationsReceived: handObservationsReceived,
                observationsWithConfidence: observationsWithConfidence,
                rawDirectionChanges: rawDirectionChanges,
                semanticDirectionChanges: semanticDirectionChanges,
                builderSamplesReceived: builderSamplesReceived,
                rawMovementEventsCreated: rawMovementEventsCreated,
                mergedSegments: mergedSegments,
                normalizedMovementEvents: normalizedMovementEvents,
                fusedMovementEvents: fusedMovementEvents,
                trustedDirectionalEvents: trustedDirectionalEvents,
                finalRecordMovementEvents: finalRecordMovementEvents,
                activeMovementStarts: activeMovementStarts,
                activeMovementFinishAttempts: activeMovementFinishAttempts,
                builderInputAccepted: builderInputAccepted,
                builderInputRejectedDirection: builderInputRejectedDirection,
                builderRejectedSteady: builderRejectedSteady,
                builderRejectedSearching: builderRejectedSearching,
                steadyInsufficientHistory: steadyInsufficientHistory,
                steadyDisplacementTooSmall: steadyDisplacementTooSmall,
                steadyVelocityTooLow: steadyVelocityTooLow,
                builderInputExtended: builderInputExtended,
                publishHandTrackingCalls: publishHandTrackingCalls,
                publishHandTrackingDedupSkips: publishHandTrackingDedupSkips,
                impossibleJumpRejects: impossibleJumpRejects,
                platterObserveAttempted: platterObserveAttempted,
                platterObserveSkippedNotRecording: platterObserveSkippedNotRecording,
                handPoseIntervalMS: handPoseIntervalMS,
                rawDropReasons: dictionary(from: rawDropReasons),
                normalizedDropReasons: dictionary(from: normalizedDropReasons),
                trustDropReasons: dictionary(from: trustDropReasons),
                replaySourceTrusted: replaySourceTrusted,
                anchorSwitches: anchorSwitches,
                lastAnchorIdentity: lastAnchorIdentity,
                recentSamples: recentSamples,
                recentDirections: recentDirections
            )
        }

        private func append(_ values: inout [String], value: String) {
            values.append(value)
            if values.count > sampleLimit {
                values.removeFirst(values.count - sampleLimit)
            }
        }

        private func dictionary<T: RawRepresentable>(from values: [T: Int]) -> [String: Int] where T.RawValue == String {
            Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        }
    }

    private enum RoutineAudioCaptureWriterError: LocalizedError {
        case unsupportedSourceFormat
        case unableToReadSampleBuffer
        case unableToCreateDestination

        var errorDescription: String? {
            switch self {
            case .unsupportedSourceFormat:
                return "ScratchLab could not prepare the raw audio stem."
            case .unableToReadSampleBuffer:
                return "ScratchLab could not read an incoming audio buffer."
            case .unableToCreateDestination:
                return "ScratchLab could not create the raw audio stem file."
            }
        }
    }

    private final class RoutineAudioCaptureWriter {
        private let destinationURL: URL
        private var destinationFile: AVAudioFile?

        private(set) var buffersReceived = 0
        private(set) var buffersAppended = 0
        private(set) var buffersSkipped = 0
        private(set) var lastErrorMessage: String?

        init(destinationURL: URL) {
            self.destinationURL = destinationURL
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            buffersReceived += 1

            do {
                let pcmBuffer = try Self.pcmBuffer(from: sampleBuffer)
                try ensureDestinationFile(for: pcmBuffer.format)
                guard let destinationFile else {
                    throw RoutineAudioCaptureWriterError.unableToCreateDestination
                }
                try destinationFile.write(from: pcmBuffer)
                buffersAppended += 1
            } catch {
                buffersSkipped += 1
                lastErrorMessage = error.localizedDescription
            }
        }

        func diagnosticsSnapshot() -> RoutineAudioCaptureDiagnosticsSnapshot {
            RoutineAudioCaptureDiagnosticsSnapshot(
                buffersReceived: buffersReceived,
                buffersAppended: buffersAppended,
                buffersSkipped: buffersSkipped,
                lastErrorMessage: lastErrorMessage
            )
        }

        private func ensureDestinationFile(for format: AVAudioFormat) throws {
            if destinationFile != nil { return }

            try? FileManager.default.removeItem(at: destinationURL)
            destinationFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }

        private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            let asbd = asbdPointer.pointee
            let channelCount = max(1, Int(asbd.mChannelsPerFrame))
            let discreteLayout = AVAudioChannelLayout(
                layoutTag: AudioChannelLayoutTag(
                    kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
                )
            )
            let exactFormat = AVAudioFormat(streamDescription: asbdPointer)
                ?? discreteLayout.flatMap {
                    AVAudioFormat(streamDescription: asbdPointer, channelLayout: $0)
                }
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  let format = exactFormat,
                  format.commonFormat == .pcmFormatFloat32
                    || format.commonFormat == .pcmFormatFloat64
                    || format.commonFormat == .pcmFormatInt16
                    || format.commonFormat == .pcmFormatInt32 else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }
            buffer.frameLength = frameCount

            let sourceBufferCount = format.isInterleaved ? 1 : channelCount
            let audioBufferListSize = MemoryLayout<AudioBufferList>.size
                + max(0, sourceBufferCount - 1) * MemoryLayout<AudioBuffer>.size
            let rawPointer = UnsafeMutableRawPointer.allocate(
                byteCount: audioBufferListSize,
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { rawPointer.deallocate() }
            let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

            var retainedBlockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferListPointer,
                bufferListSize: audioBufferListSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retainedBlockBuffer
            )
            guard status == noErr else {
                throw RoutineAudioCaptureWriterError.unableToReadSampleBuffer
            }

            let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard sourceBuffers.count == destinationBuffers.count else {
                throw RoutineAudioCaptureWriterError.unsupportedSourceFormat
            }

            for index in 0..<sourceBuffers.count {
                guard let sourceData = sourceBuffers[index].mData,
                      let destinationData = destinationBuffers[index].mData else {
                    throw RoutineAudioCaptureWriterError.unableToReadSampleBuffer
                }
                memcpy(
                    destinationData,
                    sourceData,
                    min(Int(destinationBuffers[index].mDataByteSize), Int(sourceBuffers[index].mDataByteSize))
                )
            }

            return buffer
        }
    }

    private enum RoutineReviewMovieMuxer {
        enum MuxError: LocalizedError {
            case missingVideoTrack
            case missingAudioTrack
            case unableToCreateCompositionTrack
            case unableToCreateExporter
            case exportFailed(String)

            var errorDescription: String? {
                switch self {
                case .missingVideoTrack:
                    return "The recorded camera file contains no video track."
                case .missingAudioTrack:
                    return "The captured onboard AHHH file contains no audio track."
                case .unableToCreateCompositionTrack:
                    return "ScratchLab could not prepare the final review movie tracks."
                case .unableToCreateExporter:
                    return "ScratchLab could not prepare the final review movie."
                case let .exportFailed(message):
                    return "ScratchLab could not attach onboard AHHH to the video: \(message)"
                }
            }
        }

        static func replaceAudioTrack(
            videoURL: URL,
            onboardAudioURL: URL
        ) async throws {
            let videoAsset = AVURLAsset(url: videoURL)
            let audioAsset = AVURLAsset(url: onboardAudioURL)
            guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
                throw MuxError.missingVideoTrack
            }
            guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw MuxError.missingAudioTrack
            }

            let composition = AVMutableComposition()
            guard let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MuxError.unableToCreateCompositionTrack
            }

            let videoDuration = try await videoAsset.load(.duration)
            let audioDuration = CMTimeMinimum(
                try await audioAsset.load(.duration),
                videoDuration
            )
            let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                try compositionVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: sourceVideoTrack,
                at: .zero
            )
            compositionVideo.preferredTransform = preferredTransform
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioDuration),
                of: sourceAudioTrack,
                at: .zero
            )

            guard let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw MuxError.unableToCreateExporter
            }

            let temporaryURL = videoURL.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)-onboard-audio.mov")
            try? FileManager.default.removeItem(at: temporaryURL)
            exporter.shouldOptimizeForNetworkUse = true
            do {
                try await exporter.export(to: temporaryURL, as: .mov)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw MuxError.exportFailed(error.localizedDescription)
            }

            do {
                try FileManager.default.removeItem(at: videoURL)
                try FileManager.default.moveItem(at: temporaryURL, to: videoURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

#if DEBUG
    static func writeRoutineAudioSampleBufferForTesting(
        _ sampleBuffer: CMSampleBuffer,
        to destinationURL: URL
    ) -> (
        buffersReceived: Int,
        buffersAppended: Int,
        buffersSkipped: Int,
        lastErrorMessage: String?
    ) {
        let writer = RoutineAudioCaptureWriter(destinationURL: destinationURL)
        writer.append(sampleBuffer)
        let diagnostics = writer.diagnosticsSnapshot()
        return (
            diagnostics.buffersReceived,
            diagnostics.buffersAppended,
            diagnostics.buffersSkipped,
            diagnostics.lastErrorMessage
        )
    }
#endif

    final class RoutineDetectedNotationBuilder {
        /// Minimum raw-movement position delta before a movement event is emitted.
        /// Independent of the normalizer threshold so builder and normalizer can
        /// be tuned separately.
        private static let minRawMovementPositionDelta: Double = 0.01

        private struct ActiveMovement {
            let direction: CXLDirection
            let startTime: TimeInterval
            let startPosition: Double?
            let startConfidence: Double
            let source: String
            var latestTime: TimeInterval
            var latestPosition: Double?
            var latestConfidence: Double
            var furthestTime: TimeInterval
            var furthestPosition: Double?
            var peakConfidence: Double
        }

        private let startedAt: CFTimeInterval
        private var activeMovement: ActiveMovement?
        private var events: [CaptureCore.DetectedNotationRecordMovementEvent] = []
        private let debugSession: RoutineMovementDebugSession?
        private let traceRecorder: MovementTraceRecorder?

        init(
            startedAt: CFTimeInterval = CACurrentMediaTime(),
            debugSession: RoutineMovementDebugSession? = nil,
            traceRecorder: MovementTraceRecorder? = nil
        ) {
            self.startedAt = startedAt
            self.debugSession = debugSession
            self.traceRecorder = traceRecorder
        }

        func recordObservation(
            state: HandMotionState,
            position: Double?,
            confidence: Double,
            source: String = "detected",
            now: CFTimeInterval = CACurrentMediaTime(),
            observationID: Int? = nil
        ) {
            #if DEBUG
            debugSession?.recordBuilderSample(
                state: state,
                position: position.map { CGPoint(x: $0, y: 0) },
                confidence: confidence)
            #endif
            let newDirection = Self.direction(for: state)
            let elapsed = max(0, now - startedAt)

            if var activeMovement {
                if activeMovement.direction == newDirection {
                    updateActiveMovement(
                        &activeMovement,
                        position: position,
                        confidence: confidence,
                        elapsed: elapsed
                    )
                    self.activeMovement = activeMovement
                    #if DEBUG
                    debugSession?.recordBuilderInputExtended()
                    recordBuilderAction(observationID, at: now, action: "extended", reason: nil, eventIndex: nil)
                    #endif
                    return
                }

                finishActiveMovement(activeMovement, at: now, observationID: observationID)
                self.activeMovement = nil
            }

            guard newDirection == .forward || newDirection == .back else {
                #if DEBUG
                debugSession?.recordBuilderInputRejectedDirection(state: state)
                recordBuilderAction(observationID, at: now, action: "rejected", reason: String(describing: state), eventIndex: nil)
                #endif
                return
            }
            #if DEBUG
            debugSession?.recordBuilderInputAccepted()
            recordBuilderAction(observationID, at: now, action: "started", reason: nil, eventIndex: nil)
            #endif

            let movement = ActiveMovement(
                direction: newDirection,
                startTime: elapsed,
                startPosition: position,
                startConfidence: confidence,
                source: source,
                latestTime: elapsed,
                latestPosition: position,
                latestConfidence: confidence,
                furthestTime: elapsed,
                furthestPosition: position,
                peakConfidence: confidence
            )
            self.activeMovement = movement
            #if DEBUG
            debugSession?.recordActiveMovementStart()
            #endif
        }

        #if DEBUG
        /// Records the actual builder execution for `observationID`, keyed to
        /// the point the builder actually processed the observation (on MainActor).
        private func recordBuilderAction(
            _ observationID: Int?,
            at now: CFTimeInterval,
            action: String,
            reason: String?,
            eventIndex: Int?
        ) {
            guard let observationID else { return }
            traceRecorder?.recordBuilderExecution(
                index: observationID,
                executionTime: now,
                action: action,
                rejectionReason: reason,
                finishedEventIndex: eventIndex,
                skippedReason: nil
            )
        }
        #endif

        func movementEvents(
            now: CFTimeInterval = CACurrentMediaTime()
        ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            if var activeMovement {
                let elapsed = max(0, now - startedAt)
                updateActiveMovement(
                    &activeMovement,
                    position: activeMovement.latestPosition,
                    confidence: activeMovement.latestConfidence,
                    elapsed: elapsed
                )
                finishActiveMovement(activeMovement, at: now, observationID: nil)
            }
            activeMovement = nil
            return events
        }

        private func updateActiveMovement(
            _ activeMovement: inout ActiveMovement,
            position: Double?,
            confidence: Double,
            elapsed: TimeInterval
        ) {
            activeMovement.latestTime = max(activeMovement.latestTime, elapsed)
            activeMovement.latestConfidence = confidence
            activeMovement.peakConfidence = max(activeMovement.peakConfidence, confidence)

            guard let position else { return }
            activeMovement.latestPosition = position

            // Source-neutral "furthest" tracking: the extreme is the position
            // with the greatest absolute deviation from the start — correct for
            // image X (backward = increasing) and angular position (forward =
            // increasing) alike, and never encodes a per-source sign convention.
            let reference = activeMovement.startPosition ?? position
            let currentDeviation = abs(position - reference)
            let furthestDeviation = activeMovement.furthestPosition.map { abs($0 - reference) } ?? currentDeviation
            if currentDeviation >= furthestDeviation {
                activeMovement.furthestPosition = position
                activeMovement.furthestTime = elapsed
            }
        }

        private func finishActiveMovement(_ activeMovement: ActiveMovement,
                                          at now: CFTimeInterval,
                                          observationID: Int?) {
            #if DEBUG
            debugSession?.recordActiveMovementFinishAttempt()
            #endif
            let resolvedEndPosition = activeMovement.furthestPosition
                ?? activeMovement.latestPosition
                ?? Self.defaultEndPosition(for: activeMovement.direction)
            let endTime: TimeInterval
            if activeMovement.furthestPosition != nil {
                endTime = activeMovement.furthestTime
            } else {
                endTime = activeMovement.latestTime
            }
            guard endTime > activeMovement.startTime else {
                #if DEBUG
                debugSession?.recordRawDrop(.endTimeEqualsStart)
                recordBuilderAction(observationID, at: now, action: "finished", reason: "endTimeEqualsStart", eventIndex: nil)
                #endif
                return
            }
            let duration = endTime - activeMovement.startTime
            guard duration >= 0.020 else {
                #if DEBUG
                debugSession?.recordRawDrop(.durationTooShort)
                recordBuilderAction(observationID, at: now, action: "finished", reason: "durationTooShort", eventIndex: nil)
                #endif
                return
            }

            let resolvedStartPosition = activeMovement.startPosition
                ?? Self.defaultStartPosition(for: activeMovement.direction)
            let distance = abs(resolvedEndPosition - resolvedStartPosition)
            guard distance >= Self.minRawMovementPositionDelta else {
                #if DEBUG
                debugSession?.recordRawDrop(.deltaTooSmall)
                recordBuilderAction(observationID, at: now, action: "finished", reason: "deltaTooSmall", eventIndex: nil)
                #endif
                return
            }
            let speed = duration > 0 ? distance / duration : 0
            let confidence = min(
                1,
                max(0, (activeMovement.startConfidence + activeMovement.peakConfidence) / 2)
            )

            let event = CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: activeMovement.startTime,
                endTime: endTime,
                startPosition: resolvedStartPosition,
                endPosition: resolvedEndPosition,
                direction: activeMovement.direction == .back ? "backward" : "forward",
                movementKind: .hold,
                speed: speed,
                confidence: confidence,
                source: activeMovement.source
            )
            events.append(event)
            #if DEBUG
            debugSession?.recordRawMovementEventCreated()
            recordBuilderAction(observationID, at: now, action: "finished", reason: nil, eventIndex: events.count - 1)
            #endif
        }

        private static func direction(for state: HandMotionState) -> CXLDirection {
            switch state {
            case .movingRight:
                return .forward
            case .movingLeft:
                return .back
            case .steady:
                return .idle
            case .searching:
                return .searching
            }
        }

        private static func defaultStartPosition(for direction: CXLDirection) -> Double {
            direction == .back ? 1 : 0
        }

        private static func defaultEndPosition(for direction: CXLDirection) -> Double {
            direction == .back ? 0 : 1
        }
    }

    struct RoutineNotationEventNormalizer {
        static let minStrokeDuration: TimeInterval = 0.030
        static let minPositionDelta: Double = 0.015
        static let minSpeedForStroke: Double = 0.14
        static let maxMergeGap: TimeInterval = 0.08
        static let maxAudioAlignGap: TimeInterval = 0.09
        static let fastStrokeDuration: TimeInterval = 0.13
        static let fastStrokeSpeed: Double = 3.2
        static let fastStrokeDelta: Double = 0.20
        static let slowStrokeDuration: TimeInterval = 0.34
        static let slowStrokeSpeed: Double = 0.9
        static let slowStrokeDelta: Double = 0.12
        static let unconfirmedConfidenceMultiplier: Double = 0.62
        static let minConfidenceForStroke: Double = 0.12

        func normalize(
            events: [CaptureCore.DetectedNotationRecordMovementEvent],
            audioEvents: [ScratchAudioNotationEventCandidate],
            debugSession: RoutineMovementDebugSession? = nil
        ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            let burstAudioEvents = audioEvents.filter { event in
                event.eventKind == .scratchBurst || event.eventKind == .possibleDrag
            }
            let mergedEvents = mergeAdjacentSameDirection(
                events.sorted(by: eventSort),
                debugSession: debugSession
            )
            let normalized = mergedEvents.compactMap { event in
                classify(
                    event: event,
                    audioEvents: burstAudioEvents,
                    debugSession: debugSession
                )
            }
            #if DEBUG
            debugSession?.recordNormalizedMovementCount(normalized.count)
            #endif
            return normalized
        }

        func classify(
            event: CaptureCore.DetectedNotationRecordMovementEvent,
            audioEvents: [ScratchAudioNotationEventCandidate],
            debugSession: RoutineMovementDebugSession? = nil
        ) -> CaptureCore.DetectedNotationRecordMovementEvent? {
            let duration = max(0, event.endTime - event.startTime)
            guard duration > 0 else { return nil }

            let delta = abs(event.endPosition - event.startPosition)
            let speed = delta / max(duration, 0.001)
            let overlapsAudio = overlapsAudioActivity(event: event, audioEvents: audioEvents)

            guard duration >= Self.minStrokeDuration || overlapsAudio else {
                #if DEBUG
                debugSession?.recordNormalizedDrop(.durationTooShort, confidenceBefore: event.confidence, confidenceAfter: event.confidence)
                #endif
                return nil
            }
            guard delta >= Self.minPositionDelta else {
                #if DEBUG
                debugSession?.recordNormalizedDrop(.deltaTooSmall, confidenceBefore: event.confidence, confidenceAfter: event.confidence)
                #endif
                return nil
            }
            guard speed >= Self.minSpeedForStroke else {
                #if DEBUG
                debugSession?.recordNormalizedDrop(.speedTooLow, confidenceBefore: event.confidence, confidenceAfter: event.confidence)
                #endif
                return nil
            }

            let movementKind = classifyMovementKind(
                direction: event.direction,
                duration: duration,
                delta: delta,
                speed: speed
            )
            guard movementKind != .hold else {
                #if DEBUG
                debugSession?.recordNormalizedDrop(.movementKindHold, confidenceBefore: event.confidence, confidenceAfter: event.confidence)
                #endif
                return nil
            }

            // Idempotent: physical validation + kind classification ONLY. Confidence
            // is NOT mutated here — the single documented `adjustConfidence` stage
            // owns confidence, so repeated normalization cannot compound the penalty.
            return CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: event.startTime,
                endTime: event.endTime,
                startPosition: event.startPosition,
                endPosition: event.endPosition,
                direction: event.direction,
                movementKind: movementKind,
                speed: speed,
                confidence: event.confidence,
                source: event.source
            )
        }

        /// The result of the single, documented source-confidence adjustment.
        struct ConfidenceAdjustment {
            let event: CaptureCore.DetectedNotationRecordMovementEvent
            let before: Double
            let after: Double
            /// `"directTelemetry"` | `"audioCorroborated"` | `"cameraPenalized"` |
            /// `"alreadyAdjusted"` — the exact adjustment applied (or not).
            let kind: String
        }

        /// The SINGLE, documented source-confidence stage.
        ///
        /// Idempotent: an event whose source is already `"video"`/`"fused"` has
        /// been adjusted in a prior stage and is returned unchanged, so repeated
        /// normalization/fusion passes can never compound the penalty.
        ///
        /// - Direct telemetry (`controller` / `timecode_live`) is authoritative and
        ///   NEVER adjusted (no penalty, and audio never lowers it).
        /// - Camera builder output (`detected`): audio corroboration raises it ONCE
        ///   (`+0.08`, source → `fused`); an uncorroborated camera movement is
        ///   penalized ONCE (`× unconfirmedConfidenceMultiplier`, source → `video`).
        func adjustConfidence(
            event: CaptureCore.DetectedNotationRecordMovementEvent,
            audioEvents: [ScratchAudioNotationEventCandidate]
        ) -> ConfidenceAdjustment {
            let overlapsAudio = overlapsAudioActivity(event: event, audioEvents: audioEvents)
            switch event.source {
            case "controller", "timecode_live":
                return ConfidenceAdjustment(event: event, before: event.confidence, after: event.confidence, kind: "directTelemetry")
            case "video", "fused":
                // Already adjusted — idempotent, never re-applied.
                return ConfidenceAdjustment(event: event, before: event.confidence, after: event.confidence, kind: "alreadyAdjusted")
            default:  // "detected" — camera builder output
                if overlapsAudio {
                    let after = min(1, event.confidence + 0.08)
                    let adjusted = CaptureCore.DetectedNotationRecordMovementEvent(
                        startTime: event.startTime, endTime: event.endTime,
                        startPosition: event.startPosition, endPosition: event.endPosition,
                        direction: event.direction, movementKind: event.movementKind, speed: event.speed,
                        confidence: after, source: "fused")
                    return ConfidenceAdjustment(event: adjusted, before: event.confidence, after: after, kind: "audioCorroborated")
                } else {
                    let after = min(1, max(0, event.confidence * Self.unconfirmedConfidenceMultiplier))
                    let adjusted = CaptureCore.DetectedNotationRecordMovementEvent(
                        startTime: event.startTime, endTime: event.endTime,
                        startPosition: event.startPosition, endPosition: event.endPosition,
                        direction: event.direction, movementKind: event.movementKind, speed: event.speed,
                        confidence: after, source: "video")
                    return ConfidenceAdjustment(event: adjusted, before: event.confidence, after: after, kind: "cameraPenalized")
                }
            }
        }

        func classifyMovementKind(
            direction: String,
            duration: TimeInterval,
            delta: Double,
            speed: Double
        ) -> ScratchMovementKind {
            guard delta >= Self.minPositionDelta, speed >= Self.minSpeedForStroke else {
                return .hold
            }

            let isBackward = direction == "backward"
            if duration <= Self.fastStrokeDuration,
               delta >= Self.fastStrokeDelta,
               speed >= Self.fastStrokeSpeed {
                return isBackward ? .fastPull : .fastPush
            }
            if duration >= Self.slowStrokeDuration,
               delta >= Self.slowStrokeDelta,
               speed <= Self.slowStrokeSpeed {
                return isBackward ? .slowPullDrag : .slowDrag
            }
            return isBackward ? .normalPull : .normalPush
        }

        private func mergeAdjacentSameDirection(
            _ events: [CaptureCore.DetectedNotationRecordMovementEvent],
            debugSession: RoutineMovementDebugSession? = nil
        ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            guard var active = events.first else { return [] }
            var merged: [CaptureCore.DetectedNotationRecordMovementEvent] = []

            for event in events.dropFirst() {
                let sameDirection = event.direction == active.direction
                let gap = max(0, event.startTime - active.endTime)
                if sameDirection && gap <= Self.maxMergeGap {
                    #if DEBUG
                    debugSession?.recordMerge()
                    #endif
                    active = CaptureCore.DetectedNotationRecordMovementEvent(
                        startTime: active.startTime,
                        endTime: max(active.endTime, event.endTime),
                        startPosition: active.startPosition,
                        endPosition: event.endPosition,
                        direction: active.direction,
                        movementKind: active.movementKind,
                        speed: max(active.speed, event.speed),
                        confidence: max(active.confidence, event.confidence),
                        source: active.source == event.source ? active.source : "fused"
                    )
                } else {
                    merged.append(active)
                    active = event
                }
            }

            merged.append(active)
            return merged
        }

        private func overlapsAudioActivity(
            event: CaptureCore.DetectedNotationRecordMovementEvent,
            audioEvents: [ScratchAudioNotationEventCandidate]
        ) -> Bool {
            let midpoint = (event.startTime + event.endTime) / 2
            return audioEvents.contains { audioEvent in
                let overlapStart = max(event.startTime, audioEvent.startTime)
                let overlapEnd = min(event.endTime, audioEvent.endTime)
                if overlapEnd - overlapStart > 0 {
                    return true
                }
                let audioMidpoint = (audioEvent.startTime + audioEvent.endTime) / 2
                return abs(audioMidpoint - midpoint) <= Self.maxAudioAlignGap
            }
        }

        private func eventSort(
            _ lhs: CaptureCore.DetectedNotationRecordMovementEvent,
            _ rhs: CaptureCore.DetectedNotationRecordMovementEvent
        ) -> Bool {
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
    }

    struct RoutineNotationFusionEngine {
        private let normalizer = RoutineNotationEventNormalizer()
        private static let minNotationDetectedConfidence = 0.50
        private static let minFusedMovementConfidence = 0.45
        private static let minMotionConfidenceForDirectionalFusion = 0.45
        private static let minAudioOverlapRatioForDirectionalNotation = 0.25
        private static let minDirectionalEventCount = 1

        func snapshot(
            audioSnapshot: ScratchAudioNotationSnapshot,
            motionEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
            detectedLabel: String?,
            labelSource: String,
            labelConfidence: Double?,
            capturedAt: Date = Date(),
            debugSession: RoutineMovementDebugSession? = nil,
            isReplaySource: Bool = false
        ) -> CaptureCore.DetectedNotationSnapshot {
            let candidateMovementEvents = fuseMovementEvents(
                audioEvents: audioSnapshot.audioEvents,
                motionEvents: motionEvents,
                debugSession: debugSession,
                isReplaySource: isReplaySource
            )
            let audioEvents = audioSnapshot.audioEvents.map {
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    duration: $0.duration,
                    peakLevel: Double($0.peakLevel),
                    rmsLevel: Double($0.rmsLevel),
                    confidence: $0.confidence,
                    eventKind: $0.eventKind.rawValue,
                    source: $0.source
                )
            }
            let trustedDirectionalEvents = trustedDirectionalEvents(
                from: candidateMovementEvents,
                audioEvents: audioSnapshot.audioEvents,
                debugSession: debugSession,
                isReplaySource: isReplaySource
            )
            #if DEBUG
            debugSession?.recordFinalMovementCount(candidateMovementEvents.count)
            #endif
            let detectedConfidence: Double?
            if trustedDirectionalEvents.isEmpty {
                detectedConfidence = nil
            } else if isReplaySource {
                // Replay from a recorded platter timeline: confidence
                // is derived from the deterministic reconstruction,
                // not from a live Vision tracker. Use the actual
                // mean confidence for notation display but do not
                // gate hasDetectedDirectionalNotation on it.
                detectedConfidence = trustedDirectionalEvents.map(\.confidence).reduce(0, +) / Double(trustedDirectionalEvents.count)
            } else {
                detectedConfidence = trustedDirectionalEvents.map(\.confidence).reduce(0, +) / Double(trustedDirectionalEvents.count)
            }
            let hasDetectedDirectionalNotation: Bool
            if isReplaySource {
                hasDetectedDirectionalNotation = trustedDirectionalEvents.count >= Self.minDirectionalEventCount
            } else {
                hasDetectedDirectionalNotation = trustedDirectionalEvents.count >= Self.minDirectionalEventCount
                    && (detectedConfidence ?? 0) >= Self.minNotationDetectedConfidence
            }

            let notationSource: String
            if hasDetectedDirectionalNotation {
                notationSource = "detected"
            } else if !audioEvents.isEmpty {
                notationSource = "partial"
            } else {
                notationSource = "unavailable"
            }

            let notationConfidence: Double?
            if hasDetectedDirectionalNotation {
                notationConfidence = detectedConfidence
            } else if !audioEvents.isEmpty {
                notationConfidence = audioEvents.map(\.confidence).reduce(0, +) / Double(audioEvents.count)
            } else {
                notationConfidence = nil
            }

            var detectionSources: [String] = []
            if !audioEvents.isEmpty {
                detectionSources.append("audio")
            }
            if !motionEvents.isEmpty {
                // Label the movement source truthfully from the input events'
                // provenance — camera builder events ("detected") map to the
                // historical "video" label, while direct telemetry keeps its own.
                switch motionEvents.first?.source {
                case "controller": detectionSources.append("controller")
                case "timecode_live": detectionSources.append("timecode_live")
                default: detectionSources.append("video")
                }
            }

            return CaptureCore.DetectedNotationSnapshot(
                notationSource: notationSource,
                notationConfidence: notationConfidence,
                detectedLabel: detectedLabel,
                labelSource: labelSource,
                labelConfidence: labelConfidence,
                detectionSources: detectionSources,
                recordMovementEvents: candidateMovementEvents,
                audioEvents: audioEvents,
                faderEvents: [],
                mixerMidiEvents: [],
                capturedAt: capturedAt
            )
        }

        private func trustedDirectionalEvents(
            from events: [CaptureCore.DetectedNotationRecordMovementEvent],
            audioEvents: [ScratchAudioNotationEventCandidate],
            debugSession: RoutineMovementDebugSession? = nil,
            isReplaySource: Bool = false
        ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            let burstAudioEvents = audioEvents.filter { event in
                event.eventKind == .scratchBurst || event.eventKind == .possibleDrag
            }

            let trusted = events.filter { event in
                if isReplaySource {
                    // Deterministic reconstruction from a recorded
                    // platter timeline.  Live confidence and fusion
                    // provenance are not required; the builder already
                    // enforced minimum duration (0.020s) and delta
                    // (0.01).  Accept the event as trusted.
                    #if DEBUG
                    debugSession?.recordReplaySourceTrusted()
                    #endif
                    return true
                }
                guard event.confidence >= Self.minFusedMovementConfidence else {
                    #if DEBUG
                    debugSession?.recordTrustDrop(.lowConfidence)
                    #endif
                    return false
                }
                let isDirectTelemetry = event.source == "controller" || event.source == "timecode_live"
                guard event.source == "fused" || event.source == "detected" || isDirectTelemetry else {
                    #if DEBUG
                    debugSession?.recordTrustDrop(.notFused)
                    #endif
                    return false
                }
                let overlap = audioOverlapRatio(for: event, audioEvents: burstAudioEvents)
                // Direct telemetry is independently directional — audio may
                // improve timing/confidence but is never required to retain it.
                guard overlap >= Self.minAudioOverlapRatioForDirectionalNotation
                    || event.source == "detected" || isDirectTelemetry else {
                    #if DEBUG
                    debugSession?.recordTrustDrop(.lowAudioOverlap)
                    #endif
                    return false
                }
                return true
            }
            #if DEBUG
            debugSession?.recordTrustedDirectionalCount(trusted.count)
            #endif
            return trusted
        }

        private func fuseMovementEvents(
            audioEvents: [ScratchAudioNotationEventCandidate],
            motionEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
            debugSession: RoutineMovementDebugSession? = nil,
            isReplaySource: Bool = false
        ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            let normalizedMotionEvents = normalizer.normalize(
                events: motionEvents,
                audioEvents: audioEvents,
                debugSession: debugSession
            )
            var fused: [CaptureCore.DetectedNotationRecordMovementEvent] = []
            var usedMotionIndexes = Set<Int>()
            let burstAudioEvents = audioEvents.filter { event in
                event.eventKind == .scratchBurst || event.eventKind == .possibleDrag
            }

            for audioEvent in burstAudioEvents {
                if let match = bestMotionMatch(
                    for: audioEvent,
                    motionEvents: normalizedMotionEvents,
                    usedMotionIndexes: usedMotionIndexes
                ) {
                    let motionEvent = match.event
                    guard motionEvent.confidence >= Self.minMotionConfidenceForDirectionalFusion else {
                        usedMotionIndexes.insert(match.index)
                        continue
                    }
                    // Single confidence adjustment: audio corroboration (or
                    // unchanged for direct telemetry). Physical classification
                    // already ran in normalize; it is idempotent and never
                    // re-mutates confidence.
                    let adjustment = normalizer.adjustConfidence(
                        event: motionEvent,
                        audioEvents: [audioEvent]
                    )
                    guard adjustment.event.confidence >= RoutineNotationEventNormalizer.minConfidenceForStroke else {
                        #if DEBUG
                        debugSession?.recordNormalizedDrop(.confidenceTooLow, confidenceBefore: adjustment.before, confidenceAfter: adjustment.after)
                        #endif
                        usedMotionIndexes.insert(match.index)
                        continue
                    }
                    usedMotionIndexes.insert(match.index)
                    fused.append(adjustment.event)
                }
            }

            for (index, motionEvent) in normalizedMotionEvents.enumerated() where !usedMotionIndexes.contains(index) {
                if isReplaySource {
                    // Deterministic platter replay: no live Vision uncertainty,
                    // no audio to fuse against. Preserve unchanged — never apply
                    // the camera penalty to a deterministic reconstruction.
                    fused.append(motionEvent)
                    continue
                }
                // Single confidence adjustment: direct telemetry is unchanged;
                // an uncorroborated camera movement is penalized ONCE here.
                let adjustment = normalizer.adjustConfidence(
                    event: motionEvent,
                    audioEvents: burstAudioEvents
                )
                guard adjustment.event.confidence >= RoutineNotationEventNormalizer.minConfidenceForStroke else {
                    #if DEBUG
                    debugSession?.recordNormalizedDrop(.confidenceTooLow, confidenceBefore: adjustment.before, confidenceAfter: adjustment.after)
                    #endif
                    continue
                }
                fused.append(adjustment.event)
            }

            let finalEvents = normalizer.normalize(
                events: fused,
                audioEvents: burstAudioEvents,
                debugSession: debugSession
            )
            #if DEBUG
            debugSession?.recordFusedMovementCount(finalEvents.count)
            #endif
            return finalEvents
        }

        private func audioOverlapRatio(
            for event: CaptureCore.DetectedNotationRecordMovementEvent,
            audioEvents: [ScratchAudioNotationEventCandidate]
        ) -> Double {
            let eventDuration = max(0.001, event.endTime - event.startTime)
            let overlap = audioEvents.reduce(0.0) { partial, audioEvent in
                let overlapStart = max(event.startTime, audioEvent.startTime)
                let overlapEnd = min(event.endTime, audioEvent.endTime)
                return partial + max(0, overlapEnd - overlapStart)
            }
            return min(1, overlap / eventDuration)
        }

        private func bestMotionMatch(
            for audioEvent: ScratchAudioNotationEventCandidate,
            motionEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
            usedMotionIndexes: Set<Int>
        ) -> (index: Int, event: CaptureCore.DetectedNotationRecordMovementEvent)? {
            let audioMidpoint = (audioEvent.startTime + audioEvent.endTime) / 2
            return motionEvents.enumerated()
                .filter { !usedMotionIndexes.contains($0.offset) }
                .compactMap { index, event -> (Int, CaptureCore.DetectedNotationRecordMovementEvent, Double)? in
                    let overlapStart = max(audioEvent.startTime, event.startTime)
                    let overlapEnd = min(audioEvent.endTime, event.endTime)
                    let overlap = max(0, overlapEnd - overlapStart)
                    let eventMidpoint = (event.startTime + event.endTime) / 2
                    let midpointDistance = abs(audioMidpoint - eventMidpoint)
                    guard overlap > 0 || midpointDistance <= 0.18 else { return nil }
                    let score = overlap - midpointDistance
                    return (index, event, score)
                }
                .max { $0.2 < $1.2 }
                .map { ($0.0, $0.1) }
        }

    }

    struct CompletedRoutineCaptureSnapshot: Equatable {
        let mediaURL: URL
        let sidecarURL: URL
        let sessionID: String
        let takeID: String
        let endedAt: Date
        let detectedNotation: CaptureCore.DetectedNotationSnapshot?
    }

    struct PerformerMonitorZone: Codable {
        let role: String
        let title: String
        let minX: Double
        let minY: Double
        let width: Double
        let height: Double
    }

    struct PerformerMonitorFrame: Codable {
        let timestamp: TimeInterval
        let jpegData: Data
        let guidanceCue: String
        let guidanceDetail: String
        let scratchStatusTitle: String
        let rigStatusTitle: String
        let audioPercent: String
        let detectionCount: Int
        let highlightedZoneRole: String
        let zones: [PerformerMonitorZone]
    }

    enum HandMotionState: Equatable {
        case searching
        case steady
        case movingLeft
        case movingRight

        var title: String {
            switch self {
            case .searching: return "Show your hand"
            case .steady: return "Hand steady"
            case .movingLeft: return "Back stroke"
            case .movingRight: return "Forward stroke"
            }
        }

        var detail: String {
            switch self {
            case .searching: return "No confident hand pose yet."
            case .steady: return "Camera sees your hand and is waiting for movement."
            case .movingLeft: return "Detected the reverse-back stroke."
            case .movingRight: return "Detected the forward stroke."
            }
        }

        var icon: String {
            switch self {
            case .searching: return "hand.raised.slash.fill"
            case .steady: return "hand.raised.fill"
            case .movingLeft: return "arrow.left.circle.fill"
            case .movingRight: return "arrow.right.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .searching: return Color(hex: "9E9E9E")
            case .steady: return Color(hex: "00BCD4")
            case .movingLeft, .movingRight: return Color(hex: "4CAF50")
            }
        }
    }

    @Published var availableAudioDevices: [AVCaptureDevice] = []
    @Published var availableVideoDevices: [AVCaptureDevice] = []
    @Published private(set) var availableMIDISources: [MIDIInputSourceChoice] = []
    @Published private(set) var availableMIDISourceNames: [String] = []
    @Published private(set) var midiLearnState: MIDILearnState = .idle
    @Published private(set) var crossfaderCCMapping: CrossfaderCCMapping? = nil
    @Published var selectedMIDIInputSourceID: String {
        didSet {
            if selectedMIDIInputSourceID.isEmpty {
                midiSelectionDefaults.removeObject(forKey: ScratchLabDesktopDefaultsKey.selectedMIDIInputSourceID)
            } else {
                midiSelectionDefaults.set(selectedMIDIInputSourceID, forKey: ScratchLabDesktopDefaultsKey.selectedMIDIInputSourceID)
            }
            guard oldValue != selectedMIDIInputSourceID else { return }
            resetMIDIMonitoringState()
            reconnectSelectedMIDIInput()
        }
    }
    @Published private(set) var midiListeningState: String = "Not Connected"
    @Published private(set) var midiEventsReceivedCount: Int = 0
    @Published private(set) var lastMIDIEventSummary: String = "No MIDI received yet"
    @Published private(set) var lastMIDICCMessage: String = "CC -- Ch -- Value --"
    @Published private(set) var midiLearnFeedback: String = ""
    /// Raw value (CC value, or note number for a pad) of the event the CURRENT
    /// MIDI Learn session actually consumed. `nil` from the moment Learn starts
    /// until a fresh event lands, so the Learn panel shows "move the control
    /// now" rather than echoing the parked value of whatever control was last
    /// touched (e.g. the crossfader sitting in `lastMIDICCMessage`).
    @Published private(set) var midiLearnObservedRawValue: Int?
    @Published private(set) var liveCrossfaderRawValue: Int?
    @Published private(set) var liveLeftUpfaderRawValue: Int?
    @Published private(set) var liveRightUpfaderRawValue: Int?
    @Published private(set) var liveHotCueIndex: Int?
    @Published private(set) var liveHotCueSampleID: String?
    @Published private(set) var leftUpfaderOutputGain: Double = 1.0
    var leftUpfaderOutputHandler: ((Double) -> Void)?

    private struct PendingControllerActivity {
        var crossfaderRawValue: Int?
        var leftUpfaderRawValue: Int?
        var rightUpfaderRawValue: Int?
        var hotCueIndex: Int?
        var hotCueSampleID: String?
        var leftUpfaderOutputGain: Double = 1.0
    }

    private enum ControllerActivityUpdate {
        case crossfader(rawValue: Int)
        case leftUpfader(rawValue: Int, outputGain: Double)
        case rightUpfader(rawValue: Int)
        case hotCue(index: Int, sampleID: String)
    }

    private var pendingControllerActivity = PendingControllerActivity()
    private var isControllerActivityPublishPending = false

    // MARK: - Expanded MIDI Learn State (Phase 3)
    /// The mapping store for per-device learned MIDI mappings.
    private let midiMappingStore = MIDILearnedMappingStore.default
    /// Bounded serial queue for ALL learned-mapping persistence (JSON encode +
    /// file write/delete) — learn, clear, hot-cue sample assignment, calibration,
    /// and inversion all funnel through here. Never touched from the CoreMIDI
    /// callback or the main queue: callers only capture value-type arguments and
    /// enqueue a block. Because the queue is serial, mutations apply in the exact
    /// order they were requested, so a later mapping change can never be
    /// clobbered by an earlier, still-in-flight write that read a stale
    /// on-disk/in-memory snapshot.
    private let midiMappingPersistenceQueue = DispatchQueue(label: "scratchlab.midi.mapping.persistence", qos: .utility)
    /// The current device's learned mapping profile, keyed by the selected source.
    @Published private(set) var currentMIDIDeviceMapping: MIDIDeviceMapping? = nil
    /// Set when loading, saving, or resolving a device mapping fails (corrupt file,
    /// unsupported schema, or a hot-cue's assigned sample no longer exists). Cleared
    /// on the next successful operation. Surfaced in the MIDI Learn UI.
    @Published private(set) var midiMappingError: String = ""
    /// Which semantic action is currently being learned (nil when idle).
    /// UI-facing mirror ONLY — this `@Published` property is set exclusively on
    /// main (via `publishOnMainAsync` or main-thread call sites) and must never
    /// be read or written from the CoreMIDI callback or while holding
    /// `midiCaptureLock`. The realtime source of truth is the plain,
    /// lock-protected `learnSessionAction`.
    @Published private(set) var activeMIDILearnAction: MIDISemanticAction? = nil

    // MARK: - Continuous Control Calibration State
    /// Minimum accepted calibrated range (raw 0-127 units) — narrower than this
    /// is rejected as unusably imprecise for normalization.
    private static let minimumCalibrationRange = 20
    /// Lock-protected: mirrors `activeCalibrationAction`/`calibrationObserved*`
    /// but readable/writable from the CoreMIDI thread while accumulating the
    /// observed range, matching the `learnSessionAction`/`activeMIDILearnAction` split.
    private var isCalibrating = false
    private var calibratingAction: MIDISemanticAction? = nil
    private var calibrationMinAccumulator = 0
    private var calibrationMaxAccumulator = 0
    private var calibrationSawAnyEvent = false
    /// Generation token for the active calibration session — bumped on every
    /// start/cancel/finish. A calibration-observed UI publish captures this
    /// at enqueue time and re-checks it at execution time, so a stale,
    /// already-enqueued publication (from a session that has since been
    /// cancelled, finished, or superseded by a new one) detects the mismatch
    /// and never restores or overwrites the current calibration UI state.
    private var calibrationGeneration: UInt64 = 0
    /// True while a coalesced calibration-observed publish is already queued
    /// on main. Gates re-entry so at most one `DispatchQueue.main.async` is
    /// ever pending for this channel — matches `isMidiMonitorPublishPending`.
    private var isCalibrationObservedPublishPending = false
    /// Last time a calibration-observed publish was actually enqueued.
    private var lastCalibrationObservedPublishTime: CFTimeInterval = 0
    /// Calibration-observed UI publish throttle (4 Hz) — within the required
    /// "no faster than 15 Hz" bound; matches the existing MIDI-monitor rate.
    private let calibrationPublishInterval: CFTimeInterval = 0.25
    /// Which continuous action is currently being calibrated, if any.
    @Published private(set) var activeCalibrationAction: MIDISemanticAction? = nil
    /// Live accumulated raw range observed during the active calibration session.
    @Published private(set) var calibrationObservedMin: Int? = nil
    @Published private(set) var calibrationObservedMax: Int? = nil
    /// Set when a calibration is rejected (unusably narrow range / no movement).
    @Published private(set) var calibrationError: String = ""

    // MARK: - Fader Curve Custom Capture State
    //
    // "Set closed" / "Set full-on" discrete capture, distinct from the
    // continuous-sweep min/max calibration above. Mutually exclusive with
    // both MIDI Learn and calibration (same lock-protected guard pattern).
    // A session only ever records the LATEST raw value seen on the
    // EXACT (messageType, channel, controller) already learned for the
    // action — never starts Learn, never replaces the binding, never
    // performs persistence from the CoreMIDI callback.

    /// Lock-protected realtime state, mirrors the calibration fields above.
    private var isCurveCapturing = false
    private var curveCaptureAction: MIDISemanticAction? = nil
    /// Latest raw value observed on the captured action's exact binding
    /// this session. Not persisted; read only by `captureCurveClosedPoint`/
    /// `captureCurveFullOnPoint` when the user presses those buttons.
    private var curveCaptureLastRawValue: Int? = nil
    /// Pending (not yet persisted) capture points.
    private var curveCapturePendingClosedRawValue: Int? = nil
    private var curveCapturePendingFullOnRawValue: Int? = nil
    /// Generation token — bumped on every start/cancel/finish, same
    /// stale-publish protection as `calibrationGeneration`.
    private var curveCaptureGeneration: UInt64 = 0
    private var isCurveCapturePublishPending = false
    private var lastCurveCapturePublishTime: CFTimeInterval = 0
    /// Same bounded rate as calibration's observed-value publish.
    private let curveCapturePublishInterval: CFTimeInterval = 0.25

    /// The exact (messageType, channel, controlNumber) a curve-capture
    /// session is watching — frozen at `startCurveCalibration` time, not
    /// re-read from `currentMIDIDeviceMapping` on every event. Prevents a
    /// mid-session relearn/replace from silently retargeting the session
    /// at a different physical control.
    private struct CurveCaptureBindingIdentity: Equatable {
        let messageType: LearnedMIDIMessageType
        let channel: Int
        let controlNumber: Int
    }
    /// Device the session started on. Finish refuses to persist if the
    /// selected source has since changed, even if by coincidence a
    /// same-named control exists on the new device too.
    private var curveCaptureDeviceID: String? = nil
    private var curveCaptureBindingIdentity: CurveCaptureBindingIdentity? = nil

    /// Which continuous action is currently being curve-captured, if any.
    @Published private(set) var activeCurveCaptureAction: MIDISemanticAction? = nil
    /// UI-facing mirrors of whether each pending point has been captured
    /// this session — the raw values themselves are not exposed to the UI,
    /// which never needs to display normalized/engineering values.
    @Published private(set) var curveCaptureHasClosedPoint: Bool = false
    @Published private(set) var curveCaptureHasFullOnPoint: Bool = false
    /// True once at least one matching CC event has arrived this capture
    /// session — lets the UI show "ready to capture" vs. "move the
    /// control" without ever surfacing the raw/normalized value itself.
    @Published private(set) var curveCaptureHasLiveValue: Bool = false
    /// True only when both points are captured, differ, AND resolve
    /// through the current learned control's min/max/inversion to a
    /// finite, non-degenerate span — recomputed after every capture. The
    /// Finish button's enabled state must be driven from this, not merely
    /// "both points captured", since two distinct raw values can still
    /// normalize to the same (or a degenerate) endpoint under narrow
    /// calibration or extreme inversion.
    @Published private(set) var curveCaptureCanFinish: Bool = false
    /// Set when a curve-capture action is rejected (not yet learned, no
    /// value observed yet, Finish attempted while invalid, or the
    /// captured binding/device changed mid-session).
    @Published private(set) var curveCaptureError: String = ""

    // MARK: - Scratch Bank Pad Preview Gate
    // Diagnostic-only gate. Default OFF. No scoring. No audio routing.
    // Caller injects a sample-preview callback; on macOS the callback is nil
    // until a desktop sample player is available.
    @Published var isScratchBankMIDIPreviewEnabled: Bool = true
    @Published private(set) var lastScratchBankPadLabel: String = ""
#if DEBUG
    @Published private(set) var lastRawPadDiagnostic: String = ""
#endif
    /// Outcome of the most recent validated platter-sample load request, so
    /// a missing asset is never mistaken for a platter/MIDI hardware fault.
    @Published private(set) var platterTestLoadStatus: String = ""
    @Published private(set) var scratchAudioOwnershipMode: ScratchAudioOwnershipMode = .defaultMode
    var scratchBankPadPreviewCallback: ((String) -> Void)?

    /// Platter CC6 ring-counter tracker per deck (ch=0 left, ch=1 right).
    private let platterTracker = ScratchPlatterTracker()

    /// Platter-driven scratch sample playback controller.
    private let scratchPlaybackController: ScratchSamplePlaybackController
    private var tempDirectAhhhTriggerArmed = true
    private let audioOwnershipLock = NSLock()
    private var audioOwnershipModeStorage: ScratchAudioOwnershipMode = .defaultMode

    /// Lock-backed so CoreMIDI/DVS callbacks enforce the boundary without
    /// touching SwiftUI state or performing UserDefaults I/O at MIDI rate.
    private var allowsLocalScratchPlayback: Bool {
        audioOwnershipLock.lock()
        defer { audioOwnershipLock.unlock() }
        return audioOwnershipModeStorage.allowsLocalScratchPlayback
    }

    /// When true, a gated `TimecodePlaybackDrive` from `TimecodePlaybackBridge`
    /// drives `scratchPlaybackController`, and the raw MIDI CC6 platter path
    /// below is suppressed so the two sources never drive playback at once.
    /// Defaults to false — MIDI CC6 behavior is unchanged unless the DVS
    /// panel explicitly enables the bridge.
    @Published private var publishedDVSPlaybackDriveActive: Bool = false
    private let dvsPlaybackDriveStateLock = NSLock()
    private var dvsPlaybackDriveActiveStorage = false

    var dvsPlaybackDriveActive: Bool {
        dvsPlaybackDriveStateLock.lock()
        defer { dvsPlaybackDriveStateLock.unlock() }
        return dvsPlaybackDriveActiveStorage
    }

    /// Updates the scheduling gate synchronously on any caller queue while
    /// mirroring the user-facing state asynchronously on the main queue.
    /// DVS decode/playback must not wait behind a stalled SwiftUI run loop.
    func setDVSPlaybackDriveActive(_ isActive: Bool) {
        dvsPlaybackDriveStateLock.lock()
        let changed = dvsPlaybackDriveActiveStorage != isActive
        dvsPlaybackDriveActiveStorage = isActive
        dvsPlaybackDriveStateLock.unlock()
        guard changed else { return }

        // Right-deck MIDI continuous drive ownership: DVS always outranks
        // MIDI. This is the single authoritative signal both the legacy
        // raw-CC6 suppression below and the continuous-renderer ownership
        // arbitration are driven from.
        scratchPlaybackController.setDVSOwnership(active: isActive)

        if !isActive {
            // Deactivating Drive must not leave a trusted drive or dropout
            // count from this session around to be replayed as inferred
            // motion if Drive is re-enabled later — `clearDVSDriveHoldState`
            // takes `dvsDriveHoldStateLock`, safe to call from any thread
            // (this setter is not confined to the DVS control queue).
            // `lastForwardedContinuousSteps` is deliberately untouched.
            clearDVSDriveHoldState()
        }

        let publish = { [weak self] in
            guard let self,
                  self.publishedDVSPlaybackDriveActive != isActive else { return }
            self.publishedDVSPlaybackDriveActive = isActive
        }
        // Dispatch asynchronously: writing @Published state synchronously
        // from the main thread is the known gap flagged in the
        // publishDVSDriveDiagnosticsIfNeeded comment block.  This alone is
        // not sufficient to eliminate the "Modifying state during view
        // update" warning — hardware proved publishOnMainAsync (which
        // already dispatches async) still warns.  The identical-value guard
        // above (publishedDVSPlaybackDriveActive != isActive) avoids the
        // most common unnecessary republish case.
        DispatchQueue.main.async(execute: publish)
    }

    /// Timestamp of the most recent DVS-driven `positionDidChange` call —
    /// diagnostic only. `nil` means no DVS motion has reached playback yet
    /// this session (bridge inactive, gated off, or never evaluated).
    var lastTimecodeDriveAppliedAt: Date? {
        dvsDriveDiagnosticState.lastTimecodeDriveAppliedAt
    }

    /// Diagnostic only: whether an auto-load of the DVS drive sample has
    /// been requested this session (does not mean it necessarily
    /// succeeded — see `dvsSampleLoadFailed`).
    var dvsAutoLoadAttempted: Bool {
        dvsDriveDiagnosticState.autoLoadAttempted
    }

    /// Diagnostic only: true if the most recent DVS auto-load request
    /// failed (sample ID unknown or WAV missing from the bundle).
    var dvsSampleLoadFailed: Bool {
        dvsDriveDiagnosticState.sampleLoadFailed
    }

    /// CACurrentMediaTime of the most recent forwardTimecodeDrive call (DEBUG).
    private static var _lastDriveCADate: TimeInterval = 0

#if DEBUG
    /// CACurrentMediaTime of the entry to the most recent forwardTimecodeDrive call — for
    /// measuring inter-call interval at this layer. Used by [DVS-TRACE:3].
    private static var _lastForwardEntryTime: TimeInterval = 0

    /// Number of forwardTimecodeDrive calls currently in flight (incremented at entry,
    /// decremented after positionDidChange returns). Since execution is synchronous this
    /// is always 0 or 1; a value >1 would indicate unexpected re-entrancy.
    private static var _pendingDriveOps: Int = 0
#endif

    /// Diagnostic only: whether `scratchPlaybackController` currently has
    /// any sample loaded (of any source — DVS, MIDI pad, or debug button).
    var isDVSSampleLoaded: Bool { scratchPlaybackController.loadedSampleID != nil }

    /// Diagnostic only: point-in-time playback-controller state as of the
    /// most recent `forwardTimecodeDrive` tick. Distinguishes "motion never
    /// reached the scheduler" from "scheduling happened but produced no
    /// audible output" — those two failure classes are indistinguishable
    /// from `dvsPlaybackDriveActive` / the bridge's "Driving" status alone.
    /// One tick behind the schedule call within the same
    /// `forwardTimecodeDrive` invocation (the schedule itself is queued
    /// async), but continuously refreshed at the ~10 Hz tick rate.
    var dvsPlaybackDiagnostics: ScratchSamplePlaybackController.DVSPlaybackDiagnostics? {
        dvsDriveDiagnosticState.playbackDiagnostics
    }

    /// Test-only: synchronous, unthrottled snapshot of the playback
    /// controller's diagnostics, bypassing `dvsPlaybackDiagnostics`'s
    /// 200ms publish throttle and main-queue async hop. Deterministic tests
    /// asserting on the effect of a single `forwardTimecodeDrive` tick need
    /// the state immediately after that call returns, not eventually.
    func testOnly_scratchPlaybackDiagnosticsSnapshot() -> ScratchSamplePlaybackController.DVSPlaybackDiagnostics {
        scratchPlaybackController.diagnosticsSnapshot()
    }

    /// Test-only: blocks until the playback controller's audio queue is
    /// idle — e.g. after `ensureLoadedForDVSDrive`'s async sample load,
    /// which `forwardTimecodeDrive` itself does not wait for.
    func testOnly_waitForPlaybackQueue() {
        scratchPlaybackController.waitForAudioQueue()
    }

    /// Test-only passthrough for asserting the bridge-to-playback
    /// continuity fix does not cause repeated/duplicate stop ramps — see
    /// `ScratchSamplePlaybackController.dvsAutoStopRampStartCount`.
    var testOnly_scratchAutoStopRampStartCount: Int {
        scratchPlaybackController.dvsAutoStopRampStartCount
    }

    private struct DVSDriveDiagnosticState: Equatable {
        var lastTimecodeDriveAppliedAt: Date?
        var autoLoadAttempted = false
        var sampleLoadFailed = false
        var playbackDiagnostics: ScratchSamplePlaybackController.DVSPlaybackDiagnostics?
    }

    @Published private var dvsDriveDiagnosticState = DVSDriveDiagnosticState()
    private var lastDVSDriveDiagnosticPublishUptime: TimeInterval = -.infinity
    private static let dvsDriveDiagnosticPublishInterval: TimeInterval = 0.2

    /// Throttled read-position snapshot for the live "ahh" read-position
    /// track (Task 8). Polled at ~25 Hz from a background queue and hopped to
    /// the MainActor — never mutated from `audioQueue` directly.
    @Published private(set) var playbackPositionSnapshot: ScratchSamplePlaybackController.PlaybackPositionSnapshot?
    @Published private(set) var playbackWaveformSnapshot: ScratchSamplePlaybackController.PlaybackWaveformSnapshot?
    private static let playbackPositionPollInterval: TimeInterval = 0.04
    private var playbackPositionPollTimer: DispatchSourceTimer?

    /// Sample ID armed for DVS-driven playback. Uses the short, continuous
    /// VirtualPlatter Ahhh rather than the pad sample's long silent tail.
    private static let dvsDriveSampleID = "dvs_ahhh"

    private var timecodeDriveStepConverter = TimecodeDriveStepConverter()

    /// Guards `lastTrustedTimecodeDrive` and `consecutiveTransientDropoutTicks`
    /// only — `forwardTimecodeDrive` itself is confined to the DVS control
    /// queue (`DVSControlProcessingLoop`'s serial `com.scratchlab.dvsControl`
    /// queue), but `setDVSPlaybackDriveActive` is callable from any thread
    /// (e.g. a main-thread SwiftUI toggle) and must be able to clear this
    /// hold state without racing a concurrent `forwardTimecodeDrive` tick.
    /// `lastForwardedContinuousSteps` is read/written only from
    /// `forwardTimecodeDrive`'s own queue and is deliberately not guarded by
    /// this lock.
    private let dvsDriveHoldStateLock = NSLock()

    /// Bridge-to-playback continuity fix (2026-08-09 near-stop burst/static):
    /// last `.driving` drive, held for at most one transient bridge-dropout
    /// tick — see `forwardTimecodeDrive`'s decision handling. Cleared (not
    /// just left stale) on `.unknownDirection`, after a second consecutive
    /// transient failure gives up holding, and whenever DVS drive is
    /// deactivated — a stale trusted drive from before a genuine stop must
    /// never be replayed as inferred motion by a later transient tick.
    /// Access only through `dvsDriveHoldStateLock`.
    private var lastTrustedTimecodeDrive: TimecodePlaybackDrive?

    /// Cumulative continuous platter steps most recently forwarded to the
    /// playback controller — the position anchor a no-direction tick must
    /// reuse. `positionDidChangeContinuous(steps:)` expects the caller's own
    /// running total, not a delta, so a real "no motion" tick must resend
    /// this rather than fabricate `steps: 0`. Never reset merely because
    /// motion became unavailable — only `forwardTrustedDrive` advances it.
    private var lastForwardedContinuousSteps: Double = 0

    /// Consecutive *transient* bridge-dropout ticks (unusableSignalHealth /
    /// lowConfidence / missingTimeline / validationRequired / staleSignal).
    /// Reset to 0 by any `.driving` tick, by `.unknownDirection`, and when
    /// DVS drive is deactivated. At 0→1 the last trusted drive is held for
    /// exactly this one tick (inferred motion bounded to this tick's own
    /// `elapsed`, ~16–17ms at 60 Hz); from 1 onward, holding stops and every
    /// further tick forwards one no-direction tick instead — see
    /// `forwardTimecodeDrive`. Access only through `dvsDriveHoldStateLock`.
    private var consecutiveTransientDropoutTicks = 0

    /// Clears the held-drive/dropout-hold state — see
    /// `lastTrustedTimecodeDrive`'s and `consecutiveTransientDropoutTicks`'s
    /// doc comments for the three call sites this covers. Deliberately does
    /// not touch `lastForwardedContinuousSteps`.
    private func clearDVSDriveHoldState() {
        dvsDriveHoldStateLock.lock()
        lastTrustedTimecodeDrive = nil
        consecutiveTransientDropoutTicks = 0
        dvsDriveHoldStateLock.unlock()
    }

    /// Forwards an already-gated `TimecodePlaybackDrive` (validated by
    /// `TimecodePlaybackBridge.evaluate`) into the existing platter-driven
    /// sample playback path. No-op unless `dvsPlaybackDriveActive` is true.
    ///
    /// Ensures the DVS drive sample is loaded before forwarding motion —
    /// arms as soon as `dvsPlaybackDriveActive` is true, independent of
    /// whether `drive` itself is non-nil yet, so the sample is ready
    /// before the first valid motion arrives. `ensureLoadedForDVSDrive` is
    /// idempotent and safe to call every tick: it does not reload or reset
    /// `currentSampleFrame` once the sample is already loaded.
    ///
    /// - Parameter decision: `timecodeBridge.lastDecision` for this same
    ///   evaluation. A nil `drive` alone cannot distinguish "genuinely no
    ///   motion" (`.unknownDirection`) from "signal transiently untrusted"
    ///   (e.g. `.unusableSignalHealth`) from "hard-gated off"
    ///   (`.disabled`/`.replayActive`/…) — those three call for different
    ///   handling below, and previously all three silently produced no call
    ///   into the playback controller at all, which is what let its queued
    ///   grain expire into digital silence with no tick for the settling
    ///   hysteresis to ever see (2026-08-09 hardware capture correlation).
    func forwardTimecodeDrive(
        _ drive: TimecodePlaybackDrive?,
        decision: TimecodePlaybackBridgeDecision,
        elapsed: TimeInterval
    ) {
        guard dvsPlaybackDriveActive else { return }
        guard allowsLocalScratchPlayback else { return }
        let driveEntryUptime = CACurrentMediaTime()

#if DEBUG
        let traceSeq = DVSTrace.current
        let tFwdEntry = driveEntryUptime
        let fwdDt = tFwdEntry - Self._lastForwardEntryTime
        Self._lastForwardEntryTime = tFwdEntry
        let pendingOps = Self._pendingDriveOps
        Self._pendingDriveOps += 1
        defer { Self._pendingDriveOps -= 1 }
        let _dirStr = drive.map { $0.direction.rawValue } ?? "nil"
        let _thr = Thread.current.isMainThread ? "main" : "bg"
        DVSTrace.log("[DVS-TRACE:3] captureEngine forward seq=\(traceSeq) monotonic=\(tFwdEntry) fwdDt=\(fwdDt)s pendingOps=\(pendingOps) elapsed=\(elapsed)s dir=\(_dirStr) rate=\(drive.map { $0.rate } ?? 0) segmentWindow=\(elapsed) decision=\(decision.rawValue) thread=\(_thr)")
#endif

        #if DEBUG
        let now = CACurrentMediaTime()
        let dt = now - Self._lastDriveCADate
        Self._lastDriveCADate = now
        if dt > 0.15 {
            print("[DVS] ⏱ drive dt=\(String(format: "%.0f", dt * 1000))ms elapsed=\(String(format: "%.0f", elapsed * 1000))ms rate=\(drive.map { String(format: "%.2f", $0.rate) } ?? "nil") dir=\(drive.map { "\($0.direction)" } ?? "nil") decision=\(decision.rawValue)")
        }
        #endif

        let loadOK = scratchPlaybackController.ensureLoadedForDVSDrive(sampleID: Self.dvsDriveSampleID)
        let driveApplied: Bool

        switch decision {
        case .driving:
            // Expected to carry a drive; if it somehow doesn't, fail safe
            // exactly like the pre-fix nil-drive path (no motion inferred).
            if let drive {
                dvsDriveHoldStateLock.lock()
                consecutiveTransientDropoutTicks = 0
                lastTrustedTimecodeDrive = drive
                dvsDriveHoldStateLock.unlock()
                forwardTrustedDrive(drive, elapsed: elapsed)
                driveApplied = true
            } else {
                forwardNoDirectionTick(elapsed: elapsed)
                driveApplied = false
            }

        case .unknownDirection:
            // Genuine stationary/no-direction tick: never inferred motion,
            // never held — let the existing stop ramp and settling
            // hysteresis (untouched by this fix) see it immediately. Then
            // clear the hold: a genuine stop must not leave a stale trusted
            // drive for a later transient tick to replay as inferred motion.
            forwardNoDirectionTick(elapsed: elapsed)
            driveApplied = false
            clearDVSDriveHoldState()

        case .unusableSignalHealth, .lowConfidence, .missingTimeline, .validationRequired, .staleSignal:
            // Transient: the signal is momentarily untrusted, not proven
            // absent. Hold the last trusted drive for exactly one tick so a
            // single flapped gate cannot open a digital-silence hole; a
            // second consecutive transient tick gives up holding (bounded —
            // see `consecutiveTransientDropoutTicks`'s doc comment), reports
            // genuine no-direction instead, and clears the trusted drive —
            // further transient ticks must never infer motion again until a
            // new genuine `.driving` result stores a fresh trusted drive.
            dvsDriveHoldStateLock.lock()
            let ticksSoFar = consecutiveTransientDropoutTicks
            let trusted = lastTrustedTimecodeDrive
            if ticksSoFar == 0, let trusted {
                consecutiveTransientDropoutTicks = 1
                dvsDriveHoldStateLock.unlock()
                forwardTrustedDrive(trusted, elapsed: elapsed)
                driveApplied = true
            } else {
                consecutiveTransientDropoutTicks = ticksSoFar + 1
                lastTrustedTimecodeDrive = nil
                dvsDriveHoldStateLock.unlock()
                forwardNoDirectionTick(elapsed: elapsed)
                driveApplied = false
            }

        case .disabled, .pipelineDisabled, .diagnosticsOnly, .replayActive, .liveTapOff, .notEvaluated:
            // Hard configuration/safety gate: no signal to hold or infer
            // from. Forward no-direction immediately and drop any hold.
            clearDVSDriveHoldState()
            forwardNoDirectionTick(elapsed: elapsed)
            driveApplied = false
        }

        publishDVSDriveDiagnosticsIfNeeded(
            uptime: driveEntryUptime,
            loadFailed: !loadOK,
            driveApplied: driveApplied
        )
    }

    /// Advances the step converter by `elapsed` at `drive`'s rate, records
    /// the resulting cumulative steps as `lastForwardedContinuousSteps`, and
    /// forwards `drive`'s direction to the playback controller. Used both
    /// for a genuine `.driving` tick and for the at-most-one-tick
    /// transient-dropout hold in `forwardTimecodeDrive`.
    private func forwardTrustedDrive(_ drive: TimecodePlaybackDrive, elapsed: TimeInterval) {
        let steps = timecodeDriveStepConverter.continuousSteps(
            forRate: drive.rate,
            elapsed: elapsed
        )
        lastForwardedContinuousSteps = steps
        let direction: ScratchPlatterDirection? = {
            switch drive.direction {
            case .forward:  return .forward
            case .backward: return .backward
            case .unknown:  return nil
            }
        }()
        // Pass the real tick interval as the scheduling window so the grain's
        // varispeed rate reflects true platter speed instead of the fixed
        // 1/60s slot sized for MIDI CC6's much faster call cadence — see
        // the doc comment on `positionDidChange(steps:direction:segmentWindow:)`.
        scratchPlaybackController.positionDidChangeContinuous(steps: steps, direction: direction, segmentWindow: elapsed)
    }

    /// Forwards a genuine no-motion tick at the last known cumulative step
    /// position — never a fabricated `steps: 0` — so the playback
    /// controller's existing (untouched) stop-ramp / settling hysteresis
    /// sees a real "no direction" tick instead of receiving no call at all.
    /// Deliberately does not advance `timecodeDriveStepConverter`: there is
    /// no trusted rate to integrate for a tick with no direction.
    private func forwardNoDirectionTick(elapsed: TimeInterval) {
        scratchPlaybackController.positionDidChangeContinuous(
            steps: lastForwardedContinuousSteps,
            direction: nil,
            segmentWindow: elapsed
        )
    }

    private func publishDVSDriveDiagnosticsIfNeeded(
        uptime: TimeInterval,
        loadFailed: Bool,
        driveApplied: Bool
    ) {
        guard uptime - lastDVSDriveDiagnosticPublishUptime >=
                Self.dvsDriveDiagnosticPublishInterval else {
            return
        }
        lastDVSDriveDiagnosticPublishUptime = uptime

        var next = dvsDriveDiagnosticState
        next.autoLoadAttempted = true
        next.sampleLoadFailed = loadFailed
        next.playbackDiagnostics = scratchPlaybackController.diagnosticsSnapshot()
        if driveApplied {
            next.lastTimecodeDriveAppliedAt = Date()
        }
        let publish = { [weak self] in
            guard let self, self.dvsDriveDiagnosticState != next else { return }
            print("[SwiftUIStateGuard] publish · source=MacCaptureEngine.publishDVSDriveDiagnosticsIfNeeded field=dvsDriveDiagnosticState thread=\(Thread.isMainThread ? "main" : "background") time=\(String(format: "%.6f", CACurrentMediaTime()))")
            self.dvsDriveDiagnosticState = next
        }
        // Dispatch asynchronously: the prior `Thread.isMainThread` shortcut
        // was a known gap (documented in the since-removed comment block
        // above).  This alone is not sufficient to eliminate the SwiftUI
        // warning — hardware proved publishOnMainAsync (which already
        // dispatches async) still warns.  The identical-value guard and the
        // async dispatch reduce unnecessary republishes but are
        // hardware-unverified as a complete fix.
        DispatchQueue.main.async(execute: publish)
    }

#if DEBUG
    /// Evaluates the independent DVS notation trust gate against `pipeline`
    /// and, only when trusted and a routine take is actively recording with
    /// notation routing enabled, appends the trusted window to the
    /// in-progress accumulator.
    ///
    /// Entirely independent of `dvsPlaybackDriveActive`/
    /// `forwardTimecodeDrive`: this method never reads or writes any
    /// playback-related property, and nothing in `forwardTimecodeDrive`
    /// reads or writes anything this method touches. `validationRequired`
    /// is always `true` with no override parameter exposed here — per the
    /// recorded plan, notation routing must never auto-enable a validation
    /// override the way a user-facing playback control might.
    func forwardTimecodeNotationWindow(pipeline: TimecodeControlPipeline, minConfidence: Double) {
        guard notationRoutingEnabled, isRoutineRecording else { return }
        let result = TimecodeNotationTrustGate.evaluate(
            pipeline: pipeline,
            notationRoutingEnabled: notationRoutingEnabled,
            isReplayActive: false,
            minConfidence: minConfidence,
            validationRequired: true,
            validationOverride: false
        )

        timecodeNotationLock.lock()
        defer { timecodeNotationLock.unlock() }
        timecodeNotationDiagnosticsStorage.record(result.decision)
        guard result.decision == .trusted,
              let timeline = result.timeline,
              let firstSampleTime = timeline.samples.first?.time else { return }
        if timecodeNotationAccumulator == nil {
            timecodeNotationAccumulator = TimecodeNotationTimelineAccumulator(takeStartTime: firstSampleTime)
        }
        timecodeNotationAccumulator?.append(window: timeline)
        timecodeNotationDiagnosticsStorage.updateAccumulatedSampleCount(
            timecodeNotationAccumulator?.samples.count ?? 0
        )
    }
#endif

    @Published var selectedAudioDeviceUniqueID: String = UserDefaults.standard.string(forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceUniqueID) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedAudioDeviceUniqueID, forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceUniqueID)
            switch pendingAudioSelectionOrigin {
            case .explicitUserChoice:
                hasExplicitUserAudioSelection = !selectedAudioDeviceUniqueID.isEmpty
            case .automatic:
                if selectedAudioDeviceUniqueID.isEmpty {
                    hasExplicitUserAudioSelection = false
                }
            }
            UserDefaults.standard.set(hasExplicitUserAudioSelection, forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceWasExplicit)
            syncDirectCaptureStatus(using: availableAudioDevices)
            resetAudioSignalLevel()
            syncScratchPlaybackOutputRoute()
            guard oldValue != selectedAudioDeviceUniqueID, isRunning else { return }
            reconfigureSession()
        }
    }
    @Published var selectedVideoDeviceUniqueID: String = UserDefaults.standard.string(forKey: ScratchLabDesktopDefaultsKey.selectedVideoDeviceUniqueID) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedVideoDeviceUniqueID, forKey: ScratchLabDesktopDefaultsKey.selectedVideoDeviceUniqueID)
            resetAudioSignalLevel()
            guard oldValue != selectedVideoDeviceUniqueID, isRunning else { return }
            reconfigureSession()
        }
    }
    @Published var audioLevel: Float = 0
    @Published private(set) var hasPublishedAudioLevel = false
    @Published private(set) var onboardOutputLevel: Float = 0
    @Published private(set) var onboardOutputCaptureStatus = "Load AHHH, then record to meter the captured output."
    /// The audio device uniqueID actually attached to the running capture
    /// session by `configureCaptureSession` ("" when none). The UI and
    /// diagnostics read this so what is shown == what is captured/recorded,
    /// instead of trusting the requested selection alone.
    @Published private(set) var activeCaptureAudioDeviceUniqueID: String = ""
    @Published var handDetected = false
    @Published var handPosition: CGPoint?
    @Published var handMotionState: HandMotionState = .searching
    @Published var lastScratchDetection: MacScratchDetectionResult?
    @Published var scratchDetectionCount = 0
    @Published var rigLayout: DJRigLayout?
    @Published var highlightedZoneRole: DJRigZone.Role = .leftDeck
    @Published var sessionStars = 0
    @Published var calibrationLocked: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.calibrationLocked) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(calibrationLocked, forKey: ScratchLabDesktopDefaultsKey.calibrationLocked)
            guard oldValue != calibrationLocked else { return }
            videoQueue.async {
                if self.calibrationLocked {
                    self.rigLayoutDetector.prioritizeNextDetection()
                } else {
                    self.clearFixedRigLayout(prioritizeDetection: true)
                    self.resetPublishedVideoState()
                }
            }
        }
    }
    @Published var practiceViewEnabled: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.practiceViewEnabled) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(practiceViewEnabled, forKey: ScratchLabDesktopDefaultsKey.practiceViewEnabled)
        }
    }
    @Published var useDJPerspective: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.useDJPerspective) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useDJPerspective, forKey: ScratchLabDesktopDefaultsKey.useDJPerspective)
        }
    }
    @Published var manualRigGuideEnabled: Bool = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.manualRigGuideEnabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(manualRigGuideEnabled, forKey: ScratchLabDesktopDefaultsKey.manualRigGuideEnabled)
            guard oldValue != manualRigGuideEnabled else { return }
            videoQueue.async {
                self.clearFixedRigLayout(prioritizeDetection: true)
                self.resetPublishedVideoState()
            }
        }
    }
    @Published private(set) var isUsingManualRigGuide = false
    @Published var rigHorizontalOffset: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigHorizontalOffset) as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(rigHorizontalOffset, forKey: ScratchLabDesktopDefaultsKey.rigHorizontalOffset)
        }
    }
    @Published var rigVerticalOffset: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigVerticalOffset) as? Double ?? 0 {
        didSet {
            UserDefaults.standard.set(rigVerticalOffset, forKey: ScratchLabDesktopDefaultsKey.rigVerticalOffset)
        }
    }
    @Published var rigWidthScale: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigWidthScale) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(rigWidthScale, forKey: ScratchLabDesktopDefaultsKey.rigWidthScale)
        }
    }
    @Published var rigHeightScale: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.rigHeightScale) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(rigHeightScale, forKey: ScratchLabDesktopDefaultsKey.rigHeightScale)
        }
    }
    @Published var mixerWidthRatio: Double = UserDefaults.standard.object(forKey: ScratchLabDesktopDefaultsKey.mixerWidthRatio) as? Double ?? 0.17 {
        didSet {
            UserDefaults.standard.set(mixerWidthRatio, forKey: ScratchLabDesktopDefaultsKey.mixerWidthRatio)
        }
    }
    @Published private(set) var zoneAdjustments: [DJRigZone.Role: ZoneAdjustment] = MacCaptureEngine.loadZoneAdjustments() {
        didSet {
            guard !suppressZoneAdjustmentPersistence else { return }
            Self.persistZoneAdjustments(zoneAdjustments)
        }
    }
    /// When `true` the `didSet` observer on `zoneAdjustments` skips
    /// persistence.  Set during a drag gesture so UserDefaults is only
    /// written once on `.onEnded`, not on every pointer-move tick.
    var suppressZoneAdjustmentPersistence = false
    @Published private(set) var performerMonitorFrame: PerformerMonitorFrame?
    @Published var statusMessage = "Requesting camera and microphone access"
    @Published private(set) var directCaptureStatus = "Open your DJ app to prepare Direct Capture."
    @Published private(set) var directCaptureDeviceUID: String?
    @Published private(set) var isCameraActive = false
    /// True only after the capture session is actually running with the
    /// currently selected camera and audio inputs attached. `isCameraActive`
    /// is an optimistic UI state while permissions/configuration are in flight;
    /// recording actions must use this stricter readiness signal.
    @Published private(set) var isRoutineCaptureReady = false
    @Published private(set) var isRoutineRecording = false
    /// True while the asynchronous second half of routine finalization is still
    /// pending (admission closed, awaiting the admitted builder tasks). Prevents
    /// a second take from starting and re-opening the gate before the prior
    /// take's builder has been drained.
    private var isRoutineFinalizationPending = false
    @Published private(set) var routineRecordingStatus = "Pick camera and audio to record a routine."
    @Published private(set) var lastRoutineRecordingURL: URL?
    @Published private(set) var lastRoutineRecordingSessionID: String?
    @Published private(set) var routineTakeArtifactStatuses: [TakeArtifactStatusSnapshot] = []
    @Published private(set) var lastRoutineDetectedNotation: CaptureCore.DetectedNotationSnapshot?
    @Published private(set) var routineAudioBuffersReceived = 0
    @Published private(set) var routineAudioBuffersAppended = 0
    @Published private(set) var routineAudioBuffersSkipped = 0
    @Published private(set) var lastRoutineAudioWriterError: String?

#if DEBUG
    // Rane channel-map diagnostic (Phase 2). Developer-only: samples the live
    // capture device's raw multichannel stream and reports per-channel /
    // per-pair RMS, peak, DC, silence, clipping and a program-likelihood score
    // so the correct stereo program pair can be identified with hardware.
    @Published private(set) var isChannelMapDiagnosticRunning = false
    @Published private(set) var channelMapDiagnosticSnapshot: MultichannelSignalProbe.Snapshot?
    @Published private(set) var channelMapDiagnosticStatus =
        "Idle. Start the diagnostic, then play obvious program audio through the Rane."
    /// Guarded by `audioQueue`.
    private var channelMapDiagnosticActive = false
    private var channelMapDiagnosticChannels: [[Float]] = []
    private var channelMapDiagnosticFrames = 0
    private var channelMapDiagnosticSampleRate: Double = 0
    /// ~1.5 s at 48 kHz — enough to characterise a pair without a long wait.
    private let channelMapDiagnosticTargetFrames = 72_000
#endif

    // CXL notation capture
    let cxlRecorder = CXLNotationCaptureRecorder()
    @Published private(set) var cxlIsRecording = false
    @Published private(set) var cxlSessionId = ""
    @Published private(set) var cxlEventCount = 0
    @Published private(set) var cxlSampleCount = 0
    @Published private(set) var cxlLastExportPath: String?
    @Published private(set) var cxlLastExportError: String?

    let captureSession = AVCaptureSession()
    let calibrationOffsetRange: ClosedRange<Double> = -0.28...0.28
    let calibrationScaleRange: ClosedRange<Double> = 0.65...1.85
    let mixerWidthRange: ClosedRange<Double> = 0.10...0.30

    static let unavailableAudioPercent = "0%"

    var selectedAudioDeviceStatusLine: String {
        let selectedName = isSelectedAudioInputAvailable ? selectedAudioDeviceName : "No input found"
        return "\(audioReadinessText) — \(selectedName)\(isSelectedAudioInputAvailable ? " — \(audioSignalStatusText)" : "")"
    }

    /// Compact Advanced-only audio diagnostics. Device NAMES only — never
    /// UUIDs or file paths — so it stays safe even if surfaced. States
    /// exactly which input the running session attached vs. what is
    /// selected, so a silent mismatch is visible instead of guessed.
    var captureAudioDiagnosticsLine: String {
        let selectedName = isSelectedAudioInputAvailable ? selectedAudioDeviceName : "none"
        guard !activeCaptureAudioDeviceUniqueID.isEmpty else {
            return "Capture input: not attached · Selected: \(selectedName)"
        }
        let activeRaw = availableAudioDevices
            .first(where: { $0.uniqueID == activeCaptureAudioDeviceUniqueID })?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeDisplay = (activeRaw?.isEmpty == false)
            ? displayAudioDeviceName(activeRaw!)
            : "attached input"
        if activeCaptureAudioDeviceUniqueID != selectedAudioDeviceUniqueID {
            return "Capturing: \(activeDisplay) ⚠︎ selected “\(selectedName)” is not the attached input"
        }
        return "Capturing: \(activeDisplay) · \(audioSignalStatusText)"
    }

    var hasSeratoCaptureAudioDeviceAvailable: Bool {
        preferredSeratoAudioDevice(from: availableAudioDevices.map(Self.audioChoice(from:))) != nil
    }

    var shouldOfferUseSeratoAudio: Bool {
        guard let seratoDevice = preferredSeratoAudioDevice(from: availableAudioDevices.map(Self.audioChoice(from:))) else {
            return false
        }
        return seratoDevice.uniqueID != selectedAudioDeviceUniqueID
    }

    /// True only when the DVS/Serato capture input is the *selected* audio
    /// input. This is the platform fact that
    /// `CaptureLaneReadiness.isDVSRequired` needs; the rule itself is shared.
    /// Exactly the inverse condition of `shouldOfferUseSeratoAudio`, which
    /// offers the switch precisely because Serato is not selected.
    var isSeratoAudioSelected: Bool {
        guard let seratoDevice = preferredSeratoAudioDevice(from: availableAudioDevices.map(Self.audioChoice(from:))) else {
            return false
        }
        return seratoDevice.uniqueID == selectedAudioDeviceUniqueID
    }

    var selectedAudioDeviceName: String {
        let selectedName = availableAudioDevices
            .first(where: { $0.uniqueID == selectedAudioDeviceUniqueID })?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedName, !selectedName.isEmpty {
            return displayAudioDeviceName(selectedName)
        }
        return "Default audio input"
    }

    var selectedVideoDeviceName: String {
        let selectedName = availableVideoDevices
            .first(where: { $0.uniqueID == selectedVideoDeviceUniqueID })?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedName, !selectedName.isEmpty {
            return displayVideoDeviceName(selectedName)
        }
        return "Default camera"
    }

    var isSelectedAudioInputAvailable: Bool {
        availableAudioDevices.contains(where: { $0.uniqueID == selectedAudioDeviceUniqueID })
    }

    var currentAudioSignalLevel: Float {
        guard isSelectedAudioInputAvailable,
              hasPublishedAudioLevel,
              audioLevel.isFinite else { return 0 }
        return min(max(audioLevel, 0), 1)
    }

    var formattedAudioSignalPercent: String {
        Self.formattedAudioPercent(for: currentAudioSignalLevel, hasPublishedAudioLevel: true)
    }

    var currentOnboardOutputLevel: Float {
        min(max(onboardOutputLevel.isFinite ? onboardOutputLevel : 0, 0), 1)
    }

    var formattedOnboardOutputPercent: String {
        Self.formattedAudioPercent(
            for: currentOnboardOutputLevel,
            hasPublishedAudioLevel: isRoutineRecording,
            unavailablePlaceholder: "IDLE"
        )
    }

    var onboardOutputMeterColor: Color {
        let level = currentOnboardOutputLevel
        if level >= 0.98 { return Color(hex: "FF3B30") }
        if level >= 0.65 { return Color(hex: "4CAF50") }
        if level > 0.001 { return Color(hex: "FFC107") }
        return Color(hex: "9E9E9E")
    }

    var audioReadinessText: String {
        guard !availableAudioDevices.isEmpty else { return "Audio Missing" }
        guard !selectedAudioDeviceUniqueID.isEmpty else { return "Choose input" }
        guard isSelectedAudioInputAvailable else { return "Audio Missing" }
        return "Audio Ready"
    }

    var audioSignalStatusText: String {
        guard isSelectedAudioInputAvailable else { return "No input" }
        guard currentAudioSignalLevel > 0.001 else { return "No signal" }
        return "Signal \(formattedAudioSignalPercent)"
    }

    var formattedAudioPercent: String {
        formattedAudioSignalPercent
    }

    var practiceAudioStatusText: String {
        audioReadinessText
    }

    var practiceAudioStatusColor: Color {
        audioReadinessText == "Audio Ready" ? Color(hex: "4CAF50") : .secondary
    }

    var audioMeterColor: Color {
        let level = currentAudioSignalLevel
        guard level > 0.001 else { return Color(hex: "9E9E9E") }
        if level >= 0.65 { return Color(hex: "4CAF50") }
        if level >= 0.3 { return Color(hex: "FFC107") }
        return Color(hex: "FF7043")
    }

    static func formattedAudioPercent(
        for audioLevel: Float?,
        hasPublishedAudioLevel: Bool,
        unavailablePlaceholder: String = unavailableAudioPercent
    ) -> String {
        guard hasPublishedAudioLevel, let audioLevel, audioLevel.isFinite else {
            return unavailablePlaceholder
        }

        let clampedLevel = min(max(audioLevel, 0), 1)
        return "\(Int((clampedLevel * 100).rounded()))%"
    }

    var statusIcon: String {
        switch handMotionState {
        case .searching: return "dot.radiowaves.left.and.right"
        case .steady: return "hand.raised.fill"
        case .movingLeft, .movingRight: return "waveform.path.ecg"
        }
    }

    var statusColor: Color {
        handMotionState.color
    }

    var scratchStatusTitle: String {
        guard let lastScratchDetection else {
            return currentAudioSignalLevel > 0.03 ? "Processing" : "Ready"
        }

        if Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return "Baby Scratch Detected"
        }

        return currentAudioSignalLevel > 0.03 ? "Processing" : "Ready"
    }

    var scratchStatusDetail: String {
        guard let lastScratchDetection else {
            if currentAudioSignalLevel > 0.03 {
                return "Signal is live. Play a clean forward-and-back baby scratch and the analyzer will lock it."
            }
            return "Pick a routed deck source like a virtual device or interface loopback and start playback."
        }

        return "Last hit \(Int(lastScratchDetection.accuracy))% accuracy, \(Int(lastScratchDetection.confidence))% confidence. Session detections: \(scratchDetectionCount)."
    }

    var scratchStatusIcon: String {
        if let lastScratchDetection, Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return "waveform.badge.checkmark"
        }
        return currentAudioSignalLevel > 0.03 ? "waveform" : "waveform.slash"
    }

    var scratchStatusColor: Color {
        if let lastScratchDetection, Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 {
            return Color(hex: "4CAF50")
        }
        return currentAudioSignalLevel > 0.03 ? Color(hex: "00BCD4") : Color(hex: "9E9E9E")
    }

    var canUseDirectSeratoCapture: Bool {
        guard let directCaptureDeviceUID else { return false }
        return availableAudioDevices.contains { $0.uniqueID == directCaptureDeviceUID }
    }

    var isUsingDirectSeratoCapture: Bool {
        guard let directCaptureDeviceUID else { return false }
        return selectedAudioDeviceUniqueID == directCaptureDeviceUID
    }

    var babyScratchGuidanceTitle: String {
        switch handMotionState {
        case .searching:
            return "Show the scratch hand"
        case .steady:
            return "Ready for the next baby"
        case .movingLeft:
            return "Back stroke"
        case .movingRight:
            return "Forward stroke"
        }
    }

    var babyScratchGuidanceCue: String {
        switch handMotionState {
        case .searching:
            return "Place hand over the record"
        case .steady:
            return "Start a smooth sweep"
        case .movingLeft:
            return "Back — now reverse forward"
        case .movingRight:
            return "Forward — now reverse back"
        }
    }

    var babyScratchGuidanceDetail: String {
        switch handMotionState {
        case .searching:
            return "Keep the scratching hand visible above one deck so ScratchLab can read the baby-scratch direction."
        case .steady:
            return "Hand tracking is live. Make one clean forward sweep, then reverse back for the baby scratch."
        case .movingLeft:
            return "Back stroke detected (\(coachConfidenceSourcePhrase)). Reverse forward on the next stroke to complete the baby scratch."
        case .movingRight:
            return "Forward stroke detected (\(coachConfidenceSourcePhrase)). Reverse back on the next stroke to complete the baby scratch."
        }
    }

    /// Confidence percentage from the direction tracker (0-100).
    var coachConfidencePercent: Int {
        let baseConfidence = Int((handDirectionTracker.confidence * 100).rounded())
        guard hasActiveCoachMotion,
              let audioConfidence = recentAudioScratchConfidence else {
            return baseConfidence
        }

        let conservativeAudioBoost = min(10, Int((audioConfidence * 0.10).rounded()))
        return min(100, baseConfidence + conservativeAudioBoost)
    }

    /// Human-readable signal source for the current coach state.
    /// "Fused" = camera motion and recent audio onset both active.
    /// Audio alone does not drive direction — it only confirms activity.
    var coachSignalSource: String {
        let recentAudio = recentAudioScratchConfidence != nil
        if hasActiveCoachMotion && recentAudio { return "Fused" }
        if recentAudio { return "Audio" }
        if handDetected { return "Camera" }
        return "Searching"
    }

    private var hasActiveCoachMotion: Bool {
        handMotionState == .movingLeft || handMotionState == .movingRight
    }

    private var recentAudioScratchConfidence: Double? {
        guard let lastScratchDetection,
              Date().timeIntervalSince(lastScratchDetection.detectedAt) <= 1.5 else {
            return nil
        }
        return lastScratchDetection.confidence
    }

    private var coachConfidenceSourcePhrase: String {
        let source = coachSignalSource.lowercased()
        guard coachConfidencePercent > 0 else { return source }
        return "\(coachConfidencePercent)% confidence, \(source)"
    }

    var visibleStarCount: Int {
        min(sessionStars, 5)
    }

    var routineRecordingsFolderURL: URL? {
        try? recordingsDirectoryURL()
    }

    func rescanRoutineCaptures() {
        recoverInterruptedRoutineCaptures()
        restoreLatestCompletedRoutineCapture()
        refreshRoutineArtifactStatuses()
    }

    var selectedVideoDevice: AVCaptureDevice? {
        availableVideoDevices.first(where: { $0.uniqueID == selectedVideoDeviceUniqueID })
    }

    func reserveNextRoutineTakeIdentity() throws -> TakeIdentity {
        let directory = try recordingsDirectoryURL()
        let sessionID = recordingSessionConfig?.sessionID ?? CaptureCore.LocalRecordingNaming.sessionID()
        let takeNumber = try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber)
        pendingRoutineTakeIdentity = takeIdentity
        return takeIdentity
    }

    func applyPendingWatchReply(_ reply: WatchCaptureControlReply?) {
        pendingWatchReply = reply
    }

    @MainActor
    func recordWatchRelayInterruption(_ interruption: WatchRelayInterruption) {
        guard let context = interruption.context else { return }
        if var sidecar = activeRoutineRecordingSidecar,
           sidecar.sessionID == context.sessionID,
           sidecar.takeID == context.takeID,
           let sidecarURL = activeRoutineRecordingSidecarURL {
            sidecar = sidecar.withWatchRelayInterruption(
                interruption.detail,
                recordedAt: interruption.occurredAt
            )
            do {
                try writeRoutineRecordingSidecar(sidecar, to: sidecarURL)
                activeRoutineRecordingSidecar = sidecar
            } catch {
                reportRoutineRecordingIssue("Watch relay interruption could not be saved to the take diagnostics.")
            }
            return
        }

        guard pendingRoutineTakeIdentity?.sessionID == context.sessionID,
              pendingRoutineTakeIdentity?.takeID == context.takeID else { return }
        pendingWatchReply = WatchCaptureControlReply(
            commandID: pendingWatchReply?.commandID ?? "watch-relay-interruption",
            sessionID: context.sessionID,
            takeID: context.takeID,
            syncState: .failed,
            detail: interruption.detail,
            acknowledgedAt: interruption.occurredAt
        )
    }

    @MainActor
    func cancelPendingRoutineReservation() -> TakeIdentity? {
        let pendingIdentity = pendingRoutineTakeIdentity
        pendingRoutineTakeIdentity = nil
        pendingWatchReply = nil
        return pendingIdentity
    }

    var selectedVideoSourceDescription: String {
        guard let device = selectedVideoDevice else { return "No camera selected" }
        if isDeskViewCamera(device) {
            return "Desk View"
        }
        if isBuiltInMacCamera(device) {
            return "Built-in camera"
        }
        if isPhoneContinuityCamera(device) {
            return "External camera"
        }
        return "External camera"
    }

    var isUsingMacCameraForDesktopDeck: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isBuiltInMacCamera(device)
    }

    var hasDeskViewCameraOption: Bool {
        availableVideoDevices.contains(where: isDeskViewCamera)
    }

    var isUsingDeskViewCamera: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isDeskViewCamera(device)
    }

    var isUsingContinuityCamera: Bool {
        guard let device = selectedVideoDevice else { return false }
        return isPhoneContinuityCamera(device)
    }

    var showRigGuides: Bool {
        !calibrationLocked
    }

    func zoneAdjustment(for role: DJRigZone.Role) -> ZoneAdjustment {
        zoneAdjustments[role] ?? .identity
    }

    func updateZoneAdjustment(for role: DJRigZone.Role, mutate: (inout ZoneAdjustment) -> Void) {
        var updated = zoneAdjustment(for: role)
        mutate(&updated)
        setZoneAdjustment(updated, for: role)
    }

    /// Like `updateZoneAdjustment` but skips the UserDefaults persistence
    /// that normally fires on every assignment.  Use during drag gestures
    /// so the disk write only happens once on `.onEnded`.
    func updateZoneAdjustmentTransient(for role: DJRigZone.Role, mutate: (inout ZoneAdjustment) -> Void) {
        suppressZoneAdjustmentPersistence = true
        updateZoneAdjustment(for: role, mutate: mutate)
        suppressZoneAdjustmentPersistence = false
    }

    /// Persist the current in-memory zone adjustments to UserDefaults.
    /// Call this on drag-end to commit the final position.
    func persistCurrentZoneAdjustments() {
        Self.persistZoneAdjustments(zoneAdjustments)
    }

    func resetZoneAdjustments() {
        zoneAdjustments = [:]
    }

    func resetCalibration() {
        rigHorizontalOffset = 0
        rigVerticalOffset = 0
        rigWidthScale = 1
        rigHeightScale = 1
        mixerWidthRatio = 0.17
        resetZoneAdjustments()
        videoQueue.async {
            self.clearFixedRigLayout(prioritizeDetection: true)
            self.resetPublishedVideoState()
        }
        Task { @MainActor in
            self.rigLayout = nil
            self.isUsingManualRigGuide = false
        }
    }

    var rigStatusTitle: String {
        guard let rigLayout else {
            return "Rig guide waiting"
        }

        if isUsingManualRigGuide {
            return "Deck estimate in use"
        }

        if rigLayout.confidence >= 0.65 {
            return "Decks and mixer recognized"
        }

        return "Rig outline is forming"
    }

    var rigStatusDetail: String {
        guard rigLayout != nil else {
            return "Show the left deck, mixer, and right deck in one shot. The overlay will split the rig into playable zones."
        }

        if isUsingManualRigGuide {
            return "Hand tracking is using your saved deck position. Recalibrate if tracking feels off."
        }

        return "Recognition active. Perform clean scratches to progress. Use Deck Calibration if the layout drifts."
    }

    private let sessionQueue = DispatchQueue(label: "scratchlab.mac.capture.session")
    private let videoQueue = DispatchQueue(label: "scratchlab.mac.capture.video")
    private let audioQueue = DispatchQueue(label: "scratchlab.mac.capture.audio")
    private let performerMonitorDemandQueue = DispatchQueue(label: "scratchlab.mac.capture.performer-demand")
    /// Background serial queue for the asynchronous second half of routine-take
    /// finalization. `builderAdmissionGate` completion is notified here (never
    /// on the main queue) so the main queue / MainActor is never blocked waiting
    /// for the admitted `@MainActor` builder tasks.
    private let finalizationQueue = DispatchQueue(label: "scratchlab.mac.capture.finalize")
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let scratchDetector = MacScratchDetector()
    private let rigLayoutDetector = DJRigLayoutDetector()
    private let handDirectionTracker = HandDirectionTracker()
    /// Phase 3.1 — sibling raw-platter producer. Observes the same
    /// `(rawPoint, time)` samples `handDirectionTracker.recordObservation`
    /// receives, integrates them into a `PlatterPositionTimeline`, and
    /// drains the timeline at end-of-take. Does NOT modify the tracker.
    /// In-memory only — the v4 export schema is unchanged.
    private let platterPositionRecorder = PlatterPositionRecorder()
    /// Host-time anchor for the active routine recording. Set in
    /// `startRoutineRecording`, reset on drain in `finalizeRoutineRecording`.
    /// Take-relative time for each platter sample = `now - platterRecordingStartTime`.
    private var platterRecordingStartTime: CFTimeInterval = 0
    /// Most recently drained raw-platter timeline. Cleared at the start
    /// of each new routine recording so a stale value never appears
    /// alongside a fresh capture's classified events.
    private(set) var lastDrainedPlatterPositionTimeline: PlatterPositionTimeline?
    /// Funnels every recorder access through a single lock — the
    /// recorder itself is not thread-safe and gets touched by
    /// `sessionQueue` (start), `videoQueue` (observe), and the
    /// AVCaptureFileOutput delegate queue (drain). Mirrors the
    /// `midiCaptureLock` pattern already used for raw MIDI events.
    private let platterRecorderLock = NSLock()
    /// Per-take builder admission gate. Replaces a bare `DispatchGroup`: video
    /// processing keeps running during finalization, so admission and closing
    /// must share one lock so no `enter()` can escape the barrier. `wait()` is
    /// called on the AVCaptureFileOutput delegate queue (never MainActor), so it
    /// cannot block the MainActor waiting for itself.
    private let builderAdmissionGate = BuilderAdmissionGate()

#if DEBUG
    // MARK: - DVS notation slice 2 (implementation plan, planning-only slice
    // recorded in TASKS.md/AI_HANDOFF.md) — accumulates trusted decoded DVS
    // motion into notation during a routine take, entirely independent of
    // DVS playback (`dvsPlaybackDriveActive`/`forwardTimecodeDrive`). No UI
    // control sets `notationRoutingEnabled` yet — it exists so this wiring
    // can be exercised ahead of any user-facing toggle, matching "keep
    // playback override and notation routing off until explicitly
    // approved." `DetectedNotationSnapshot`/the v4 export schema are NOT
    // touched here — that is a later slice's explicit scope.

    /// Whether decoded DVS motion should be accumulated into notation
    /// during routine take recording. Defaults to `false`. Deliberately a
    /// separate stored property from `dvsPlaybackDriveActive` — there is no
    /// code path connecting the two, so enabling one can never enable the
    /// other. `TimecodeNotationTrustGate.evaluate` never reads or sets
    /// playback state either (proven in `TimecodeNotationRoutingTests
    /// .testTrustGateNeverReadsOrTouchesPlaybackBridgeState`), so this
    /// independence holds end to end, not just at this single flag.
    var notationRoutingEnabled = false

    /// Accumulates trusted DVS timeline windows for the duration of one
    /// routine take. `nil` when not recording, notation routing is off, or
    /// no trusted window has arrived yet this take. Lazily anchored to the
    /// first trusted window's own sample time (the pipeline's decode clock
    /// domain, not `CACurrentMediaTime()` — DVS timestamps come from audio
    /// buffer decode timing, a different clock than the camera-based
    /// `platterPositionRecorder` uses) rather than a fixed start-of-take
    /// timestamp, so rebasing stays correct regardless of when the first
    /// trusted window happens to land within the take.
    private var timecodeNotationAccumulator: TimecodeNotationTimelineAccumulator?

    /// Funnels every accumulator access through a single lock, mirroring
    /// `platterRecorderLock` — the accumulator is touched by whichever
    /// queue the DVS control loop's tick handler runs on and drained on
    /// the AVCaptureFileOutput delegate queue.
    private let timecodeNotationLock = NSLock()

    /// Protected by `timecodeNotationLock`; exposed to the live panel only
    /// through the immutable snapshot below.
    private var timecodeNotationDiagnosticsStorage = TimecodeNotationDiagnostics()

    var timecodeNotationDiagnostics: TimecodeNotationDiagnostics {
        timecodeNotationLock.lock()
        defer { timecodeNotationLock.unlock() }
        return timecodeNotationDiagnosticsStorage
    }

    /// Most recently drained DVS notation timeline. In-memory diagnostic
    /// only, mirroring `lastDrainedPlatterPositionTimeline`'s role for the
    /// camera-based recorder — not wired into `DetectedNotationSnapshot`
    /// or export (a later slice's scope). Cleared at the start of each new
    /// routine recording so a stale value never lingers.
    private(set) var lastDrainedTimecodeNotationTimeline: PlatterPositionTimeline?
#endif

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
#if ENABLE_TIMECODE_LIVE_TAP
    /// Dedicated low-latency input path for control vinyl. The ordinary
    /// AVCapture audio output remains authoritative for routine recording;
    /// only the DEBUG DVS callback uses this `AVAudioSinkNode`-based path.
    private let timecodeInputEngine = AVAudioEngine()
    private let timecodeInputStateLock = NSLock()
    private var timecodeInputTapHeartbeat = LowLatencyTimecodeTapHeartbeat()
    /// Read once per bind in `refreshLowLatencyTimecodeInput()` — the
    /// device's own buffer-size/latency configuration doesn't change
    /// per-callback the way the heartbeat does, so this is captured once
    /// and republished alongside the heartbeat text on every diagnostic
    /// update rather than re-queried on every callback.
    private var timecodeInputBufferDiagnostic: AudioDeviceBufferFrameSizeDiagnostic?
    /// Owns the pure start/stop sequencing (generation tracking, sink-
    /// attached/heartbeat-installed/current-session bookkeeping) for the
    /// low-latency DVS sink-node path — see `LowLatencySinkLifecycle`. Only
    /// ever driven from `sessionQueue` (`refreshLowLatencyTimecodeInput()`/
    /// `stopLowLatencyTimecodeInput()`), matching `timecodeInputEngine`'s own
    /// access discipline.
    private let lowLatencySinkLifecycle = LowLatencySinkLifecycle()
    /// Thread-safe mirror of `lowLatencySinkLifecycle.currentSession`,
    /// updated immediately after every `start`/`stop` call on `sessionQueue`.
    /// Always accessed under `timecodeInputStateLock`: read from the
    /// worker's own private queue (`handleLowLatencySinkDelivery`'s
    /// diagnostic publish) and from the legacy capture path's queue
    /// (`processAudioSampleBuffer`'s heartbeat freshness check, which also
    /// republishes this diagnostic).
    private var currentLowLatencySinkSession: LowLatencySinkSession?
    /// The real `AVAudioSinkNode` currently attached to `timecodeInputEngine`,
    /// or `nil`. Torn down together with the lifecycle's session in
    /// `stopLowLatencyTimecodeInput()`. Only ever touched from `sessionQueue`
    /// — the same access discipline `timecodeInputEngine` itself already
    /// has — never from the worker queue or the realtime callback.
    private var currentLowLatencySinkNode: AVAudioSinkNode?
    /// Raw worker-observed evidence (frame/channel count, sample rate) for
    /// the most recently drained slot — updated on every delivery from
    /// `handleLowLatencySinkDelivery`, regardless of whether adapter
    /// conversion succeeds. Always accessed under `timecodeInputStateLock`.
    private var timecodeInputWorkerObservationDiagnostic: LowLatencySinkWorkerObservationDiagnostic?
#endif
    private let performerMonitorCIContext = CIContext()
    private let seratoBundleIdentifiers = ["com.serato.seratodj"]
    private let seratoVirtualAudioDeviceName = "Serato Virtual Audio"
    private let seratoDirectCaptureDeviceName = "ScratchLab Direct Serato"
    private let seratoDirectCaptureDeviceUIDValue = "com.machelpnz.scratchlab.mac.serato-direct-capture"

#if ENABLE_TIMECODE_LIVE_TAP
    /// Optional callback for the timecode live audio tap.
    ///
    /// Set from the UI layer (MacAnalyzerView) when the timecode live
    /// tap is enabled; cleared when the timecode section disappears.
    ///
    /// Called on `audioQueue` with separate left/right Float32 channel
    /// data normalised to [-1, +1].
    ///
    /// **Batch 4:** DEBUG/prototype only. Stripped from Release builds.
    var timecodeAudioCallback: ((_ left: [Float], _ right: [Float], _ sampleRate: Double, _ hostTime: UInt64?) -> Void)? {
        didSet {
            sessionQueue.async { [weak self] in
                self?.refreshLowLatencyTimecodeInput()
            }
        }
    }
#endif

    private var isRunning = false
    /// When true, live Vision hand-pose processing, audio-level publishing,
    /// scratch detection, platter observing, and diagnostics accumulation
    /// are suspended.  Recording (if active) is NOT suspended — the guard
    /// in `shouldProcessCaptureSamples` always permits recording.
    /// Set by the Review tab to drop idle CPU while the user reviews takes.
    private var isLiveInputSuspendedForReview = false
    private let idleHandPoseInterval: CFTimeInterval = 0.12
    private let routineRecordingHandPoseInterval: CFTimeInterval = 0.04
    /// The shared, non-UI camera movement processor (cadence → stable anchor →
    /// platter geometry → angular tracker → builder observation). Used by live
    /// capture AND offline replay, so tracking/notation logic is not duplicated.
    private var cameraProcessor = CameraMovementProcessor()
    /// True when the current frame lacked a reliable platter centre, so the
    /// camera cannot contribute directional notation (fail-closed — never a
    /// silent fallback to raw X).
    private(set) var cameraPlatterCalibrationInsufficient = false
    private var lastPerformerMonitorFrameTime: CFTimeInterval = 0
    private let audioLevelPublishInterval: CFTimeInterval = 0.05
    private var lastPublishedAudioLevelTime: CFTimeInterval = 0
    private var smoothedHandPoint: CGPoint?
    private var missedHandTrackingFrames = 0
    private let standardJointConfidenceThreshold: Float = 0.16
    private let recordingJointConfidenceThreshold: Float = 0.07
    private let platterContinuityGapSeconds: CFTimeInterval = 0.15
    private let maxPlatterJumpVelocity: Double = 4.5
    private var lastContinuityHandPoint: CGPoint?
    private var lastContinuityHandPointTime: CFTimeInterval = 0
    #if DEBUG
    @Published private(set) var routineMovementDiagnostics: RoutineMovementDiagnosticsSnapshot?
    @Published private(set) var frozenReviewDiagnostics: DebugStats?
    private var activeRoutineMovementDebugSession: RoutineMovementDebugSession?
    private var debugLastRawDirection: HandDirectionTracker.Direction = .idle
    /// Per-observation movement trace recorder. Frozen at take finalization and
    /// exported as `debug/take-N_movement_trace.json` so the exact live
    /// observation stream (raw points, misses, timestamps, dedup, builder
    /// inputs) is available for offline replay — not just aggregate counters.
    private let movementTraceRecorder = MovementTraceRecorder()
    /// Host-time anchor captured at recording start, used to produce
    /// take-relative trace timestamps.
    private var movementTraceRecordingStartHostTime: Double = 0
    /// Frozen at take finalization; drained by the export companion writer so a
    /// later take cannot overwrite the trace/diagnostics of an earlier one.
    private(set) var lastMovementTraceExport: MovementTraceExport?
    private(set) var lastMovementDiagnosticsSnapshot: RoutineMovementDiagnosticsSnapshot?
    #endif

    #if DEBUG
    private var debugFramesReceived = 0
    private var debugFramesAnalyzed = 0
    private var debugHandObservationsFound = 0
    private var debugDirectionChanges = 0
    private var debugMissedFrameCount = 0
    private var debugVisionReturnedHand = 0
    private var debugTrackedPointReturnedNil = 0
    private var debugTrackedPointReturnedPoint = 0
    private var debugJointsInspectedTotal = 0
    private var debugJointsRejectedLowConfidence = 0
    private var debugJointsRejectedOutsideROI = 0
    private var debugJointsAcceptedCandidates = 0
    private var debugObserveSkippedNotRecording = 0
    private var debugObserveAttempted = 0
    private var debugMidiEventsCapturedThisTake = 0
    private var debugLastROI: CGRect = .zero
    private var debugJointsRelaxedAccepted = 0
    private var debugContinuityFilledSamples = 0
    private var debugImpossibleJumpRejects = 0
    #endif
    private var lastStarAwardAt: Date?
    private var lastPublishedRigLayout: DJRigLayout?
    private var lastPublishedUsesManualRigGuide = false
    private var lastPublishedHandDetected = false
    private var lastPublishedHandPosition: CGPoint?
    private var lastPublishedHandMotionState: HandMotionState = .searching
    private var performerMonitorStreamingEnabled = false
    private var seratoDirectCaptureTapID = AudioObjectID(0)
    private var seratoDirectCaptureAggregateDeviceID = AudioObjectID(0)
    private var seratoDirectCaptureProcessIdentifiers: [pid_t] = []
    private var directCaptureRoute: DirectCaptureRoute?
    var recordingSessionConfig: CaptureSessionConfig?
    private var activeRoutineRecordingSidecar: CaptureCore.LocalRecordingSidecar?
    private var activeRoutineRecordingSidecarURL: URL?
    private var pendingRoutineOutputAudioURL: URL?
    private var activeRoutineAudioCaptureWriter: RoutineAudioCaptureWriter?
    private var activeRoutineAudioNotationDetector: ScratchAudioNotationDetector?
    private var activeRoutineDetectedNotationBuilder: RoutineDetectedNotationBuilder?
    private var midiClient: MIDIClientRef = 0
    private var midiInputPort: MIDIPortRef = 0
    private var midiSourceEndpoints: [MIDIInputSourceChoice: MIDIEndpointRef] = [:]
    private var capturedMidiCCEvents: [CaptureCore.RawMixerMIDIEvent] = []
    private let midiCaptureLock = NSLock()
    private var midiRecordingStartTime: CFTimeInterval = 0
    private var midiConnectedSourceName: String = ""
    /// MIDI monitor UI-publish throttle: all incoming MIDI CC events are
    /// still captured at full fidelity; only the @Published SwiftUI
    /// monitor properties below are rate-limited to ~4 Hz so the main
    /// actor isn't flooded with ~310 string-format + objectWillChange
    /// emissions per second during active controller input.
    private var lastMidiMonitorPublishTime: CFTimeInterval = 0
    private var batchedMidiEventCount: Int = 0
    private var batchedMidiCCMessage: String = ""
    private var batchedMidiSummary: String = "No MIDI received yet"
    private let midiMonitorPublishInterval: CFTimeInterval = 0.25
    /// True while a coalesced MIDI-monitor publish is already queued on main.
    /// Gates re-entry so at most one `DispatchQueue.main.async` is ever
    /// pending for this channel — the queued block re-reads the batched state
    /// at execution time, so later events are folded into it rather than
    /// queuing additional blocks.
    private var isMidiMonitorPublishPending: Bool = false
    private var lastScratchPlaybackBridgeLogTime: CFTimeInterval = 0
    private let scratchPlaybackBridgeLogInterval: CFTimeInterval = 0.10
    private var lastSwiftUIStateGuardLogTime: CFTimeInterval = 0
    private let swiftUIStateGuardLogInterval: CFTimeInterval = 1.0
    /// Plain, lock-protected MIDI Learn session storage — the CoreMIDI-thread-
    /// safe source of truth. `nil` when idle. Deliberately NOT `@Published`:
    /// only ever read/written under `midiCaptureLock`, never touching
    /// SwiftUI/Combine machinery (which is not safe to touch from CoreMIDI).
    /// `activeMIDILearnAction` below is a separate, main-thread-only mirror
    /// for the UI.
    private var learnSessionAction: MIDISemanticAction? = nil
    /// Generation/request ID for the active learn session — bumped every time
    /// a session starts, is claimed, or is cancelled, so stale async work
    /// (e.g. a queued "no MIDI received" warning) can detect it no longer
    /// applies. Lock-protected alongside `learnSessionAction`.
    private var midiLearnRequestID: UInt64 = 0
    private var persistedCrossfaderMapping: CrossfaderCCMapping? = nil
    private var pendingRoutineTakeIdentity: TakeIdentity?
    private var pendingWatchReply: WatchCaptureControlReply?
    private var routineArtifactRefreshTask: Task<Void, Never>?
    private var fixedRigLayout: DJRigLayout?
    private var fixedRigLayoutUsesManualGuide = false
    private let autoRefreshDevicesAfterViewMount: Bool
    /// Keeps hosted XCTest processes from overwriting the real app's selected
    /// controller with synthetic `midi_test_*` identifiers. Production uses
    /// `.standard`; tests get a process-local suite while retaining normal
    /// persistence semantics between engine instances in the same test run.
    private let midiSelectionDefaults: UserDefaults
    /// Keeps the legacy crossfader mapping on the production app domain unless
    /// a caller explicitly injects a fully isolated MIDI defaults store.
    private let midiPersistenceDefaults: UserDefaults
    private var hasStartedDeviceDiscoveryAfterViewMount = false
    private let audioSignalStaleInterval: CFTimeInterval = 0.8
    private let audioSignalDecayPollInterval: CFTimeInterval = 0.25
    private var lastReceivedAudioSampleTime: CFTimeInterval = 0
    private var audioSignalDecayTimer: DispatchSourceTimer?
    private enum AudioSelectionOrigin {
        case automatic
        case explicitUserChoice
    }

    private var pendingAudioSelectionOrigin: AudioSelectionOrigin = .automatic
    private var hasExplicitUserAudioSelection = UserDefaults.standard.bool(forKey: ScratchLabDesktopDefaultsKey.selectedAudioDeviceWasExplicit)
    private static let routineSidecarDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    override init() {
        let midiSelectionDefaults = Self.makeMIDISelectionDefaults()
        let audioOwnershipMode = ScratchAudioOwnershipMode.load(from: .standard)
        autoRefreshDevicesAfterViewMount = true
        self.midiSelectionDefaults = midiSelectionDefaults
        midiPersistenceDefaults = .standard
        scratchPlaybackController = ScratchSamplePlaybackController()
        scratchAudioOwnershipMode = audioOwnershipMode
        audioOwnershipModeStorage = audioOwnershipMode
        selectedMIDIInputSourceID = midiSelectionDefaults.string(
            forKey: ScratchLabDesktopDefaultsKey.selectedMIDIInputSourceID
        ) ?? ""
        super.init()
        configureInitialState()
    }

    init(
        autoRefreshDevices: Bool,
        midiDefaults: UserDefaults? = nil,
        sampleResourceRoot: URL? = Bundle.main.resourceURL
    ) {
        let midiSelectionDefaults = midiDefaults ?? Self.makeMIDISelectionDefaults()
        let audioOwnershipMode = ScratchAudioOwnershipMode.load(from: midiDefaults ?? .standard)
        autoRefreshDevicesAfterViewMount = autoRefreshDevices
        self.midiSelectionDefaults = midiSelectionDefaults
        midiPersistenceDefaults = midiDefaults ?? .standard
        scratchPlaybackController = ScratchSamplePlaybackController(
            sampleResourceRoot: sampleResourceRoot
        )
        scratchAudioOwnershipMode = audioOwnershipMode
        audioOwnershipModeStorage = audioOwnershipMode
        selectedMIDIInputSourceID = midiSelectionDefaults.string(
            forKey: ScratchLabDesktopDefaultsKey.selectedMIDIInputSourceID
        ) ?? ""
        super.init()
        configureInitialState()
    }

    private static func makeMIDISelectionDefaults(
        processInfo: ProcessInfo = .processInfo
    ) -> UserDefaults {
        guard processInfo.environment["XCTestConfigurationFilePath"] != nil,
              let isolatedDefaults = UserDefaults(
                suiteName: "com.machelpnz.scratchlab.tests.midi-selection.\(processInfo.processIdentifier)"
              ) else {
            return .standard
        }
        return isolatedDefaults
    }

    func setScratchAudioOwnershipMode(_ mode: ScratchAudioOwnershipMode) {
        audioOwnershipLock.lock()
        audioOwnershipModeStorage = mode
        audioOwnershipLock.unlock()
        mode.persist(to: midiPersistenceDefaults)
        if !mode.allowsLocalScratchPlayback {
            scratchPlaybackController.unload()
            scratchPlaybackController.waitForAudioQueue()
        }
        publishOnMainAsync(field: "scratchAudioOwnershipMode") { [weak self] in
            guard let self else { return }
            self.scratchAudioOwnershipMode = mode
            self.platterTestLoadStatus = mode.allowsLocalScratchPlayback
                ? "Standalone audio enabled — load AHHH to arm the platter."
                : mode.detail
        }
    }

    private func configureInitialState() {
        scratchPlaybackController.routineOutputLevelHandler = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.onboardOutputLevel = level
                if self.isRoutineRecording {
                    self.onboardOutputCaptureStatus = level >= 0.98
                        ? "Onboard output is clipping. Reduce ScratchLab output level."
                        : level > 0.001
                            ? "Recording ScratchLab's onboard AHHH output."
                            : "Recording is armed, but onboard AHHH is currently silent."
                }
            }
        }
        handPoseRequest.maximumHandCount = 1
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        movieOutput.movieFragmentInterval = .invalid
        startAudioSignalDecayTimer()

        // Scratch bank pad → diagnostic preview event only (2026-08-13 dedup
        // fix). This legacy hardcoded pad mapping (`ScratchBankPadEventRouter`)
        // and the learned production hot-cue mapping
        // (`resolveAndLoadHotCueSample`, called right after this callback
        // fires in both the CC and Note On routes) cover the exact same
        // ch4/ch5 CC/note 20–27 range on real Rane hardware, so once a
        // hot-cue is learned, every pad press matched both routes and
        // loaded the sample twice. `resolveAndLoadHotCueSample` is now the
        // single authoritative loader; this closure only logs so the
        // firing itself (used by pad-label diagnostics and tests) is
        // unchanged.
        scratchBankPadPreviewCallback = { sampleID in
            print("[RanePad] preview event (no load) · sampleID=\(sampleID)")
        }

        // Right-deck (channel 1) MIDI continuous platter drive (2026-08-09):
        // the single loaded scratch sample is owned exclusively by the Rane
        // ONE MKII right platter / Deck 2, per product decision. The
        // coalescing timer inside `scratchPlaybackController` samples this
        // provider on its own bounded cadence — it never reads the left
        // deck (channel 0), which stays tracked/diagnostic-only.
        scratchPlaybackController.configureMIDIPlatterProvider(
            rightDeckAccumulatedSteps: { [platterTracker] in
                platterTracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
            }
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceApplicationChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceApplicationChange(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        if let data = midiPersistenceDefaults.data(forKey: ScratchLabDesktopDefaultsKey.crossfaderMIDIMapping),
           let mapping = try? JSONDecoder().decode(CrossfaderCCMapping.self, from: data) {
            crossfaderCCMapping = mapping
            midiLearnState = .learned(mapping)
            persistedCrossfaderMapping = mapping
        }

        setupMIDIClient()
    }

    @MainActor
    func startDeviceDiscoveryAfterViewMount() async {
        guard autoRefreshDevicesAfterViewMount else { return }
        guard !hasStartedDeviceDiscoveryAfterViewMount else { return }
        hasStartedDeviceDiscoveryAfterViewMount = true

        await Task.yield()

        if let mapping = persistedCrossfaderMapping {
            publishOnMainAsync(field: "midiLearn.initialMapping") { [weak self] in
                guard let self,
                      self.midiLearnState != .learned(mapping) else { return }
                self.crossfaderCCMapping = mapping
                self.midiLearnState = .learned(mapping)
            }
        }

        rescanRoutineCaptures()
        refreshDevices()
    }

    deinit {
        audioSignalDecayTimer?.cancel()
        playbackPositionPollTimer?.cancel()
#if ENABLE_TIMECODE_LIVE_TAP
        stopLowLatencyTimecodeInput()
#endif
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        destroySeratoDirectCapture()
        if midiInputPort != 0 { MIDIPortDispose(midiInputPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isCameraActive = true
        isRoutineCaptureReady = false
        resetAudioSignalLevel()
        refreshDevices()
        requestPermissionsAndConfigure()
        startPlaybackPositionPoll()
    }

    func stop() {
        isRunning = false
        playbackPositionPollTimer?.cancel()
        playbackPositionPollTimer = nil
        playbackPositionSnapshot = nil
        playbackWaveformSnapshot = nil
        isCameraActive = false
        isRoutineCaptureReady = false
        activeCaptureAudioDeviceUniqueID = ""
        scratchDetector.reset()
        rigLayoutDetector.reset()
        handDirectionTracker.reset()
        setPerformerMonitorStreamingEnabled(false)
        lastScratchDetection = nil
        scratchDetectionCount = 0
        rigLayout = nil
        isUsingManualRigGuide = false
        highlightedZoneRole = .leftDeck
        sessionStars = 0
        smoothedHandPoint = nil
        missedHandTrackingFrames = 0
        performerMonitorFrame = nil
        lastStarAwardAt = nil
        #if DEBUG
        activeRoutineMovementDebugSession = nil
        publishRoutineMovementDiagnostics(nil)
        frozenReviewDiagnostics = nil
        debugLastRawDirection = .idle
        #endif
        resetAudioSignalLevel()
#if ENABLE_TIMECODE_LIVE_TAP
        stopLowLatencyTimecodeInput()
#endif
        videoQueue.async {
            self.clearFixedRigLayout()
            self.resetPublishedVideoState()
        }
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.activeRoutineDetectedNotationBuilder = nil
            self.activeRoutineAudioNotationDetector = nil
            // Diagnostics survive across recording stop — captureOutput didFinishRecordingTo
            // publishes the final snapshot. They are reset at the start of the next recording.
            self.audioQueue.async {
                self.activeRoutineAudioCaptureWriter = nil
                self.publishRoutineAudioCaptureDiagnostics(nil)
            }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
        lastRoutineDetectedNotation = nil
    }

    func setPerformerMonitorStreamingEnabled(_ enabled: Bool) {
        performerMonitorDemandQueue.sync {
            performerMonitorStreamingEnabled = enabled
        }

        guard !enabled else { return }
        Task { @MainActor in
            if self.performerMonitorFrame != nil {
                self.performerMonitorFrame = nil
            }
        }
    }

    /// Suspends or resumes live Vision hand-pose processing, audio-level
    /// publishing, scratch detection, platter observing, diagnostics
    /// accumulation, and MIDI monitor UI updates when the Review tab is
    /// active — but NEVER suspends an active routine recording.
    ///
    /// On suspend: stale hand-tracking state is cleared so Review doesn't
    /// show a frozen hand position.  On resume: tracking restarts from
    /// scratch (next Vision frame picks it up).
    func setLiveInputSuspendedForReview(_ suspended: Bool) {
        guard suspended != isLiveInputSuspendedForReview else { return }
        isLiveInputSuspendedForReview = suspended
        if suspended {
            // Clear stale hand-tracking state so Review doesn't show
            // a frozen hand position from the last live frame.
            videoQueue.async { [weak self] in
                self?.resetPublishedVideoState()
            }
            Task { @MainActor [weak self] in
                self?.handDetected = false
                self?.handPosition = nil
                self?.handMotionState = .searching
            }
        }
        // On resume: shouldProcessCaptureSamples re-enables Vision +
        // audio processing on the next incoming frame.  No explicit
        // "restart" needed — the capture session keeps running.
    }

    func resetScratchRatingSession() {
        audioQueue.async {
            self.scratchDetector.reset()
            self.lastPublishedAudioLevelTime = 0
        }

        Task { @MainActor in
            self.resetAudioSignalLevel()
            self.lastScratchDetection = nil
            self.scratchDetectionCount = 0
            self.highlightedZoneRole = .leftDeck
            self.sessionStars = 0
            self.lastStarAwardAt = nil
        }
    }

    // MARK: - CXL notation capture

    func startCXLCapture(
        scratchType: String = "baby_scratch",
        mode: String = "scratchRating",
        bpm: Int? = nil,
        loopDuration: Double? = nil
    ) {
        let roi = fixedRigLayout.map { layout -> CXLNotationCaptureSession.CXLRect? in
            let box = layout.unionBox
            return CXLNotationCaptureSession.CXLRect(
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height
            )
        } ?? nil

        cxlRecorder.startSession(
            scratchType: scratchType,
            mode: mode,
            bpm: bpm,
            loopDuration: loopDuration,
            cameraMode: selectedVideoSourceDescription,
            calibrationLocked: calibrationLocked,
            deckROI: roi,
            appBuildVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        publishCXLState()
    }

    func stopCXLCapture() {
        cxlRecorder.stopSession()
        publishCXLState()
    }

    func exportCXLSession() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let result = try self.cxlRecorder.exportSession()
                await MainActor.run {
                    self.cxlLastExportPath = result.directoryURL.path
                    self.cxlLastExportError = nil
                    self.publishCXLState()
                }
            } catch {
                await MainActor.run {
                    self.cxlLastExportError = error.localizedDescription
                    self.publishCXLState()
                }
            }
        }
    }

    /// Record a target stroke from the notation playback engine.
    /// Direction must come from the notation timeline — not from live hand detection.
    @discardableResult
    func recordCXLTargetStroke(direction: CXLDirection, strokeDuration: Double? = nil) -> Int {
        let idx = cxlRecorder.recordTargetStroke(direction: direction, strokeDuration: strokeDuration)
        publishCXLState()
        return idx
    }

    private func publishCXLState() {
        Task { @MainActor in
            self.cxlIsRecording = self.cxlRecorder.isRecording
            self.cxlSessionId = self.cxlRecorder.sessionId
            self.cxlEventCount = self.cxlRecorder.eventCount
            self.cxlSampleCount = self.cxlRecorder.sampleCount
            self.cxlLastExportPath = self.cxlRecorder.lastExportPath
        }
    }

    private func cxlDirectionFrom(_ state: HandMotionState) -> CXLDirection {
        switch state {
        case .movingRight: return .forward
        case .movingLeft:  return .back
        case .steady:      return .idle
        case .searching:   return .searching
        }
    }

    static func normalizedRecordDirection(
        forCameraSpaceDirection direction: HandDirectionTracker.Direction
    ) -> LiveRecordDirection? {
        switch direction {
        case .movingForward:
            return .backward
        case .movingBackward:
            return .forward
        case .idle, .searching:
            return nil
        }
    }

    private func cxlSignalSource() -> CXLSignalSource {
        switch coachSignalSource {
        case "Fused":     return .fused
        case "Audio":     return .audio
        case "Camera":    return .camera
        default:          return .searching
        }
    }

    private func requestPermissionsAndConfigure() {
        requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            self.requestAccess(for: .audio) { [weak self] audioGranted in
                guard let self else { return }

                Task { @MainActor in
                    if !videoGranted || !audioGranted {
                        self.statusMessage = "Grant camera and microphone access in System Settings"
                        self.isCameraActive = false
                    } else {
                        self.statusMessage = "Configuring capture session"
                    }
                }

                self.reconfigureSession()
            }
        }
    }

    private func requestAccess(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    func refreshSeratoDirectCapture() {
        refreshDevices()
    }

    func useDirectSeratoCapture() {
        guard let directCaptureDeviceUID, availableAudioDevices.contains(where: { $0.uniqueID == directCaptureDeviceUID }) else {
            refreshDevices()
            return
        }

        // The user pressed "use direct Serato capture": this is an explicit
        // choice and must be tracked as such (it previously bypassed origin
        // tracking, so a later automatic refresh treated it as non-explicit
        // and could override it).
        setSelectedAudioDeviceUniqueID(directCaptureDeviceUID, origin: .explicitUserChoice)
        directCaptureStatus = "\(seratoDirectCaptureDeviceName) is selected and feeding the analyzer."
    }

    func selectAudioInput(uniqueID: String) {
        setSelectedAudioDeviceUniqueID(uniqueID, origin: .explicitUserChoice)
    }

    func autoSelectCaptureAudioDeviceIfNeeded() {
        refreshAudioInputSelection(forceReselect: false)
    }

    func usePreferredSeratoAudio() {
        guard let device = preferredSeratoAudioDevice(from: availableAudioDevices.map(Self.audioChoice(from:))) else {
            refreshDevices()
            return
        }
        setSelectedAudioDeviceUniqueID(device.uniqueID, origin: .explicitUserChoice)
    }

    func toggleRoutineRecording() {
        isRoutineRecording ? stopRoutineRecording() : startRoutineRecording()
    }

    @MainActor
    func reportRoutineRecordingIssue(_ message: String) {
        routineRecordingStatus = message
    }

    func startRoutineRecording(captureTiming: CaptureTimingMetadata? = nil) {
        // A prior take's asynchronous finalization may still be pending; refuse
        // to start a new take (and re-open the admission gate) until it completes.
        guard !isRoutineFinalizationPending else { return }

        // Reset the shared camera processor (cadence phase, held anchor, and
        // accumulated angle/direction) so a prior take cannot leak into this one.
        cameraProcessor.reset()
        cameraPlatterCalibrationInsufficient = false

        let selectedVideoID = selectedVideoDeviceUniqueID
        let selectedAudioID = selectedAudioDeviceUniqueID
        let audioDevices = availableAudioDevices
        let videoDevices = availableVideoDevices

        Task { @MainActor in
            self.isRoutineRecording = true
            self.routineRecordingStatus = "Starting routine recording"
        }

        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            guard !selectedVideoID.isEmpty else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.missingVideo.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard !selectedAudioID.isEmpty else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.missingAudio.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard videoDevices.contains(where: { $0.uniqueID == selectedVideoID }) else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.selectedVideoUnavailable.errorDescription ?? "Unable to start recording."
                }
                return
            }
            guard audioDevices.contains(where: { $0.uniqueID == selectedAudioID }) else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = RoutineRecordingError.selectedAudioUnavailable.errorDescription ?? "Unable to start recording."
                }
                return
            }

            do {
                if !self.captureSessionHasInput(matching: selectedVideoID, mediaType: .video)
                    || !self.captureSessionHasInput(matching: selectedAudioID, mediaType: .audio) {
                    self.configureCaptureSession(
                        selectedAudioID: selectedAudioID,
                        selectedVideoID: selectedVideoID,
                        audioDevices: audioDevices,
                        videoDevices: videoDevices
                    )
                }

                guard self.captureSession.isRunning else {
                    throw RoutineRecordingError.sessionNotReady
                }
                guard self.captureSessionHasInput(matching: selectedVideoID, mediaType: .video) else {
                    throw RoutineRecordingError.missingVideoConnection
                }
                guard self.captureSessionHasInput(matching: selectedAudioID, mediaType: .audio) else {
                    throw RoutineRecordingError.missingAudioConnection
                }

                let preparedRecording = try self.prepareRoutineRecording(
                    selectedVideoID: selectedVideoID,
                    selectedAudioID: selectedAudioID,
                    videoDevices: videoDevices,
                    audioDevices: audioDevices,
                    captureTiming: captureTiming
                )
                try? CaptureJournalStore.appendTransactionBegan(
                    storageKind: .routine,
                    sessionID: preparedRecording.sidecar.sessionID,
                    takeID: preparedRecording.sidecar.takeID,
                    sidecarFileName: preparedRecording.sidecar.sidecarFileName,
                    mediaFileName: preparedRecording.sidecar.mediaFileName
                )
                try self.writeRoutineRecordingSidecar(preparedRecording.sidecar, to: preparedRecording.sidecarURL)
                self.activeRoutineRecordingSidecar = preparedRecording.sidecar
                self.activeRoutineRecordingSidecarURL = preparedRecording.sidecarURL
                // Per-take builder admission gate. Shared (non-DEBUG) so Debug
                // and Release admit builder observations identically; only the
                // diagnostic trace/instrumentation below is DEBUG-scoped.
                self.builderAdmissionGate.open()
                #if DEBUG
                let movementDebugSession = RoutineMovementDebugSession(handPoseInterval: self.routineRecordingHandPoseInterval)
                self.activeRoutineMovementDebugSession = movementDebugSession
                self.publishRoutineMovementDiagnostics(movementDebugSession.snapshot())
                // Arm the per-observation movement trace for this take. Started
                // here (before movieOutput) so the first observation lands with a
                // take-relative time near zero; the prior take's trace is dropped.
                self.movementTraceRecordingStartHostTime = CACurrentMediaTime()
                self.movementTraceRecorder.startRecording(at: self.movementTraceRecordingStartHostTime)
                self.activeRoutineDetectedNotationBuilder = RoutineDetectedNotationBuilder(
                    debugSession: movementDebugSession,
                    traceRecorder: self.movementTraceRecorder
                )
                #else
                self.activeRoutineDetectedNotationBuilder = RoutineDetectedNotationBuilder()
                #endif
                self.activeRoutineAudioNotationDetector = ScratchAudioNotationDetector()
                self.pendingRoutineOutputAudioURL = preparedRecording.audioURL
                self.audioQueue.sync {
                    self.activeRoutineAudioCaptureWriter = nil
                    self.publishRoutineAudioCaptureDiagnostics(nil)
                }
                Task { @MainActor in
                    self.lastRoutineDetectedNotation = nil
                    self.onboardOutputLevel = 0
                    self.onboardOutputCaptureStatus = "Recording is armed, but onboard AHHH is currently silent."
                    self.routineRecordingStatus = "Starting routine recording"
                }
                self.openMIDIInputForRecording()
                // Phase 3.1 — arm the raw-platter recorder just before
                // movieOutput starts, so the first hand-tracker sample
                // after this point lands in the buffer with a
                // take-relative time near zero. The clear+start pair
                // also discards any stale timeline from a previous
                // take.
                self.platterRecorderLock.lock()
                self.lastDrainedPlatterPositionTimeline = nil
                self.platterRecordingStartTime = CACurrentMediaTime()
                self.platterPositionRecorder.startRecording(at: 0)
                self.platterRecorderLock.unlock()
                #if DEBUG
                self.timecodeNotationLock.lock()
                self.lastDrainedTimecodeNotationTimeline = nil
                self.timecodeNotationAccumulator = nil
                self.timecodeNotationDiagnosticsStorage = TimecodeNotationDiagnostics()
                self.timecodeNotationLock.unlock()
                #endif
                #if DEBUG
                // Reset per-take Vision counters so Review diagnostics
                // compare against this take only, not the whole session.
                self.debugFramesAnalyzed = 0
                self.debugHandObservationsFound = 0
                self.debugDirectionChanges = 0
                self.debugMissedFrameCount = 0
                self.debugVisionReturnedHand = 0
                self.debugTrackedPointReturnedNil = 0
                self.debugTrackedPointReturnedPoint = 0
                self.debugJointsInspectedTotal = 0
                self.debugJointsRejectedLowConfidence = 0
                self.debugJointsRejectedOutsideROI = 0
                self.debugJointsAcceptedCandidates = 0
                self.debugObserveSkippedNotRecording = 0
                self.debugObserveAttempted = 0
                self.debugJointsRelaxedAccepted = 0
                self.debugContinuityFilledSamples = 0
                self.debugImpossibleJumpRejects = 0
                self.lastContinuityHandPoint = nil
                self.lastContinuityHandPointTime = 0
                // debugMidiEventsCapturedThisTake is reset under midiCaptureLock
                // in openMIDIInputForRecording(), alongside capturedMidiCCEvents.
                // debugLastROI intentionally left alone — it will be
                // updated on the next analyzed frame.
                #endif
                self.movieOutput.maxRecordedDuration = CMTime(
                    seconds: RoutineCaptureDefaults.defaultTakeLengthSeconds,
                    preferredTimescale: 600
                )
                self.movieOutput.startRecording(to: preparedRecording.mediaURL, recordingDelegate: self)
            } catch {
                self.scratchPlaybackController.cancelRoutineOutputCapture()
                self.reconnectSelectedMIDIInput()
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                Task { @MainActor in
                    self.isRoutineRecording = false
                    self.routineRecordingStatus = message
                }
            }
        }
    }

    func stopRoutineRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else {
                Task { @MainActor in
                    self.isRoutineRecording = false
                }
                return
            }
            Task { @MainActor in
                self.routineRecordingStatus = "Finishing routine recording"
                if let sidecar = self.activeRoutineRecordingSidecar {
                    self.upsertRoutineTakeArtifactStatus(
                        self.provisionalRoutineTakeArtifactStatus(for: sidecar, readiness: .finalizing)
                    )
                }
            }
            self.movieOutput.stopRecording()
        }
    }

    func refreshDevices() {
        var audioDevices = discoverAudioDevices()
        refreshSeratoDirectCaptureState(discoveredAudioDevices: audioDevices)
        if directCaptureRoute == .privateProcessTap {
            audioDevices = discoverAudioDevices()
        }

        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let discoveredVideoDevices = videoDiscovery.devices
        let companionDeskViewDevices = discoveredVideoDevices
            .filter { !isDeskViewCamera($0) }
            .compactMap(\.companionDeskViewCamera)
        let videoDevices = uniqueVideoDevices(discoveredVideoDevices + companionDeskViewDevices)
            .sorted { $0.localizedName < $1.localizedName }

        availableAudioDevices = audioDevices
        availableVideoDevices = videoDevices
        refreshMIDISources()

        refreshAudioInputSelection(using: audioDevices)
        syncScratchPlaybackOutputRoute(using: audioDevices)

        if !videoDevices.contains(where: { $0.uniqueID == selectedVideoDeviceUniqueID }) {
            selectedVideoDeviceUniqueID = videoDevices.first?.uniqueID ?? ""
        }

        syncDirectCaptureStatus(using: audioDevices)
    }

    func preferMacCameraForDesktopDeck(force: Bool = false) {
        guard let preferredDevice = preferredDesktopDeckCamera else { return }
        guard force || (!isUsingMacCameraForDesktopDeck && !isUsingDeskViewCamera) else { return }
        selectedVideoDeviceUniqueID = preferredDevice.uniqueID
    }

    func preferDeskViewCamera(force: Bool = false) {
        guard let preferredDevice = preferredDeskViewCamera else { return }
        guard force || selectedVideoDeviceUniqueID != preferredDevice.uniqueID else { return }
        selectedVideoDeviceUniqueID = preferredDevice.uniqueID
    }

    @objc private func handleWorkspaceApplicationChange(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              shouldTrackSeratoApplication(application) else {
            return
        }

        DispatchQueue.main.async {
            self.refreshDevices()
        }
    }

    private func shouldTrackSeratoApplication(_ application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier, seratoBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        guard let localizedName = application.localizedName?.lowercased() else { return false }
        return localizedName.contains("serato dj")
    }

    private func refreshSeratoDirectCaptureState(discoveredAudioDevices: [AVCaptureDevice]) {
        guard #available(macOS 14.2, *) else {
            directCaptureStatus = "Direct Capture needs macOS 14.2 or later."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            destroySeratoDirectCapture()
            return
        }

        let runningSeratoApps = runningSeratoApplications()
        let currentProcessIdentifiers = runningSeratoApps.map(\.processIdentifier).sorted()

        guard !currentProcessIdentifiers.isEmpty else {
            directCaptureStatus = "Open your DJ app to create the ScratchLab direct capture input."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            destroySeratoDirectCapture()
            return
        }

        if let seratoVirtualAudioDevice = discoveredAudioDevices.first(where: isSeratoVirtualAudioDevice(_:)) {
            directCaptureDeviceUID = seratoVirtualAudioDevice.uniqueID
            directCaptureRoute = .nativeSeratoVirtualAudio
            directCaptureStatus = isUsingDirectSeratoCapture
                ? "Audio input connected."
                : "Direct Capture is ready."
            destroySeratoDirectCapture()
            return
        }

        if seratoDirectCaptureTapID != 0,
           seratoDirectCaptureAggregateDeviceID != 0,
           currentProcessIdentifiers == seratoDirectCaptureProcessIdentifiers {
            directCaptureDeviceUID = seratoDirectCaptureDeviceUIDValue
            directCaptureRoute = .privateProcessTap
            return
        }

        destroySeratoDirectCapture()

        let processObjectIDs = currentProcessIdentifiers.compactMap(audioProcessObjectID(for:))
        guard !processObjectIDs.isEmpty else {
            directCaptureStatus = "Direct Capture is getting ready."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        let tapDescription = CATapDescription()
        tapDescription.name = seratoDirectCaptureDeviceName
        tapDescription.uuid = UUID()
        tapDescription.processes = processObjectIDs
        tapDescription.isExclusive = false
        tapDescription.isPrivate = true
        tapDescription.isMixdown = true
        tapDescription.isMono = false
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            print("Unable to create Serato process tap: \(tapStatus)")
            directCaptureStatus = "Direct Capture is unavailable right now. Restart the DJ app and try again."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        let tapDictionary: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: 1
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: seratoDirectCaptureDeviceName,
            kAudioAggregateDeviceUIDKey: seratoDirectCaptureDeviceUIDValue,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapDictionary],
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]

        var aggregateDeviceID = AudioObjectID(0)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            print("Unable to publish Serato direct-capture input: \(aggregateStatus)")
            directCaptureStatus = "Direct Capture is unavailable right now. Restart the DJ app and try again."
            directCaptureDeviceUID = nil
            directCaptureRoute = nil
            return
        }

        seratoDirectCaptureTapID = tapID
        seratoDirectCaptureAggregateDeviceID = aggregateDeviceID
        seratoDirectCaptureProcessIdentifiers = currentProcessIdentifiers
        directCaptureDeviceUID = seratoDirectCaptureDeviceUIDValue
        directCaptureRoute = .privateProcessTap
        directCaptureStatus = "Direct Capture is ready. Choose it from Source or use Direct Capture."
    }

    private func discoverAudioDevices() -> [AVCaptureDevice] {
        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return audioDiscovery.devices.sorted { $0.localizedName < $1.localizedName }
    }

    private func runningSeratoApplications() -> [NSRunningApplication] {
        let bundleMatches = seratoBundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        let nameMatches = NSWorkspace.shared.runningApplications.filter(shouldTrackSeratoApplication(_:))
        let uniqueMatches = Dictionary(grouping: bundleMatches + nameMatches, by: \.processIdentifier)
            .compactMap { $0.value.first }

        return uniqueMatches
            .filter { !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private func audioProcessObjectID(for processIdentifier: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = processIdentifier
        var processObjectID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &propertySize,
            &processObjectID
        )

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return processObjectID
    }

    private func isSeratoVirtualAudioDevice(_ device: AVCaptureDevice) -> Bool {
        device.localizedName.localizedCaseInsensitiveContains(seratoVirtualAudioDeviceName)
    }

    private func setSelectedAudioDeviceUniqueID(_ uniqueID: String, origin: AudioSelectionOrigin) {
        pendingAudioSelectionOrigin = origin
        selectedAudioDeviceUniqueID = uniqueID
        pendingAudioSelectionOrigin = .automatic
    }

    /// Standalone scratch audio must leave through the real Rane interface so
    /// the controller's hardware signal meters represent the sound ScratchLab
    /// is producing. Never bind playback to a Serato virtual endpoint. The
    /// system default remains the fail-safe when no physical Rane is present.
    private func syncScratchPlaybackOutputRoute(using audioDevices: [AVCaptureDevice]? = nil) {
        let devices = audioDevices ?? availableAudioDevices
        let selectedRane = devices.first(where: {
            $0.uniqueID == selectedAudioDeviceUniqueID
                && Self.isRaneHardwareDeviceName($0.localizedName)
        })
        let raneDevice = selectedRane
            ?? devices.first(where: { Self.isRaneHardwareDeviceName($0.localizedName) })

        guard let raneDevice,
              let deviceID = Self.audioDeviceID(forUID: raneDevice.uniqueID) else {
            scratchPlaybackController.setPreferredOutputDevice(
                deviceID: nil,
                deviceName: "System Default"
            )
            return
        }

        scratchPlaybackController.setPreferredOutputDevice(
            deviceID: deviceID,
            deviceName: raneDevice.localizedName
        )
    }

    private func refreshAudioInputSelection(
        using audioDevices: [AVCaptureDevice]? = nil,
        forceReselect: Bool = false
    ) {
        let resolvedAudioDevices = audioDevices ?? availableAudioDevices
        let availableChoices = resolvedAudioDevices.map(Self.audioChoice(from:))
        let currentSelection = selectedAudioDeviceUniqueID.trimmingCharacters(in: .whitespacesAndNewlines)

        if !forceReselect,
           hasExplicitUserAudioSelection,
           !currentSelection.isEmpty,
           availableChoices.contains(where: { $0.uniqueID == currentSelection }) {
            return
        }

        // Carry the user's explicit choice into the priority chain. When the
        // explicitly-selected device is still present, the chain returns it
        // (above Serato/default), so an automatic refresh (Serato launch,
        // tab/scene change, init) can no longer silently replace it. Only
        // when that device is genuinely gone does the fallback run. This is
        // the single source of the "input keeps switching" instability.
        let explicitSelectionID = (hasExplicitUserAudioSelection && !currentSelection.isEmpty)
            ? currentSelection
            : nil
        let decision: AudioSelectionDecision
#if DEBUG
        // Batch 12: in Debug builds, prefer the system default audio
        // input over Serato-like virtual devices.  This lets the
        // prototype timecode live tap capture from Loopback Audio
        // (or whatever the user has selected as macOS default input)
        // instead of silently grabbing Serato Virtual Audio.
        decision = Self.preferredCaptureAudioDevice(
            from: availableChoices,
            explicitSelectionUniqueID: explicitSelectionID,
            previousSelectionUniqueID: currentSelection.isEmpty ? nil : currentSelection,
            systemDefaultUniqueID: defaultSystemAudioInputUniqueID(),
            skipSeratoPriority: true,
            preferRaneHardware: true
        )
#else
        decision = Self.preferredCaptureAudioDevice(
            from: availableChoices,
            explicitSelectionUniqueID: explicitSelectionID,
            previousSelectionUniqueID: currentSelection.isEmpty ? nil : currentSelection,
            systemDefaultUniqueID: defaultSystemAudioInputUniqueID()
        )
#endif

        guard forceReselect || currentSelection != decision.device?.uniqueID else {
            if decision.device == nil, !currentSelection.isEmpty {
                setSelectedAudioDeviceUniqueID("", origin: .automatic)
            }
            return
        }

        let needsAutomaticSelection: Bool
        if let selectedDeviceID = decision.device?.uniqueID {
            needsAutomaticSelection = selectedDeviceID != currentSelection || !hasExplicitUserAudioSelection
        } else {
            needsAutomaticSelection = !currentSelection.isEmpty
        }

        guard needsAutomaticSelection else { return }
        setSelectedAudioDeviceUniqueID(decision.device?.uniqueID ?? "", origin: .automatic)
    }

    private func defaultSystemAudioInputUniqueID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uid: Unmanaged<CFString>? = nil
        let uidStatus: OSStatus = withUnsafeMutableBytes(of: &uid) { rawBuf in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, rawBuf.baseAddress!)
        }
        guard uidStatus == noErr else {
            return nil
        }

        return uid?.takeRetainedValue() as String?
    }

#if ENABLE_TIMECODE_LIVE_TAP
    /// Starts (or rebinds) the DEBUG DVS input path to the explicitly
    /// selected capture device, using an `AVAudioSinkNode` connected as the
    /// terminal input-render consumer (Slice 2) instead of
    /// `AVAudioNode.installTap` (Slice 2's predecessor). The sink node's
    /// realtime receiver block performs only validation/copy into a fresh
    /// `TimecodeRealtimeIngressRing` (Slice 1); a dedicated
    /// `TimecodeRealtimeIngressWorker` drains that ring off the realtime
    /// thread and performs the adapter conversion, heartbeat updates, and
    /// diagnostics that previously ran inline in the tap callback (see
    /// `handleLowLatencySinkDelivery(_:)`).
    private func refreshLowLatencyTimecodeInput() {
        guard timecodeAudioCallback != nil,
              !selectedAudioDeviceUniqueID.isEmpty else {
            stopLowLatencyTimecodeInput()
            return
        }
        let selectedUID = selectedAudioDeviceUniqueID
        let alreadyRunning = timecodeInputStateLock.withLock {
            timecodeInputTapHeartbeat.isInstalled &&
                timecodeInputTapHeartbeat.deviceUID == selectedUID
        }
        guard !alreadyRunning else { return }

        stopLowLatencyTimecodeInput()
        guard let deviceID = Self.audioDeviceID(forUID: selectedUID) else {
            NSLog("[DVS] Low-latency input could not resolve selected device UID; retaining AVCapture fallback.")
            return
        }
        // Read-only — queried before any AUHAL mutation so it reflects the
        // device's own configuration, not anything this bind is about to
        // change. The sink node below has no fixed buffer-size request (it
        // is driven by whatever render quantum the engine schedules); this
        // diagnostic is what answers the device's own real buffer-size
        // configuration and range regardless of that.
        // Not stored yet: `stopLowLatencyTimecodeInput()` above already
        // cleared any previous diagnostic, and this one is only published
        // once the bind below is confirmed to succeed — a failed bind must
        // not leave a diagnostic attributed to a device that never bound.
        let bufferDiagnostic = Self.readAudioDeviceBufferDiagnostic(deviceID: deviceID)
        NSLog("[DVS] HAL buffer diagnostic: %@", formatAudioDeviceBufferDiagnostic(bufferDiagnostic))

        let inputNode = timecodeInputEngine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            NSLog("[DVS] Low-latency input node has no AudioUnit; retaining AVCapture fallback.")
            return
        }
        // AUHAL requires input I/O to be enabled before assigning its
        // current device. Assigning first can return noErr while the unit
        // continues rendering the system-default mono input.
        var enableInput: UInt32 = 1
        let enableStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard enableStatus == noErr else {
            NSLog("[DVS] Low-latency input enable failed (%d); retaining AVCapture fallback.", enableStatus)
            return
        }
        var mutableDeviceID = deviceID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            NSLog("[DVS] Low-latency input device binding failed (%d); retaining AVCapture fallback.", deviceStatus)
            return
        }
        var boundDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var boundDeviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readbackStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &boundDeviceID,
            &boundDeviceSize
        )
        guard readbackStatus == noErr, boundDeviceID == deviceID else {
            NSLog(
                "[DVS] Low-latency input device read-back mismatch (status %d, requested %u, actual %u); retaining AVCapture fallback.",
                readbackStatus,
                deviceID,
                boundDeviceID
            )
            return
        }

        // Apple's input-node contract identifies `inputFormat` as the
        // hardware format to inspect when deciding whether input is enabled.
        // Immediately after rebinding an AUHAL device, `outputFormat` can
        // still be the pre-start 0 Hz / 0-channel placeholder even though the
        // newly-bound hardware input is valid. Treating that placeholder as
        // fatal caused the Rane tap to fall back to 7,168-frame AVCapture
        // buffers every time. In that state use the explicit hardware format.
        // A nil/inherited format was observed to render a default mono stream
        // on this 14-channel Rane even after successful device binding.
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let formatChoice = lowLatencyTimecodeTapFormatChoice(
            hardwareChannelCount: Int(hardwareFormat.channelCount),
            hardwareSampleRate: hardwareFormat.sampleRate,
            outputChannelCount: Int(outputFormat.channelCount),
            outputSampleRate: outputFormat.sampleRate
        )
        guard formatChoice != .unavailable else {
            NSLog(
                "[DVS] Low-latency hardware input is unusable (hardware %.0fHz/%uch, output %.0fHz/%uch); retaining AVCapture fallback.",
                hardwareFormat.sampleRate,
                hardwareFormat.channelCount,
                outputFormat.sampleRate,
                outputFormat.channelCount
            )
            return
        }
        let tapFormat: AVAudioFormat = formatChoice == .explicitOutput
            ? outputFormat
            : hardwareFormat

        let formatValidation = validateLowLatencySinkFormat(
            commonFormat: tapFormat.commonFormat,
            isInterleaved: tapFormat.isInterleaved,
            sampleRate: tapFormat.sampleRate,
            channelCount: Int(tapFormat.channelCount),
            ringConfiguration: .production
        )
        guard formatValidation == .valid else {
            NSLog(
                "[DVS] Low-latency sink format rejected (%@); retaining AVCapture fallback.",
                String(describing: formatValidation)
            )
            return
        }

        // The realtime receiver block below must capture only this
        // session's own `ring` and the two fixed values below — never
        // `self`, never any mutable engine-wide property. A stale render
        // call from a superseded session can therefore only ever publish
        // into (or be rejected by) *that* session's own closed ring; it can
        // never reach a replacement session's ring, regardless of teardown
        // timing. `LowLatencySinkLifecycle.start` constructs the session
        // (with its own fresh ring) and passes it to `attachAndConnect`
        // below — the production sequencing that guarantees this is the
        // same sequencing exercised, with recording/no-op closures, in
        // `LowLatencySinkLifecycleTests`.
        let expectedChannelCount = Int(tapFormat.channelCount)
        let sinkSampleRate = tapFormat.sampleRate
        var startError: Error?
        var actions = teardownActions()
        // These 3 closures are used and discarded synchronously, entirely
        // within this call to `lowLatencySinkLifecycle.start(actions:...)`
        // below — they never escape or persist beyond it, so capturing
        // `self` strongly here creates no retain cycle. This matters beyond
        // style: `stopLowLatencyTimecodeInput()` (which builds the
        // equivalent teardown closures via `teardownActions()`) is also
        // called from `deinit`, and forming a *new* `[weak self]` capture
        // while `self` is being deallocated is what the ObjC runtime flags
        // as "Cannot form weak reference ... in the process of
        // deallocation" — using `self` directly here is both safe and
        // avoids that entirely, exactly like calling `self.method()`
        // directly from `deinit` already does elsewhere in this class.
        actions.attachAndConnect = { ring in
            let sinkNode = AVAudioSinkNode { timestamp, frameCount, audioBufferList -> OSStatus in
                let flags = timestamp.pointee.mFlags
                let hostTime: UInt64 = flags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : 0
                let sampleTime: Int64 = flags.contains(.sampleTimeValid)
                    ? (safeSampleTime(timestamp.pointee.mSampleTime) ?? 0)
                    : 0
                // Realtime-safe: no allocation, no locks, no dispatch, no
                // logging, no `AVAudioPCMBuffer` construction, no adapter/
                // heartbeat/fixture/playback/notation/UI work. `publish`'s
                // result is intentionally not inspected here — the ring
                // already tracks published/dropped/rejected atomically;
                // surfacing that is the worker/diagnostic path's job, not
                // the realtime callback's.
                ring.publish(
                    bufferList: audioBufferList,
                    frameCount: Int(frameCount),
                    expectedChannelCount: expectedChannelCount,
                    sampleRate: sinkSampleRate,
                    hostTime: hostTime,
                    sampleTime: sampleTime
                )
                return noErr
            }
            self.currentLowLatencySinkNode = sinkNode
            self.timecodeInputEngine.attach(sinkNode)
            self.timecodeInputEngine.connect(inputNode, to: sinkNode, format: tapFormat)
        }
        actions.startEngine = {
            self.timecodeInputEngine.prepare()
            do {
                try self.timecodeInputEngine.start()
            } catch {
                startError = error
                throw error
            }
        }
        actions.markHeartbeatInstalled = {
            self.timecodeInputStateLock.withLock {
                self.timecodeInputTapHeartbeat.markInstalled(deviceUID: selectedUID)
                self.timecodeInputBufferDiagnostic = bufferDiagnostic
            }
        }

        let outcome = lowLatencySinkLifecycle.start(
            actions: actions,
            // Captures the exact, already-validated `tapFormat` — never a
            // freshly reconstructed one — so `handleLowLatencySinkDelivery`
            // can hand it straight to `AVAudioPCMBuffer(pcmFormat:...)`.
            // This closure runs on the worker's own queue, not the realtime
            // callback, so capturing an extra immutable value here is fine.
            consumer: { [weak self] slot in
                self?.handleLowLatencySinkDelivery(slot, format: tapFormat)
            }
        )

        timecodeInputStateLock.withLock {
            currentLowLatencySinkSession = lowLatencySinkLifecycle.currentSession
        }
        if lowLatencySinkLifecycle.currentSession == nil {
            currentLowLatencySinkNode = nil
        }

        switch outcome {
        case .started:
            publishLowLatencyTimecodeTapDiagnostic()
        case .sessionConstructionFailed:
            NSLog("[DVS] Low-latency sink session failed to construct; retaining AVCapture fallback.")
        case .engineStartFailed:
            NSLog(
                "[DVS] Low-latency input failed to start (%@); retaining AVCapture fallback.",
                startError?.localizedDescription ?? "unknown error"
            )
            publishLowLatencyTimecodeTapDiagnostic()
        }
    }

    /// Builds the 4 teardown-only closures shared by
    /// `stopLowLatencyTimecodeInput()` and (via
    /// `refreshLowLatencyTimecodeInput()`'s override of the other 3 fields)
    /// `LowLatencySinkLifecycle.start`'s internal failure-path cleanup. The
    /// 3 start-only fields are placeholder no-ops here — safe because
    /// `LowLatencySinkLifecycle.stop` never invokes them, and
    /// `refreshLowLatencyTimecodeInput()` always overrides them before
    /// calling `start`.
    ///
    /// Deliberately captures `self` directly (no `[weak self]`): every
    /// closure here is invoked synchronously, within the same call to
    /// `LowLatencySinkLifecycle.start`/`.stop` that constructed it, and
    /// never escapes beyond that — so there is no retain cycle to guard
    /// against. This matters beyond style: `stopLowLatencyTimecodeInput()`
    /// (which calls this method) is also called from `deinit`, and forming
    /// a *new* `[weak self]` capture while `self` is already being
    /// deallocated is exactly what the ObjC runtime flags as "Cannot form
    /// weak reference ... in the process of deallocation" — using `self`
    /// directly is both safe and avoids that, identically to how plain
    /// property/method access on `self` already works elsewhere in this
    /// class's own `deinit`.
    private func teardownActions() -> LowLatencySinkLifecycleActions {
        LowLatencySinkLifecycleActions(
            attachAndConnect: { _ in },
            startEngine: {},
            stopEngine: { self.timecodeInputEngine.stop() },
            disconnectAndDetach: {
                guard let sinkNode = self.currentLowLatencySinkNode else { return }
                self.timecodeInputEngine.disconnectNodeInput(sinkNode)
                self.timecodeInputEngine.detach(sinkNode)
            },
            resetEngine: { self.timecodeInputEngine.reset() },
            markHeartbeatInstalled: {},
            resetHeartbeat: {
                self.timecodeInputStateLock.withLock {
                    self.timecodeInputTapHeartbeat.reset()
                    self.timecodeInputBufferDiagnostic = nil
                    self.timecodeInputWorkerObservationDiagnostic = nil
                }
            }
        )
    }

    /// Runs on `TimecodeRealtimeIngressWorker`'s own private serial queue —
    /// never the realtime audio thread. Safe to allocate, lock, log, and
    /// call the adapter here; this is exactly the work the old
    /// `installTap` callback used to perform inline on the tap's thread.
    /// `format` is the exact, already-validated sink connection format
    /// (`tapFormat`, captured once by the caller) — never reconstructed
    /// here. Synthesizes an `AVAudioPCMBuffer` from the drained slot via
    /// `makeLowLatencySinkPCMBuffer(fromSlot:format:)` so the existing,
    /// unmodified `TimecodeCMSampleBufferAdapter.stereoSampleResult
    /// (fromPCMBuffer:hostTime:)` entry point — and therefore the existing
    /// channel-selection/retention/diagnostics behavior — is reused exactly
    /// as-is; no Rane-specific channel pinning or preset behavior is added.
    private func handleLowLatencySinkDelivery(_ slot: TimecodeRealtimeIngressSlotView, format: AVAudioFormat) {
        let actualChannelCount = slot.channelCount

        // Hardware evidence must stay visible even if adapter conversion
        // fails below — recorded on every delivery, never gated on success,
        // and never fed into the heartbeat (which alone controls AVCapture
        // fallback suppression).
        timecodeInputStateLock.withLock {
            timecodeInputWorkerObservationDiagnostic = LowLatencySinkWorkerObservationDiagnostic(
                frameCount: slot.frameCount,
                channelCount: actualChannelCount,
                sampleRate: slot.sampleRate
            )
        }

        let selection = TimecodeCMSampleBufferAdapter.channelPairSelection
        guard lowLatencyTimecodeTapHasRequiredChannels(
            actualChannelCount: actualChannelCount,
            selection: selection
        ) else {
            let rejection = "\(actualChannelCount)ch insufficient for \(selection.label)"
            let shouldStop = timecodeInputStateLock.withLock { () -> Bool in
                guard timecodeInputTapHeartbeat.isInstalled else { return false }
                timecodeInputTapHeartbeat.recordRejection(rejection)
                return true
            }
            publishLowLatencyTimecodeTapDiagnostic()
            if shouldStop {
                NSLog(
                    "[DVS] Low-latency sink delivered only %d channel(s), insufficient for %@; restoring AVCapture fallback.",
                    actualChannelCount,
                    selection.label
                )
                sessionQueue.async { [weak self] in
                    self?.stopLowLatencyTimecodeInput(preservingRejection: rejection)
                }
            }
            return
        }

        let pcmBuffer: AVAudioPCMBuffer
        switch makeLowLatencySinkPCMBuffer(fromSlot: slot, format: format) {
        case .succeeded(let buffer):
            pcmBuffer = buffer
        case .failed(let stage):
            // Includes actual slot metadata (not just a generic message) so
            // a real-hardware rejection is diagnosable without a debugger:
            // channel count, frame count, sample rate, and exactly which
            // conversion stage failed.
            let rejection = "adapter conversion failed (\(stage.rawValue)):" +
                " \(actualChannelCount)ch \(slot.frameCount)f@\(Int(slot.sampleRate))Hz"
            timecodeInputStateLock.withLock {
                timecodeInputTapHeartbeat.recordRejection(rejection)
            }
            publishLowLatencyTimecodeTapDiagnostic()
            return
        }

        guard let result = TimecodeCMSampleBufferAdapter.stereoSampleResult(
                fromPCMBuffer: pcmBuffer,
                hostTime: slot.hostTime == 0 ? nil : slot.hostTime
              ),
              let callback = timecodeAudioCallback else { return }
        let callbackUptime = CACurrentMediaTime()
        let formatDescription = "Float32 non-interleaved"
        let shouldPublishDiagnostic = timecodeInputStateLock.withLock { () -> Bool in
            let firstCallback = timecodeInputTapHeartbeat.callbackCount == 0
            let observedFormatChanged =
                timecodeInputTapHeartbeat.observedChannelCount != actualChannelCount ||
                timecodeInputTapHeartbeat.observedFrameCount != slot.frameCount ||
                timecodeInputTapHeartbeat.observedSampleRate != slot.sampleRate ||
                timecodeInputTapHeartbeat.observedFormat != formatDescription
            timecodeInputTapHeartbeat.recordCallback(
                uptime: callbackUptime,
                channelCount: actualChannelCount,
                frameCount: slot.frameCount,
                sampleRate: slot.sampleRate,
                format: formatDescription
            )
            return firstCallback || observedFormatChanged
        }
        if shouldPublishDiagnostic {
            publishLowLatencyTimecodeTapDiagnostic(now: callbackUptime)
        }
        callback(result.left, result.right, result.sampleRate, result.hostTime)
    }

    /// Truthful, deterministic, idempotent teardown of the current
    /// low-latency DVS sink-node session — a thin wrapper delegating the
    /// actual sequencing to `LowLatencySinkLifecycle.stop`, in the required
    /// order: (1) close producer acceptance first — a `publish` call that
    /// had already passed the ring's accept-writes check *before* this step
    /// may still complete and write one final slot; this step only
    /// guarantees that a call which *observes* the flag as already closed
    /// afterward is rejected, not that every racing producer call is (see
    /// `TimecodeRealtimeIngressRing.closeForWriting()`'s own documented
    /// guarantee) — that in-flight slot is still safe because the ring
    /// object itself is kept alive by the sink node's own closure capture,
    /// independent of this function's local bindings; (2) stop the engine's
    /// producer path; (3) disconnect and detach the sink node; (4)
    /// synchronously stop the worker/consumer — guarantees no further
    /// consumer delivery once this call returns; (5) clear published
    /// session state. `currentLowLatencySinkNode` is only cleared after
    /// `lowLatencySinkLifecycle.stop` returns, so producer retirement is
    /// provably complete first. Safe to call when nothing is running, and
    /// safe to call more than once.
    private func stopLowLatencyTimecodeInput(
        preservingRejection rejection: String? = nil
    ) {
        lowLatencySinkLifecycle.stop(actions: teardownActions())
        currentLowLatencySinkNode = nil

        timecodeInputStateLock.withLock {
            currentLowLatencySinkSession = nil
            if let rejection {
                timecodeInputTapHeartbeat.recordRejection(rejection)
            }
        }
        publishLowLatencyTimecodeTapDiagnostic()
    }

    private func publishLowLatencyTimecodeTapDiagnostic(
        now: TimeInterval = CACurrentMediaTime()
    ) {
        let heartbeatText = timecodeInputStateLock.withLock {
            timecodeInputTapHeartbeat.diagnostic(at: now)
        }
        let marker = " | DVS tap heartbeat: "
        let existing = TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo
        let base = existing.components(separatedBy: marker).first ?? existing
        TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo =
            base + marker + heartbeatText
        publishAudioDeviceBufferDiagnosticIfAvailable()
        publishLowLatencySinkRingDiagnosticIfAvailable()
        publishLowLatencySinkWorkerObservationDiagnosticIfAvailable()
    }

    /// Appends the low-latency sink ring's live published/dropped/rejected
    /// counters (see `LowLatencySinkRingDiagnostic`), using the pure
    /// `applyingLowLatencySinkRingDiagnostic(to:diagnostic:)` helper so a
    /// `nil` diagnostic (no active session) strips any stale marker text
    /// rather than leaving a previous session's counters in place.
    private func publishLowLatencySinkRingDiagnosticIfAvailable() {
        let session = timecodeInputStateLock.withLock { currentLowLatencySinkSession }
        let diagnostic = session.map {
            LowLatencySinkRingDiagnostic(
                publishedCount: $0.ring.publishedCount,
                droppedCount: $0.ring.droppedCount,
                rejectedCount: $0.ring.rejectedCount
            )
        }
        TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo = applyingLowLatencySinkRingDiagnostic(
            to: TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo,
            diagnostic: diagnostic
        )
    }

    /// Appends the worker's raw observed frame/channel/sample-rate evidence
    /// for the most recent slot (see `LowLatencySinkWorkerObservationDiagnostic`)
    /// — visible even while adapter conversion is failing, distinct from and
    /// never a substitute for the heartbeat's own `observed=`/freshness
    /// state, which only updates once conversion actually succeeds.
    private func publishLowLatencySinkWorkerObservationDiagnosticIfAvailable() {
        let diagnostic = timecodeInputStateLock.withLock { timecodeInputWorkerObservationDiagnostic }
        TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo = applyingLowLatencySinkWorkerObservationDiagnostic(
            to: TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo,
            diagnostic: diagnostic
        )
    }

    /// Appends the once-per-bind HAL buffer diagnostic (see
    /// `readAudioDeviceBufferDiagnostic(deviceID:)`) using the pure
    /// `applyingAudioDeviceBufferDiagnostic(to:diagnostic:)` helper, so a
    /// `nil` diagnostic (device switch, failed bind, or stop) actively
    /// strips any stale marker text rather than leaving it in place.
    private func publishAudioDeviceBufferDiagnosticIfAvailable() {
        let diagnostic = timecodeInputStateLock.withLock { timecodeInputBufferDiagnostic }
        TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo = applyingAudioDeviceBufferDiagnostic(
            to: TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo,
            diagnostic: diagnostic
        )
    }

    private static func audioDeviceID(forUID requestedUID: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else { return nil }

        return devices.first { deviceID in
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uid: Unmanaged<CFString>?
            let status = withUnsafeMutableBytes(of: &uid) { ptr in
                AudioObjectGetPropertyData(
                    deviceID,
                    &uidAddress,
                    0,
                    nil,
                    &uidSize,
                    ptr.baseAddress!
                )
            }
            return status == noErr && (uid?.takeRetainedValue() as String?) == requestedUID
        }
    }

    /// Read-only query of the properties that actually govern the frame
    /// count an `AVAudioEngine` tap receives from this device.
    /// `installTap(bufferSize:)` is a request, not a guarantee — this is
    /// the diagnostic that answers what the device's real, currently
    /// configured buffer size is, what range it supports, and whether the
    /// requested size is even achievable on this hardware. Every property
    /// read is independent and tolerant of the device not supporting it —
    /// never fatal, never partial-fails the whole struct. No property is
    /// ever written; this call has no side effects and needs no teardown.
    /// Scopes verified against the installed CoreAudio SDK headers
    /// (`AudioHardware.h`/`AudioHardwareBase.h`), not assumed:
    /// `kAudioDevicePropertyBufferFrameSize`, its `...Range`, and
    /// `kAudioDevicePropertyNominalSampleRate` are documented as properties
    /// of the device as a whole (no input/output distinction in their
    /// description) and are queried at `kAudioObjectPropertyScopeGlobal`.
    /// `kAudioDevicePropertySafetyOffset` ("...ahead (for output) or behind
    /// (for input...") and `kAudioDevicePropertyLatency` ("input and output
    /// latency may differ") are explicitly documented as differing by
    /// direction, so they are queried at `kAudioDevicePropertyScopeInput` —
    /// this tap only ever cares about the input side.
    private static func readAudioDeviceBufferDiagnostic(
        deviceID: AudioDeviceID
    ) -> AudioDeviceBufferFrameSizeDiagnostic {
        /// Every read checks property availability and the actual reported
        /// data size before touching the value — a property that exists
        /// but reports an unexpected size is treated as unavailable rather
        /// than trusting a partially/differently filled buffer.
        func hasProperty(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope
        ) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            return AudioObjectHasProperty(deviceID, &address)
        }

        func readUInt32(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope
        ) -> UInt32? {
            guard hasProperty(selector, scope: scope) else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            var actualSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &actualSize) == noErr,
                  actualSize == UInt32(MemoryLayout<UInt32>.size) else { return nil }
            var value: UInt32 = 0
            var size = actualSize
            guard AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &value
            ) == noErr else { return nil }
            return value
        }

        func readDouble(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope
        ) -> Double? {
            guard hasProperty(selector, scope: scope) else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            var actualSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &actualSize) == noErr,
                  actualSize == UInt32(MemoryLayout<Float64>.size) else { return nil }
            var value: Float64 = 0
            var size = actualSize
            guard AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &value
            ) == noErr else { return nil }
            return Double(value)
        }

        func readFrameRange(
            _ selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope
        ) -> (minimum: UInt32, maximum: UInt32)? {
            guard hasProperty(selector, scope: scope) else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            var actualSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &actualSize) == noErr,
                  actualSize == UInt32(MemoryLayout<AudioValueRange>.size) else { return nil }
            var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
            var size = actualSize
            guard AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &range
            ) == noErr else { return nil }
            // Defensive: a device could in principle report a NaN,
            // infinite, negative, or out-of-UInt32 bound. Never assume the
            // call succeeding means the value is safe to convert.
            guard let minimum = safeFrameCount(range.mMinimum),
                  let maximum = safeFrameCount(range.mMaximum) else { return nil }
            return (minimum, maximum)
        }

        let frameRange = readFrameRange(
            kAudioDevicePropertyBufferFrameSizeRange,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return AudioDeviceBufferFrameSizeDiagnostic(
            currentBufferFrameSize: readUInt32(
                kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal
            ),
            minimumBufferFrameSize: frameRange?.minimum,
            maximumBufferFrameSize: frameRange?.maximum,
            nominalSampleRate: readDouble(
                kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal
            ),
            safetyOffsetFrames: readUInt32(
                kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeInput
            ),
            deviceLatencyFrames: readUInt32(
                kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeInput
            )
        )
    }
#endif

    private static func audioChoice(from device: AVCaptureDevice) -> AudioInputDeviceChoice {
        AudioInputDeviceChoice(uniqueID: device.uniqueID, name: device.localizedName)
    }

    private static func isExactSeratoVirtualAudioDeviceName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Serato Virtual Audio") == .orderedSame
    }

    private static func isSeratoLikeDeviceName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Serato")
    }

    private static func isRaneHardwareDeviceName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Rane")
    }

    /// Map raw device names to generic, App-Store-safe labels for user-visible UI.
    /// Keeps device-routing identifiers untouched — only the display string changes.
    private func displayAudioDeviceName(_ name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Audio input" }

        let lowercasedName = trimmedName.lowercased()
        if lowercasedName.contains("serato")
            || lowercasedName.contains("virtual")
            || lowercasedName.contains("blackhole")
            || lowercasedName.contains("loopback")
            || lowercasedName.contains("rogue amoeba") {
            return "Virtual audio device"
        }
        if lowercasedName.contains("mic")
            || lowercasedName.contains("microphone")
            || lowercasedName.contains("built-in")
            || lowercasedName.contains("internal") {
            return "Built-in microphone"
        }
        if lowercasedName.contains("djm")
            || lowercasedName.contains("scarlett")
            || lowercasedName.contains("interface")
            || lowercasedName.contains("usb")
            || lowercasedName.contains("record") {
            return "Audio interface"
        }
        return "Audio input"
    }

    private func displayVideoDeviceName(_ name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Camera" }

        let lowercasedName = trimmedName.lowercased()
        if lowercasedName.contains("built-in")
            || lowercasedName.contains("facetime")
            || lowercasedName.contains("desk view") {
            return "Built-in camera"
        }
        return "External camera"
    }

    private func preferredSeratoAudioDevice(from devices: [AudioInputDeviceChoice]) -> AudioInputDeviceChoice? {
        if let exactSerato = devices.first(where: { Self.isExactSeratoVirtualAudioDeviceName($0.name) }) {
            return exactSerato
        }
        return devices.first(where: { Self.isSeratoLikeDeviceName($0.name) })
    }

    static func preferredCaptureAudioDevice(
        from devices: [AudioInputDeviceChoice],
        explicitSelectionUniqueID: String?,
        previousSelectionUniqueID: String?,
        systemDefaultUniqueID: String?,
        skipSeratoPriority: Bool = false,
        preferRaneHardware: Bool = false
    ) -> AudioSelectionDecision {
        guard !devices.isEmpty else {
            return AudioSelectionDecision(device: nil, priority: .noneAvailable)
        }

        let normalizedExplicitID = explicitSelectionUniqueID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedExplicitID,
           !normalizedExplicitID.isEmpty,
           let explicitDevice = devices.first(where: { $0.uniqueID == normalizedExplicitID }) {
            return AudioSelectionDecision(device: explicitDevice, priority: .explicitUserSelection)
        }

        if preferRaneHardware,
           let raneDevice = devices.first(where: { isRaneHardwareDeviceName($0.name) }) {
            return AudioSelectionDecision(device: raneDevice, priority: .raneHardware)
        }

        // Batch 12: when skipSeratoPriority is true (DEBUG timecode
        // prototype path), system default beats Serato-like virtual
        // audio.  Serato Virtual Audio is silent when Serato isn't
        // running, and the user's OS-level default input (e.g. Loopback
        // Audio) carries the real timecode signal.
        if !skipSeratoPriority {
            let exactSerato = devices.first(where: { isExactSeratoVirtualAudioDeviceName($0.name) })
            if let exactSerato {
                return AudioSelectionDecision(device: exactSerato, priority: .exactSeratoVirtualAudio)
            }

            let seratoLike = devices.first(where: { isSeratoLikeDeviceName($0.name) })
            if let seratoLike {
                return AudioSelectionDecision(device: seratoLike, priority: .seratoLike)
            }
        }

        // When skipSeratoPriority is true, the previous-session choice is
        // only reused if it is NOT a Serato-like virtual device.
        // Otherwise the stale VirtualAudio_UID from a prior session
        // silently captures silence ahead of the system default.
        let normalizedPreviousID = previousSelectionUniqueID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousDevice: AudioInputDeviceChoice? = {
            guard let id = normalizedPreviousID, !id.isEmpty,
                  let device = devices.first(where: { $0.uniqueID == id }) else { return nil }
            if skipSeratoPriority, isSeratoLikeDeviceName(device.name) { return nil }
            return device
        }()
        if let previousDevice {
            return AudioSelectionDecision(device: previousDevice, priority: .previousSelection)
        }

        let normalizedDefaultID = systemDefaultUniqueID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDefaultID,
           !normalizedDefaultID.isEmpty,
           let defaultDevice = devices.first(where: { $0.uniqueID == normalizedDefaultID }) {
            return AudioSelectionDecision(device: defaultDevice, priority: .systemDefault)
        }

        // When skipSeratoPriority is true, prefer the first non-Serato
        // device as last resort so the timecode prototype path doesn't
        // silently lock onto a silent virtual device.
        let fallback = skipSeratoPriority
            ? (devices.first(where: { !isSeratoLikeDeviceName($0.name) }) ?? devices.first)
            : devices.first
        return AudioSelectionDecision(device: fallback, priority: .firstAvailable)
    }

    private func syncDirectCaptureStatus(using audioDevices: [AVCaptureDevice]) {
        guard let directCaptureDeviceUID else { return }

        if audioDevices.contains(where: { $0.uniqueID == directCaptureDeviceUID }) {
            directCaptureStatus = isUsingDirectSeratoCapture
                ? "Audio input connected."
                : "Direct Capture is ready."
        } else if seratoDirectCaptureAggregateDeviceID != 0 {
            directCaptureStatus = "Direct Capture is getting ready."
        }
    }

    private func destroySeratoDirectCapture() {
        if seratoDirectCaptureAggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(seratoDirectCaptureAggregateDeviceID)
            seratoDirectCaptureAggregateDeviceID = 0
        }

        if #available(macOS 14.2, *), seratoDirectCaptureTapID != 0 {
            AudioHardwareDestroyProcessTap(seratoDirectCaptureTapID)
            seratoDirectCaptureTapID = 0
        }

        seratoDirectCaptureProcessIdentifiers.removeAll()
    }

    private func reconfigureSession() {
        // A capture device change invalidates any DVS pair Auto selection
        // is currently holding — the new device's channel layout may not
        // even resemble the old one.
        #if DEBUG && ENABLE_TIMECODE_LIVE_TAP
        TimecodeCMSampleBufferAdapter.resetPairRetention()
        #endif
        let selectedAudioID = selectedAudioDeviceUniqueID
        let selectedVideoID = selectedVideoDeviceUniqueID
        let audioDevices = availableAudioDevices
        let videoDevices = availableVideoDevices

        Task { @MainActor in
            self.isRoutineCaptureReady = false
        }

        sessionQueue.async {
            self.configureCaptureSession(
                selectedAudioID: selectedAudioID,
                selectedVideoID: selectedVideoID,
                audioDevices: audioDevices,
                videoDevices: videoDevices
            )

            Task { @MainActor in
                self.lastScratchDetection = nil
                self.scratchDetectionCount = 0
                self.rigLayout = nil
                self.isUsingManualRigGuide = false
                self.highlightedZoneRole = .leftDeck
                self.sessionStars = 0
                self.smoothedHandPoint = nil
                self.missedHandTrackingFrames = 0
                let audioName = audioDevices.first(where: { $0.uniqueID == selectedAudioID })?.localizedName ?? "No audio input"
                let videoName = videoDevices.first(where: { $0.uniqueID == selectedVideoID })?.localizedName ?? "No camera"
                self.statusMessage = "Connected to \(audioName) and \(videoName)."
            }
        }
    }

    private func configureCaptureSession(
        selectedAudioID: String,
        selectedVideoID: String,
        audioDevices: [AVCaptureDevice],
        videoDevices: [AVCaptureDevice]
    ) {
        // Never tear the session down mid-take. `configureCaptureSession`
        // removes every input/output and rebuilds; doing that while
        // `movieOutput` is recording silently drops the take's audio. The
        // only caller that runs before recording (startRoutineRecording)
        // does so with movieOutput NOT recording, so this guard is safe and
        // protects against any reconfigure (device-change/refresh) landing
        // during an active recording. Runs on sessionQueue, same queue that
        // starts/stops movieOutput, so this read is consistent.
        if movieOutput.isRecording {
            NSLog("[MacCaptureEngine] Skipped capture-session reconfigure: a take is recording (audio device change deferred until the take ends).")
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        if let videoDevice = videoDevices.first(where: { $0.uniqueID == selectedVideoID }),
           let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
           captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        var attachedAudioUniqueID = ""
        if let audioDevice = audioDevices.first(where: { $0.uniqueID == selectedAudioID }),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
            attachedAudioUniqueID = audioDevice.uniqueID
        }
        if attachedAudioUniqueID != selectedAudioID {
            NSLog("[MacCaptureEngine] Requested audio input was not attached to the capture session (requested=\(selectedAudioID.isEmpty ? "<none>" : "set") attached=\(attachedAudioUniqueID.isEmpty ? "<none>" : "set")). Recording/detection will reflect the attached input.")
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        captureSession.commitConfiguration()
        scratchDetector.reset()
        rigLayoutDetector.reset()
        videoQueue.async {
            self.clearFixedRigLayout()
            self.resetPublishedVideoState()
        }

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
        // Video readiness is only required when a camera was actually
        // selected: DVS-only and MIDI-only capture setups intentionally run
        // with no video device chosen at all (`selectedVideoID` empty), and
        // `LivePerformedNotationTracker` already falls back to camera
        // evidence only when a controller source is absent — this signal
        // must not block those setups (canonical consolidation, Phase 2,
        // 2026-08-22: `isRoutineCaptureReady` must not require a camera that
        // was never requested).
        let sessionIsReady = captureSession.isRunning
            && (selectedVideoID.isEmpty || captureSessionHasInput(matching: selectedVideoID, mediaType: .video))
            && captureSessionHasInput(matching: selectedAudioID, mediaType: .audio)
#if ENABLE_TIMECODE_LIVE_TAP
        refreshLowLatencyTimecodeInput()
#endif
        Task { @MainActor in
            self.isCameraActive = self.captureSession.isRunning
            self.isRoutineCaptureReady = sessionIsReady
            self.activeCaptureAudioDeviceUniqueID = attachedAudioUniqueID

#if DEBUG && ENABLE_TIMECODE_LIVE_TAP
            let inputs = self.captureSession.inputs.compactMap { input -> String? in
                guard let deviceInput = input as? AVCaptureDeviceInput,
                      deviceInput.device.hasMediaType(.audio) else { return nil }
                let d = deviceInput.device
                return "\(d.localizedName) [\(d.uniqueID)]"
            }
            let inputsSummary = inputs.isEmpty ? "none" : inputs.joined(separator: "; ")
            TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo =
                "device=\(self.selectedAudioDeviceName) uid=\(attachedAudioUniqueID.isEmpty ? "(empty)" : attachedAudioUniqueID) inputs=[\(inputsSummary)]"
#endif
        }
    }

    private func captureSessionHasInput(matching uniqueID: String, mediaType: AVMediaType) -> Bool {
        captureSession.inputs.contains { input in
            guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
            return deviceInput.device.uniqueID == uniqueID && deviceInput.device.hasMediaType(mediaType)
        }
    }

    private func prepareRoutineRecording(
        selectedVideoID: String,
        selectedAudioID: String,
        videoDevices: [AVCaptureDevice],
        audioDevices: [AVCaptureDevice],
        captureTiming: CaptureTimingMetadata?
    ) throws -> PreparedRoutineRecording {
        let directory = try recordingsDirectoryURL()
        let startedAt = Date()
        let sessionID = recordingSessionConfig?.sessionID
            ?? CaptureCore.LocalRecordingNaming.sessionID()
        let takeIdentity: TakeIdentity
        if let pendingRoutineTakeIdentity {
            takeIdentity = pendingRoutineTakeIdentity
        } else {
            takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(
                sessionID: sessionID,
                takeNumber: try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
            )
        }
        let files = try CaptureCore.LocalRecordingFiles.make(
            in: directory,
            sessionID: sessionID,
            takeNumber: takeIdentity.takeNumber,
            roleLabel: "routine"
        )
        let audioURL = directory
            .appendingPathComponent(files.baseName)
            .appendingPathExtension("wav")

        let videoDeviceName = videoDevices.first(where: { $0.uniqueID == selectedVideoID })?.localizedName ?? "Unknown video input"
        let audioDeviceName = audioDevices.first(where: { $0.uniqueID == selectedAudioID })?.localizedName ?? "Unknown audio input"
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: recordingSessionConfig,
            takeIdentity: takeIdentity,
            files: files,
            recordingRole: "mac_routine_capture",
            platform: "macOS",
            appSurface: "ScratchLab Routine Recorder",
            sourceDeviceName: Host.current().localizedName ?? "Computer",
            videoDeviceUniqueID: selectedVideoID,
            videoDeviceName: videoDeviceName,
            audioDeviceUniqueID: selectedAudioID,
            audioDeviceName: audioDeviceName,
            captureTiming: captureTiming,
            startedAt: startedAt
        )
        let syncedSidecar = pendingWatchReply.map { sidecar.withWatchSync($0) } ?? sidecar
        pendingRoutineTakeIdentity = nil
        pendingWatchReply = nil

        return PreparedRoutineRecording(
            mediaURL: files.mediaURL,
            audioURL: audioURL,
            sidecarURL: files.sidecarURL,
            sidecar: syncedSidecar
        )
    }

    private func recordingsDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        let directory = baseDirectory
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineCaptures", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Synchronous first half of routine-take finalization.
    ///
    /// Runs on the AVFoundation completion (main) queue and MUST return without
    /// blocking: `didFinishRecordingTo` is delivered on the main dispatch queue,
    /// and the admitted builder tasks are `@MainActor`, so a synchronous
    /// `DispatchGroup.wait()` here would deadlock. This closes admission,
    /// captures the take's state, and schedules the second half via
    /// `group.notify(queue: finalizationQueue)`.
    private func finalizeRoutineRecording(outputFileURL: URL, error: Error?) {
        let captureErrorDescription = Self.routineCaptureFailureDescription(for: error)

        guard let sidecar = activeRoutineRecordingSidecar else {
            let message = captureErrorDescription != nil
                ? "Recording ended before it could be saved."
                : "Finalizing \(outputFileURL.lastPathComponent)..."
            publishRoutineFinalization(
                outputFileURL: outputFileURL,
                captureErrorDescription: captureErrorDescription,
                statusMessage: message,
                sessionID: nil,
                sidecar: nil)
            return
        }

        // Capture everything the async second half needs. The builder is kept
        // ATTACHED so already-admitted tasks can still feed it.
        let builder = activeRoutineDetectedNotationBuilder
        let sidecarURL = activeRoutineRecordingSidecarURL
            ?? CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: outputFileURL)
        let labelSource = lastScratchDetection == nil ? "unknown" : "detected"
        let audioDetector = activeRoutineAudioNotationDetector
        // The selected MIDI source is the authoritative device for CC6 platter
        // decode. Captured here (main queue, before the async second half) so
        // the decode is deterministic even if a device list refresh lands later.
        let selectedPlatterSourceName = selectedMIDIInputSourceName
        #if DEBUG
        let debugSession = activeRoutineMovementDebugSession
        #else
        let debugSession: RoutineMovementDebugSession? = nil
        #endif

        // Atomically close admission — no later admit() succeeds; late
        // observations are synchronously marked postFinalization on the capture
        // path.
        let group = builderAdmissionGate.close()

        // Prevent a second take from starting until async finalization completes.
        isRoutineFinalizationPending = true

        // Resume on a background queue after the group empties. This never blocks
        // the main queue / MainActor, so the admitted @MainActor tasks can run.
        group.notify(queue: finalizationQueue) { [weak self] in
            self?.completeRoutineFinalization(
                outputFileURL: outputFileURL,
                captureErrorDescription: captureErrorDescription,
                sidecar: sidecar,
                sidecarURL: sidecarURL,
                builder: builder,
                audioDetector: audioDetector,
                labelSource: labelSource,
                selectedPlatterSourceName: selectedPlatterSourceName,
                debugSession: debugSession)
        }
    }

    /// Asynchronous second half of routine-take finalization, run on
    /// `finalizationQueue` after the builder admission group empties. Detaches
    /// and drains the builder, freezes diagnostics, writes the sidecar +
    /// companions, clears take state, and publishes the completed UI state.
    private func completeRoutineFinalization(
        outputFileURL: URL,
        captureErrorDescription: String?,
        sidecar: CaptureCore.LocalRecordingSidecar,
        sidecarURL: URL,
        builder: RoutineDetectedNotationBuilder?,
        audioDetector: ScratchAudioNotationDetector?,
        labelSource: String,
        selectedPlatterSourceName: String,
        debugSession: RoutineMovementDebugSession?
    ) {
        var sidecar = sidecar

        // The group has emptied — no admitted task remains, so detaching the
        // builder is now safe.
        activeRoutineDetectedNotationBuilder = nil

        let audioSnapshot = audioDetector?.snapshot()
            ?? ScratchAudioNotationSnapshot(audioEvents: [], confidence: nil)
        let finalizationHostTime = CACurrentMediaTime()
        let motionEvents = builder?.movementEvents(now: finalizationHostTime) ?? []
        ScratchLabPerformanceSignpost.event(
            "MovementEventBuild",
            count: motionEvents.count,
            take: sidecar.appLocalTakeNumber)
        let capturedMidi = drainCapturedMidiCCEvents()
        reconnectSelectedMIDIInput()

        // Decode direct platter telemetry (RANE ONE MKII CC6 ring counter) into
        // movement events. This is the preferred record-movement source when
        // present; camera hand-tracking is a fallback / diagnostic only.
        //
        // Fail-closed: the decoder is invoked ONLY when the selected MIDI
        // device was resolved. A nil device name would otherwise disable
        // `derivePlatterMovementEvents`' device filter and accept every
        // channel-1 CC6 device. `resolvedControllerMovementEvents` returns []
        // when the selected source is absent/unresolved, so the camera (or DVS)
        // fallback is used instead of silently decoding arbitrary traffic.
        let controllerEvents = Self.resolvedControllerMovementEvents(
            selectedMIDISourceName: selectedPlatterSourceName,
            capturedMidi: capturedMidi)
        let usesControllerMovement = !controllerEvents.isEmpty

        // Drain the sibling raw-platter recorder (in-memory only).
        platterRecorderLock.lock()
        let platterEndRelative = max(0, CACurrentMediaTime() - platterRecordingStartTime)
        lastDrainedPlatterPositionTimeline = platterPositionRecorder
            .finishRecording(at: platterEndRelative)
        platterRecordingStartTime = 0
        platterRecorderLock.unlock()
        #if DEBUG
        timecodeNotationLock.lock()
        lastDrainedTimecodeNotationTimeline = timecodeNotationAccumulator?.finalizedTimeline()
        timecodeNotationDiagnosticsStorage.finalize(
            sampleCount: lastDrainedTimecodeNotationTimeline?.samples.count ?? 0,
            eventCount: 0)
        timecodeNotationAccumulator = nil
        timecodeNotationLock.unlock()
        #endif

        let normalizeID = ScratchLabPerformanceSignpost.begin("MovementNormalize")
        #if DEBUG
        let cameraOrDVS = TimecodeNotationCapturePrecedence.resolvedMovementEvents(
            notationRoutingEnabled: notationRoutingEnabled,
            cameraMovementEvents: motionEvents,
            drainedTimecodeNotationTimeline: lastDrainedTimecodeNotationTimeline)
        timecodeNotationLock.lock()
        timecodeNotationDiagnosticsStorage.finalize(
            sampleCount: lastDrainedTimecodeNotationTimeline?.samples.count ?? 0,
            eventCount: notationRoutingEnabled ? cameraOrDVS.count : 0)
        timecodeNotationLock.unlock()
        #else
        let cameraOrDVS = motionEvents
        #endif
        // Controller telemetry is authoritative when present; camera/DVS is the
        // fallback. The two are never merged into one event stream.
        let resolvedMotionEvents = usesControllerMovement ? controllerEvents : cameraOrDVS
        var notationSnapshot = RoutineNotationFusionEngine().snapshot(
            audioSnapshot: audioSnapshot,
            motionEvents: resolvedMotionEvents,
            detectedLabel: lastScratchDetection?.scratchName,
            labelSource: labelSource,
            labelConfidence: lastScratchDetection?.confidence,
            debugSession: debugSession
        ).withMixerMidiEvents(capturedMidi)
        // Controller provenance is preserved through fusion and `snapshot`
        // truthfully labels it (no post-hoc retag). Only the DEBUG DVS path
        // still needs `withTimecodeLiveMovementProvenance` because its events
        // are produced by a separate adapter and the fusion historically
        // relabelled them "video".
        #if DEBUG
        if !usesControllerMovement, notationRoutingEnabled, lastDrainedTimecodeNotationTimeline != nil {
            notationSnapshot = notationSnapshot.withTimecodeLiveMovementProvenance()
        }
        #endif
        ScratchLabPerformanceSignpost.end("MovementNormalize", normalizeID)
        ScratchLabPerformanceSignpost.eventNotationSnapshot(
            movement: notationSnapshot.recordMovementEvents.count,
            audio: notationSnapshot.audioEvents.count,
            fader: notationSnapshot.faderEvents.count,
            take: sidecar.appLocalTakeNumber)

        #if DEBUG
        let frozenDiagnostics = debugSession?.snapshot()
        publishRoutineMovementDiagnostics(frozenDiagnostics)
        lastMovementDiagnosticsSnapshot = frozenDiagnostics
        lastMovementTraceExport = movementTraceRecorder.export(
            takeID: sidecar.takeID,
            takeNumber: sidecar.appLocalTakeNumber,
            finalizationHostTime: finalizationHostTime)
        let replayDiagnostics = replayDiagnosticsFromPlatterTimeline()
        writeReplayDiagnosticsToDisk(diag: replayDiagnostics)
        #endif

        sidecar = sidecar.finalized(
            mediaFileName: outputFileURL.lastPathComponent,
            captureErrorDescription: captureErrorDescription
        )
        .withDetectedNotation(notationSnapshot)

        #if DEBUG
        writeMovementCompanionFilesForTake(sidecar: sidecar, sidecarURL: sidecarURL)
        #endif

        var statusMessage: String
        var sessionID: String?
        var finalizedSidecar: CaptureCore.LocalRecordingSidecar?
        do {
            try? CaptureJournalStore.appendMediaCommitted(
                storageKind: .routine,
                sidecar: sidecar)
            try writeRoutineRecordingSidecar(sidecar, to: sidecarURL)
            Task { @MainActor in
                self.lastRoutineDetectedNotation = notationSnapshot
            }
            try? CaptureJournalStore.appendTransactionFinalized(
                storageKind: .routine,
                sidecar: sidecar)
            finalizedSidecar = sidecar
            sessionID = sidecar.sessionID
            statusMessage = captureErrorDescription != nil
                ? "Recording ended before it could be saved completely."
                : "Finalizing \(outputFileURL.lastPathComponent)..."
        } catch {
            statusMessage = captureErrorDescription != nil
                ? "Recording ended before it could be saved completely."
                : "Finalizing \(outputFileURL.lastPathComponent)..."
            sessionID = nil
            finalizedSidecar = nil
        }

        // Clear per-take state so a later take can start.
        activeRoutineRecordingSidecar = nil
        activeRoutineRecordingSidecarURL = nil
        activeRoutineAudioNotationDetector = nil
        #if DEBUG
        activeRoutineMovementDebugSession = nil
        #endif
        pendingRoutineTakeIdentity = nil
        pendingWatchReply = nil

        publishRoutineFinalization(
            outputFileURL: outputFileURL,
            captureErrorDescription: captureErrorDescription,
            statusMessage: statusMessage,
            sessionID: sessionID,
            sidecar: finalizedSidecar)
    }

    /// `AVCaptureMovieFileOutput` may finish a manually stopped recording with
    /// a non-nil AVFoundation error while explicitly marking the file as having
    /// finished successfully. Treat only that documented marker as success;
    /// every other error remains a fail-closed capture failure.
    static func routineCaptureFailureDescription(for error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain,
           nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true {
            return nil
        }
        return error.localizedDescription
    }

    /// Publishes the completed take's UI state on the MainActor and clears the
    /// finalization-pending flag.
    private func publishRoutineFinalization(
        outputFileURL: URL,
        captureErrorDescription: String?,
        statusMessage: String,
        sessionID: String?,
        sidecar: CaptureCore.LocalRecordingSidecar?
    ) {
        Task { @MainActor in
            self.isRoutineRecording = false
            if captureErrorDescription == nil {
                self.lastRoutineRecordingURL = outputFileURL
                if let sidecar {
                    self.upsertRoutineTakeArtifactStatus(
                        self.provisionalRoutineTakeArtifactStatus(for: sidecar, readiness: .finalizing))
                }
            }
            self.lastRoutineRecordingSessionID = sessionID
            self.routineRecordingStatus = statusMessage
            self.isRoutineFinalizationPending = false
            self.refreshRoutineArtifactStatuses()
        }
    }

    private func writeRoutineRecordingSidecar(_ sidecar: CaptureCore.LocalRecordingSidecar, to url: URL) throws {
        let data = try sidecar.encodedData()
        try data.write(to: url, options: .atomic)
        try? CaptureAuditStore.persist(sidecar: sidecar, storageKind: .routine)
    }

    #if DEBUG
    /// Persists the frozen movement trace + diagnostics beside `sidecarURL` at
    /// take finalization, using this take's identity. Atomic writes; a write or
    /// encode failure is surfaced, not swallowed.
    private func writeMovementCompanionFilesForTake(
        sidecar: CaptureCore.LocalRecordingSidecar,
        sidecarURL: URL
    ) {
        let sidecarBase = sidecarURL.deletingPathExtension().lastPathComponent
        let dir = sidecarURL.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var errors: [String] = []

        if let trace = lastMovementTraceExport {
            let traceURL = dir.appendingPathComponent("\(sidecarBase)_movement_trace.json")
            do {
                try encoder.encode(trace).write(to: traceURL, options: .atomic)
            } catch {
                errors.append("movement_trace: \(error.localizedDescription)")
            }
        }
        if let diagnostics = lastMovementDiagnosticsSnapshot {
            let export = MovementDiagnosticsExport(
                schemaVersion: "scratchlab_movement_diagnostics_v1",
                takeID: sidecar.takeID,
                takeNumber: sidecar.appLocalTakeNumber,
                diagnostics: diagnostics
            )
            let diagnosticsURL = dir.appendingPathComponent("\(sidecarBase)_movement_diagnostics.json")
            do {
                try encoder.encode(export).write(to: diagnosticsURL, options: .atomic)
            } catch {
                errors.append("movement_diagnostics: \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            let message = "Movement diagnostics could not be written: \(errors.joined(separator: "; "))"
            Task { @MainActor in
                self.reportRoutineRecordingIssue(message)
            }
        }
    }
    #endif

    private func recoverInterruptedRoutineCaptures() {
        do {
            let directory = try recordingsDirectoryURL()
            let report = StagedCaptureRecoveryManager().recoverRecordingDirectory(
                at: directory,
                storageKind: .routine
            )
            if let summaryText = report.summaryText {
                routineRecordingStatus = summaryText
            }
        } catch {
            routineRecordingStatus = "Routine capture recovery needs attention."
        }
    }

    private func restoreLatestCompletedRoutineCapture() {
        guard !isRoutineRecording else { return }

        do {
            let directory = try recordingsDirectoryURL()
            let preferredSessionID = recordingSessionConfig?.sessionID
            guard let snapshot = Self.latestCompletedRoutineCapture(
                in: directory,
                preferredSessionID: preferredSessionID
            ) else {
                if preferredSessionID != nil {
                    lastRoutineRecordingURL = nil
                    lastRoutineRecordingSessionID = nil
                }
                return
            }

            lastRoutineRecordingURL = snapshot.mediaURL
            lastRoutineRecordingSessionID = snapshot.sessionID
            lastRoutineDetectedNotation = snapshot.detectedNotation
            routineRecordingStatus = "Ready to export \(snapshot.mediaURL.lastPathComponent)."
        } catch {
            routineRecordingStatus = "Routine capture recovery needs attention."
        }
    }

    private func refreshRoutineArtifactStatuses() {
        routineArtifactRefreshTask?.cancel()
        guard let directory = routineRecordingsFolderURL,
              let lastRoutineRecordingURL else {
            routineTakeArtifactStatuses = []
            return
        }

        let lastURL = lastRoutineRecordingURL
        routineArtifactRefreshTask = Task { [weak self] in
            let statuses = await Task.detached(priority: .userInitiated) {
                SessionArchiveBuilder().localRecordingArtifactStatuses(
                    lastRecordingURL: lastURL
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.routineRecordingsFolderURL == directory else { return }
                self.routineTakeArtifactStatuses = statuses
                self.lastRoutineDetectedNotation = statuses.last?.detectedNotation
                    ?? self.lastRoutineDetectedNotation
                if let latest = statuses.last {
                    self.applyRoutineArtifactStatusToMessage(latest)
                }
            }
        }
    }

    @MainActor
    private func applyRoutineArtifactStatusToMessage(_ status: TakeArtifactStatusSnapshot) {
        let takeLabel = "Take \(String(format: "%03d", status.takeNumber))"
        switch status.readiness {
        case .recording:
            routineRecordingStatus = "Recording \(takeLabel.lowercased())"
        case .finalizing:
            routineRecordingStatus = "\(takeLabel) is finalizing..."
        case .ready:
            if let videoSourceURL = status.videoSourceURL {
                routineRecordingStatus = "Ready to export \(videoSourceURL.lastPathComponent)."
            } else {
                routineRecordingStatus = "\(takeLabel) is ready to export."
            }
        case .missingAudio:
            routineRecordingStatus = "\(takeLabel) audio is missing or still finalizing."
        case .missingVideo:
            routineRecordingStatus = "\(takeLabel) video is missing or still finalizing."
        case .failed(let message):
            routineRecordingStatus = "\(takeLabel) failed: \(message)"
        }
    }

    @MainActor
    private func upsertRoutineTakeArtifactStatus(_ status: TakeArtifactStatusSnapshot) {
        var statuses = routineTakeArtifactStatuses.filter { $0.takeID != status.takeID }
        statuses.append(status)
        routineTakeArtifactStatuses = statuses.sorted { lhs, rhs in
            if lhs.takeNumber == rhs.takeNumber {
                return lhs.takeID < rhs.takeID
            }
            return lhs.takeNumber < rhs.takeNumber
        }
        applyRoutineArtifactStatusToMessage(status)
    }

    private func provisionalRoutineTakeArtifactStatus(
        for sidecar: CaptureCore.LocalRecordingSidecar,
        readiness: TakeArtifactReadiness
    ) -> TakeArtifactStatusSnapshot {
        let baseDirectory = activeRoutineRecordingSidecarURL?.deletingLastPathComponent()
            ?? routineRecordingsFolderURL
            ?? FileManager.default.temporaryDirectory
        let mediaURL = baseDirectory.appendingPathComponent(sidecar.mediaFileName)
        let audioURL = baseDirectory
            .appendingPathComponent(mediaURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")
        let videoExists = FileManager.default.fileExists(atPath: mediaURL.path)
        let audioExists = FileManager.default.fileExists(atPath: audioURL.path)
        return TakeArtifactStatusSnapshot(
            takeID: sidecar.takeID,
            takeNumber: sidecar.appLocalTakeNumber,
            bpm: sidecar.sessionConfig?.bpm,
            targetLabel: sidecar.sessionConfig?.scratchType.flatMap {
                $0 == .unknown ? nil : $0.title
            },
            sessionConfig: sidecar.sessionConfig,
            startedAt: sidecar.startedAt,
            audioSourceURL: audioURL,
            videoSourceURL: mediaURL,
            audioExists: audioExists,
            videoExists: videoExists,
            audioBytes: fileSizeOrZero(at: audioURL),
            videoBytes: fileSizeOrZero(at: mediaURL),
            finalizedAt: sidecar.endedAt,
            readiness: readiness,
            detectedNotation: sidecar.detectedNotation,
            detectedLabel: sidecar.reviewDecision?.detectedLabel
                ?? sidecar.detectedNotation?.detectedLabel
                ?? sidecar.reviewDecision?.label,
            labelConfidence: sidecar.reviewDecision?.confidence ?? sidecar.detectedNotation?.labelConfidence
        )
    }

    private func fileSizeOrZero(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func latestCompletedRoutineCapture(
        in directory: URL,
        preferredSessionID: String? = nil,
        fileManager: FileManager = .default
    ) -> CompletedRoutineCaptureSnapshot? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { sidecarURL -> CompletedRoutineCaptureSnapshot? in
                guard let data = try? Data(contentsOf: sidecarURL),
                      let sidecar = try? routineSidecarDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data),
                      sidecar.recordingStatus == "completed" else {
                    return nil
                }
                if let preferredSessionID, sidecar.sessionID != preferredSessionID {
                    return nil
                }

                let mediaURL = directory.appendingPathComponent(sidecar.mediaFileName)
                guard fileManager.fileExists(atPath: mediaURL.path) else { return nil }

                return CompletedRoutineCaptureSnapshot(
                    mediaURL: mediaURL,
                    sidecarURL: sidecarURL,
                    sessionID: sidecar.sessionID,
                    takeID: sidecar.takeID,
                    endedAt: sidecar.endedAt ?? sidecar.startedAt,
                    detectedNotation: sidecar.detectedNotation
                )
            }
            .sorted { lhs, rhs in
                if lhs.endedAt != rhs.endedAt {
                    return lhs.endedAt > rhs.endedAt
                }
                return lhs.mediaURL.lastPathComponent > rhs.mediaURL.lastPathComponent
            }
            .first
    }

    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let signpostID = ScratchLabPerformanceSignpost.begin("CameraFrameProcess")
        defer { ScratchLabPerformanceSignpost.end("CameraFrameProcess", signpostID) }

        let now = CACurrentMediaTime()
        let presentationTime = Self.sampleBufferPresentationTime(sampleBuffer)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        #if DEBUG
        debugFramesReceived += 1
        activeRoutineMovementDebugSession?.framesReceived += 1
        #endif

        let detectedLayout = fixedRigLayout == nil
            ? rigLayoutDetector.detectLayout(in: pixelBuffer, useLockedCadence: calibrationLocked)
            : nil
        let resolvedLayout = resolveFixedRigLayout(from: detectedLayout)
        let calibratedLayout = applyCalibration(to: resolvedLayout)
        let perspectiveLayout = applyPerspective(to: calibratedLayout)
        let layout = applyZoneCalibration(to: perspectiveLayout)
        let usesManualRigGuide = layout != nil && fixedRigLayoutUsesManualGuide
        publishRigLayoutIfNeeded(layout, usesManualRigGuide: usesManualRigGuide)
        if shouldPublishPerformerMonitorFrame {
            publishPerformerMonitorFrame(from: pixelBuffer, layout: layout, at: now)
        }

        // Hand pose always runs at the active rate; the rig detector manages its own cadence.
        // Accumulated-deadline scheduling (not "reset to the accepted frame") so
        // a 30 fps source is never quantized down to 15 fps by the 40 ms gate.
        // The shared camera processor owns the cadence phase.
        guard cameraProcessor.shouldProcess(frameAt: now, interval: activeHandPoseInterval) else { return }

        #if DEBUG
        debugFramesAnalyzed += 1
        activeRoutineMovementDebugSession?.framesAnalyzed += 1
        let trackingRegion = resolvedHandTrackingRegion(for: layout)
        debugLastROI = trackingRegion
        #else
        let trackingRegion = resolvedHandTrackingRegion(for: layout)
        #endif

        handPoseRequest.regionOfInterest = trackingRegion
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try requestHandler.perform([handPoseRequest])
            let visionCompletionTime = CACurrentMediaTime()
            #if DEBUG
            if handPoseRequest.results?.first != nil {
                debugVisionReturnedHand += 1
            }
            #endif

            let observation = handPoseRequest.results?.first
            let activeThreshold: Float = isRoutineRecording
                ? recordingJointConfidenceThreshold
                : standardJointConfidenceThreshold
            let joints = observation.map {
                extractHandJoints(from: $0, trackingRegion: trackingRegion,
                                  minimumJointConfidence: activeThreshold)
            } ?? [:]

            // Shared production camera processor: cadence → stable anchor →
            // platter geometry → angular tracker → builder observation. The SAME
            // processor drives live capture and offline replay.
            let platterCentre = cameraPlatterCentre(for: layout)
            let geometryConfidence = layout?.confidence ?? 0.32
            let processed = cameraProcessor.process(
                frameAt: now,
                joints: joints, platterCentre: platterCentre,
                geometryConfidence: geometryConfidence)
            cameraPlatterCalibrationInsufficient = processed.calibrationInsufficient

            #if DEBUG
            if let anchorMode = processed.anchorMode {
                activeRoutineMovementDebugSession?.recordAnchorIdentity(
                    jointNames: processed.anchorJointNames,
                    mode: anchorMode.rawValue,
                    switched: processed.anchorSwitched)
            }
            #endif

            guard processed.detected, let rawTrackedPoint = processed.anchorPoint else {
                #if DEBUG
                debugTrackedPointReturnedNil += 1
                #endif
                // No usable anchor (no hand, or the time-bounded anchor hold
                // expired). The processor already fed the rotation tracker a miss.
                lastContinuityHandPoint = nil
                handleHandTrackingMiss(presentationTime: presentationTime,
                                       processingStartTime: now,
                                       visionCompletionTime: visionCompletionTime,
                                       kind: .miss,
                                       rejectedPoint: nil)
                return
            }
            let rawJointConfidence = processed.anchorConfidence

            // Reject impossible positional jumps: a new point requiring hand velocity
            // exceeding maxPlatterJumpVelocity is Vision noise, not real motion.
            if let lastPoint = lastContinuityHandPoint {
                let elapsed = max(0.001, now - lastContinuityHandPointTime)
                if Self.isImpossibleHandJump(
                    from: lastPoint, to: rawTrackedPoint,
                    elapsed: elapsed, maxVelocity: maxPlatterJumpVelocity
                ) {
                    #if DEBUG
                    debugImpossibleJumpRejects += 1
                    activeRoutineMovementDebugSession?.recordImpossibleJumpReject()
                    #endif
                    lastContinuityHandPoint = nil
                    handleHandTrackingMiss(presentationTime: presentationTime,
                                           processingStartTime: now,
                                           visionCompletionTime: visionCompletionTime,
                                           kind: .jumpRejected,
                                           rejectedPoint: rawTrackedPoint)
                    return
                }
            }

            lastContinuityHandPoint = rawTrackedPoint
            lastContinuityHandPointTime = now

            #if DEBUG
            debugTrackedPointReturnedPoint += 1
            debugHandObservationsFound += 1
            let prevState = lastPublishedHandMotionState
            #endif

            missedHandTrackingFrames = 0

            // Keep the legacy X tracker fed (unsmoothed = accurate velocity) for
            // coach display + its diagnostics; its direction/confidence no longer
            // feed notation — the angular processor is the notation authority.
            let direction = handDirectionTracker.recordObservation(rawPoint: rawTrackedPoint, at: now)

            // Platter recorder: continuous ANGULAR position (radians), never raw X.
            platterRecorderLock.lock()
            if platterPositionRecorder.isRecording {
                let takeRelativeTime = max(0, now - platterRecordingStartTime)
                let angularRadians = processed.position.map { $0 * 2 * Double.pi } ?? 0
                platterPositionRecorder.observe(point: CGPoint(x: angularRadians, y: 0), at: takeRelativeTime)
                #if DEBUG
                debugObserveAttempted += 1
                activeRoutineMovementDebugSession?.recordPlatterObserveAttempted()
                #endif
            } else {
                #if DEBUG
                debugObserveSkippedNotRecording += 1
                activeRoutineMovementDebugSession?.recordPlatterObserveSkippedNotRecording()
                #endif
            }
            platterRecorderLock.unlock()

            // The processor already mapped angular rotation → semantic direction.
            let movementState = processed.state

            #if DEBUG
            if movementState == .steady {
                activeRoutineMovementDebugSession?.recordSteadyIdleReason(handDirectionTracker.lastIdleReason)
            }
            if direction != debugLastRawDirection {
                activeRoutineMovementDebugSession?.recordRawDirectionChange()
                debugLastRawDirection = direction
            }
            if movementState != prevState { debugDirectionChanges += 1 }
            if movementState != prevState {
                activeRoutineMovementDebugSession?.recordSemanticDirectionChange()
            }
            #endif

            // Smoothed point is DISPLAY ONLY; the builder receives the angular
            // position, not this image point.
            let currentPoint = smoothedTrackingPoint(from: rawTrackedPoint)
            #if DEBUG
            activeRoutineMovementDebugSession?.recordSample(
                rawPoint: rawTrackedPoint,
                displayedPoint: currentPoint,
                confidence: processed.confidence,
                rawDirection: direction,
                semanticState: movementState
            )
            publishRoutineMovementDiagnostics(activeRoutineMovementDebugSession?.snapshot())
            // Compute the dedup outcome before publish mutates lastPublished*
            // so the trace records exactly what the builder will receive.
            let dedupRejected = shouldDedupHandTracking(detected: true, position: currentPoint, state: movementState)
            let observationID = recordMovementTraceObservation(
                kind: .real,
                presentationTime: presentationTime,
                processingStartTime: now,
                visionCompletionTime: visionCompletionTime,
                trackerPoint: rawTrackedPoint,
                trackerTime: now,
                jointConfidence: Double(rawJointConfidence),
                builderPosition: processed.position,
                builderState: movementState,
                builderConfidence: processed.confidence,
                rawDirection: direction,
                idleReason: handDirectionTracker.lastIdleReason,
                trackerConfidence: Double(handDirectionTracker.confidence),
                semanticDirection: movementState,
                rejectedPoint: nil,
                dedupRejected: dedupRejected
            )
            publishHandTrackingIfNeeded(detected: true, position: currentPoint, state: movementState,
                                        movementPosition: processed.position,
                                        movementConfidence: processed.confidence,
                                        observationID: observationID)
            #else
            publishHandTrackingIfNeeded(detected: true, position: currentPoint, state: movementState,
                                        movementPosition: processed.position,
                                        movementConfidence: processed.confidence)
            #endif
        } catch {
            Task { @MainActor in
                self.statusMessage = "Hand tracking paused. Adjust framing and try again."
            }
        }
    }

    private func handMotionState(from direction: HandDirectionTracker.Direction) -> HandMotionState {
        // Vision reports unmirrored camera-space X from the raw pixel buffer, while capture
        // notation needs semantic record movement. Manual routine-capture validation showed the
        // previous direct mapping was inverted at the source: positive-X camera motion was being
        // published as forward even though the corresponding record movement is backward. Keep
        // the normalization in one place so live guidance, notation events, and CXL all inherit
        // the same direction contract.
        if let normalizedDirection = Self.normalizedRecordDirection(forCameraSpaceDirection: direction) {
            switch normalizedDirection {
            case .forward:
                return .movingRight
            case .backward:
                return .movingLeft
            }
        }

        switch direction {
        case .idle:
            return .steady
        case .searching:
            return .searching
        case .movingForward, .movingBackward:
            return .steady
        }
    }

    private var activeHandPoseInterval: CFTimeInterval {
        isRoutineRecording ? routineRecordingHandPoseInterval : idleHandPoseInterval
    }

    private func publishPerformerMonitorFrame(from pixelBuffer: CVPixelBuffer, layout: DJRigLayout?, at now: CFTimeInterval) {
        guard now - lastPerformerMonitorFrameTime >= 0.20 else { return }
        lastPerformerMonitorFrameTime = now

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        guard sourceWidth > 0 else { return }

        let maxOutputWidth: CGFloat = 960
        let scale = min(maxOutputWidth / sourceWidth, 1)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let outputImage = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = performerMonitorCIContext.jpegRepresentation(
            of: outputImage,
            colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55]
        ) else {
            return
        }

        let zones = (layout?.zones ?? []).map { zone in
            PerformerMonitorZone(
                role: zone.role.rawValue,
                title: zone.role.title,
                minX: zone.boundingBox.minX,
                minY: zone.boundingBox.minY,
                width: zone.boundingBox.width,
                height: zone.boundingBox.height
            )
        }

        DispatchQueue.main.async {
            self.performerMonitorFrame = PerformerMonitorFrame(
                timestamp: Date().timeIntervalSince1970,
                jpegData: jpegData,
                guidanceCue: self.babyScratchGuidanceCue,
                guidanceDetail: self.babyScratchGuidanceDetail,
                scratchStatusTitle: self.scratchStatusTitle,
                rigStatusTitle: self.rigStatusTitle,
                audioPercent: self.formattedAudioPercent,
                detectionCount: self.scratchDetectionCount,
                highlightedZoneRole: self.highlightedZoneRole.rawValue,
                zones: zones
            )
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let signpostID = ScratchLabPerformanceSignpost.begin("AudioAnalyze")
        defer { ScratchLabPerformanceSignpost.end("AudioAnalyze", signpostID) }

        guard let audioPacket = Self.audioPacket(from: sampleBuffer) else { return }

#if ENABLE_TIMECODE_LIVE_TAP
        // Forward stereo audio to the timecode live tap, if enabled.
        // Suppress the legacy 7,168-frame source only while a recently
        // observed, valid multichannel AVAudioEngine callback proves the
        // low-latency path is actually alive. Engine startup alone is not
        // sufficient: the Rane can bind successfully and then stop rendering,
        // which previously left DVS with no source until the bridge went stale.
        let heartbeatNow = CACurrentMediaTime()
        let lowLatencyTapFresh = timecodeInputStateLock.withLock {
            timecodeInputTapHeartbeat.isFresh(at: heartbeatNow)
        }
        publishLowLatencyTimecodeTapDiagnostic(now: heartbeatNow)
        if !lowLatencyTapFresh,
           let callback = timecodeAudioCallback,
           let stereoResult = TimecodeCMSampleBufferAdapter.stereoSampleResult(from: sampleBuffer) {
            callback(stereoResult.left, stereoResult.right, stereoResult.sampleRate, stereoResult.hostTime)
        }
#endif

        let measuredLevel = Self.level(from: audioPacket.samples)
        let hasFiniteMeasuredLevel = measuredLevel.isFinite
        let sanitizedLevel = hasFiniteMeasuredLevel ? min(max(measuredLevel, 0), 1) : 0
        // Slice O — diagnostics-only feed; does not affect scratch
        // detection, notation, scoring, or export. Throttled internally
        // so the @Published summary updates at most ~5 Hz.
        ScratchLabRuntimeDiagnostics.shared.recordAudioSamplesForOnsetDiagnostics(
            audioPacket.samples,
            sampleRate: audioPacket.sampleRate
        )
        let detection = scratchDetector.process(samples: audioPacket.samples, sampleRate: audioPacket.sampleRate)
        if detection != nil {
            ScratchLabPerformanceSignpost.event("AudioOnsetDetected")
        }
        if (isRoutineRecording || movieOutput.isRecording), !allowsLocalScratchPlayback {
            activeRoutineAudioNotationDetector?.process(samples: audioPacket.samples, sampleRate: audioPacket.sampleRate)
        }
        let now = CACurrentMediaTime()
        let shouldPublishAudioLevel = now - lastPublishedAudioLevelTime >= audioLevelPublishInterval
        if shouldPublishAudioLevel {
            lastPublishedAudioLevelTime = now
        }

        guard shouldPublishAudioLevel || detection != nil else { return }

        Task { @MainActor in
            if shouldPublishAudioLevel {
                self.publishAudioSignalLevel(
                    hasFiniteMeasuredLevel ? sanitizedLevel : nil,
                    receivedAt: now
                )
            }
            if let detection {
                self.lastScratchDetection = detection
                self.scratchDetectionCount += 1
                self.rewardScratchIfNeeded(detection)
                if self.cxlRecorder.isRecording {
                    self.cxlRecorder.recordAudioScratch(
                        confidence: detection.confidence / 100.0,
                        rms: nil,
                        onset: true
                    )
                    self.publishCXLState()
                }
            }
        }
    }

    private func rewardScratchIfNeeded(_ detection: MacScratchDetectionResult) {
        guard detection.accuracy >= 45 else { return }

        let now = Date()
        if let lastStarAwardAt, now.timeIntervalSince(lastStarAwardAt) < 0.45 {
            return
        }
        lastStarAwardAt = now

        sessionStars += 1
        let roles = DJRigZone.Role.allCases
        let currentIndex = roles.firstIndex(of: highlightedZoneRole) ?? 0
        highlightedZoneRole = roles[(currentIndex + 1) % roles.count]
    }

    private func resolveFixedRigLayout(from detectedLayout: DJRigLayout?) -> DJRigLayout? {
        // Invariant: once fixedRigLayout is set it is frozen until the user explicitly resets
        // (resetCalibration, camera source change, manualRigGuideEnabled toggle, or stop).
        // The rig detector is skipped entirely when fixedRigLayout != nil (see processVideoSampleBuffer),
        // so live detection can never silently shift the hand ROI after the first lock.
        if let fixedRigLayout {
            return fixedRigLayout
        }

        if let detectedLayout {
            fixedRigLayout = detectedLayout
            fixedRigLayoutUsesManualGuide = false
            return detectedLayout
        }

        guard manualRigGuideEnabled else { return nil }
        let fallbackLayout = manualFallbackLayout()
        fixedRigLayout = fallbackLayout
        fixedRigLayoutUsesManualGuide = true
        return fallbackLayout
    }

    private func applyCalibration(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }
        let adjustedUnion = adjustedBoundingBox(layout.unionBox)
        return DJRigLayout(zones: DJRigLayout.zones(in: adjustedUnion, tuning: currentZoneTuning), confidence: layout.confidence)
    }

    private func applyZoneCalibration(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }

        let adjustedZones = layout.zones.map { zone in
            DJRigZone(
                role: zone.role,
                boundingBox: adjustedBoundingBox(zone.boundingBox, using: zoneAdjustment(for: zone.role))
            )
        }

        return DJRigLayout(zones: adjustedZones, confidence: layout.confidence)
    }

    private func manualFallbackLayout() -> DJRigLayout {
        let union: CGRect
        if isUsingDeskViewCamera {
            union = CGRect(x: 0.03, y: 0.08, width: 0.94, height: 0.62)
        } else {
            union = CGRect(x: 0.12, y: 0.18, width: 0.76, height: 0.48)
        }
        return DJRigLayout(zones: DJRigLayout.zones(in: union, tuning: currentZoneTuning), confidence: 0.32)
    }

    /// Result of `trackedHandPoint`: the resolved anchor point plus its identity,
    /// so diagnostics can record WHICH joints formed the anchor (and whether it
    /// switched this frame).
    /// Canonical joint key for the stable-anchor math. Vision's
    /// `JointName.rawValue.rawValue` is an opaque key (`VNHLKWRI`, `VNHLKITIP`,
    /// …), not the human-readable name the anchor math keys on, so this maps
    /// every joint we query onto the canonical name (`wrist`, `indexMCP`, …).
    static func canonicalAnchorJointName(_ name: VNHumanHandPoseObservation.JointName) -> String {
        switch name {
        case .wrist: return "wrist"
        case .thumbCMC: return "thumbCMC"
        case .indexMCP: return "indexMCP"
        case .middleMCP: return "middleMCP"
        case .ringMCP: return "ringMCP"
        case .littleMCP: return "littleMCP"
        case .thumbTip: return "thumbTip"
        case .indexTip: return "indexTip"
        case .middleTip: return "middleTip"
        case .ringTip: return "ringTip"
        case .littleTip: return "littleTip"
        case .thumbIP: return "thumbIP"
        case .indexDIP: return "indexDIP"
        case .middleDIP: return "middleDIP"
        case .ringDIP: return "ringDIP"
        case .littleDIP: return "littleDIP"
        case .indexPIP: return "indexPIP"
        case .middlePIP: return "middlePIP"
        case .ringPIP: return "ringPIP"
        case .littlePIP: return "littlePIP"
        default: return name.rawValue.rawValue
        }
    }

    /// Extracts canonical joint samples (confidence + ROI gated) from a Vision
    /// hand-pose observation. Stateless — the stable anchor and angular tracking
    /// live in `CameraMovementProcessor`, not here. Returns an empty dictionary
    /// when no joint passes the gates.
    private func extractHandJoints(
        from observation: VNHumanHandPoseObservation,
        trackingRegion: CGRect,
        minimumJointConfidence: Float
    ) -> [String: HandAnchorSample] {
        let jointNames: [VNHumanHandPoseObservation.JointName] = [
            .indexTip, .middleTip, .ringTip, .littleTip, .thumbTip,
            .indexDIP, .middleDIP, .ringDIP, .littleDIP, .thumbIP,
            .indexPIP, .middlePIP, .ringPIP, .littlePIP,
            .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP,
            .wrist
        ]
        var joints: [String: HandAnchorSample] = [:]

        #if DEBUG
        self.debugJointsInspectedTotal += jointNames.count
        #endif
        for jointName in jointNames {
            guard let recognizedPoint = try? observation.recognizedPoint(jointName),
                  recognizedPoint.confidence >= minimumJointConfidence else {
                #if DEBUG
                self.debugJointsRejectedLowConfidence += 1
                #endif
                continue
            }
            let point = recognizedPoint.location
            guard trackingRegion.contains(point) else {
                #if DEBUG
                self.debugJointsRejectedOutsideROI += 1
                #endif
                continue
            }
            #if DEBUG
            self.debugJointsAcceptedCandidates += 1
            if recognizedPoint.confidence < standardJointConfidenceThreshold {
                self.debugJointsRelaxedAccepted += 1
            }
            #endif
            joints[Self.canonicalAnchorJointName(jointName)] = HandAnchorSample(
                location: point, confidence: recognizedPoint.confidence)
        }
        return joints
    }

    private func preferredHandTrackingRegion(for layout: DJRigLayout?) -> CGRect {
        let base = layout?.unionBox ?? CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.72)
        return expanded(base, dx: 0.10, dy: 0.18)
            .intersection(CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.94))
    }

    private func resolvedHandTrackingRegion(for layout: DJRigLayout?) -> CGRect {
        let region = preferredHandTrackingRegion(for: layout)
        guard !region.isNull, !region.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return region
    }

    /// Resolves the platter centre for physical-rotation tracking from the
    /// calibrated active-deck geometry. Returns nil when there is no reliable
    /// deck geometry to anchor the platter, which the caller treats as
    /// "camera calibration insufficient" (fail-closed, never raw X).
    ///
    /// The platter is approximated as the active deck zone's centre: the
    /// highlighted deck when set, otherwise the right deck (the Rane right
    /// platter is the scratch deck). No per-frame anchor dependency — the centre
    /// is geometry-derived so it is identical across live and replay.
    private func cameraPlatterCentre(for layout: DJRigLayout?) -> CGPoint? {
        guard let layout else { return nil }
        let deckZones = layout.zones.filter { $0.role != .mixer }
        guard !deckZones.isEmpty else { return nil }
        if let highlighted = layout.zone(for: highlightedZoneRole), highlighted.role != .mixer {
            return highlighted.center
        }
        return deckZones.last?.center  // right deck default
    }

    private func smoothedTrackingPoint(from point: CGPoint) -> CGPoint {
        guard let smoothedHandPoint else {
            self.smoothedHandPoint = point
            return point
        }

        let alpha: CGFloat = 0.34
        let smoothed = CGPoint(
            x: smoothedHandPoint.x + ((point.x - smoothedHandPoint.x) * alpha),
            y: smoothedHandPoint.y + ((point.y - smoothedHandPoint.y) * alpha)
        )
        self.smoothedHandPoint = smoothed
        return smoothed
    }

    private func handleHandTrackingMiss(presentationTime: Double,
                                        processingStartTime: Double,
                                        visionCompletionTime: Double?,
                                        kind: MovementTraceObservation.PointKind,
                                        rejectedPoint: CGPoint?) {
        missedHandTrackingFrames += 1

        #if DEBUG
        debugMissedFrameCount += 1
        #endif

        let direction = handDirectionTracker.recordMiss()
        // NOTE: the rotation tracker's miss is fed by the shared camera
        // processor (which owns it), not here — a double miss would corrupt the
        // elapsed-time hold/reset accounting.

        if direction == .searching {
            // Extended miss — clear all hand state.
            smoothedHandPoint = nil
            #if DEBUG
            let observationID = recordMovementTraceObservation(
                kind: kind,
                presentationTime: presentationTime,
                processingStartTime: processingStartTime,
                visionCompletionTime: visionCompletionTime,
                trackerPoint: nil,
                trackerTime: processingStartTime,
                jointConfidence: nil,
                builderPosition: nil, builderState: .searching, builderConfidence: nil,
                rawDirection: direction, idleReason: nil,
                trackerConfidence: Double(handDirectionTracker.confidence),
                semanticDirection: .searching,
                rejectedPoint: rejectedPoint,
                dedupRejected: false
            )
            publishHandTrackingIfNeeded(detected: false, position: nil, state: .searching,
                                        movementPosition: nil, movementConfidence: 0,
                                        observationID: observationID)
            #else
            publishHandTrackingIfNeeded(detected: false, position: nil, state: .searching,
                                        movementPosition: nil, movementConfidence: 0)
            #endif
        } else {
            // Brief miss — hold the last position and direction so the coach doesn't flicker.
            let movementState = handMotionState(from: direction)
            #if DEBUG
            let dedupRejected = shouldDedupHandTracking(
                detected: smoothedHandPoint != nil,
                position: smoothedHandPoint,
                state: movementState)
            let observationID = recordMovementTraceObservation(
                kind: kind,
                presentationTime: presentationTime,
                processingStartTime: processingStartTime,
                visionCompletionTime: visionCompletionTime,
                trackerPoint: nil,
                trackerTime: processingStartTime,
                jointConfidence: nil,
                builderPosition: nil,
                builderState: movementState,
                builderConfidence: Double(handDirectionTracker.confidence),
                rawDirection: direction,
                idleReason: nil,
                trackerConfidence: Double(handDirectionTracker.confidence),
                semanticDirection: movementState,
                rejectedPoint: rejectedPoint,
                dedupRejected: dedupRejected
            )
            publishHandTrackingIfNeeded(
                detected: smoothedHandPoint != nil,
                position: smoothedHandPoint,
                state: movementState,
                movementPosition: nil, movementConfidence: 0,
                observationID: observationID
            )
            #else
            publishHandTrackingIfNeeded(
                detected: smoothedHandPoint != nil,
                position: smoothedHandPoint,
                state: movementState,
                movementPosition: nil, movementConfidence: 0
            )
            #endif
        }
    }

    private var shouldPublishPerformerMonitorFrame: Bool {
        performerMonitorDemandQueue.sync { performerMonitorStreamingEnabled }
    }

    /// Returns true when live input should be skipped because the Review tab
    /// suspended it and no routine recording is protecting against suspension.
    /// Pure function of two booleans — tested in LiveInputSuspensionTests
    /// without any AV, camera, or UI dependencies.
    static func isLiveInputEffectivelySuspended(
        suspendedForReview: Bool,
        routineRecordingActive: Bool
    ) -> Bool {
        suspendedForReview && !routineRecordingActive
    }

    /// Live capture-sample processing is enabled when the engine is
    /// running, recording, CXL-recording, or streaming performer-monitor
    /// frames.  When `isLiveInputSuspendedForReview` is true, processing
    /// is disabled UNLESS a routine recording is active — recordings are
    /// never suspended so take capture is never interrupted.
    private var shouldProcessCaptureSamples: Bool {
        guard !Self.isLiveInputEffectivelySuspended(
            suspendedForReview: isLiveInputSuspendedForReview,
            routineRecordingActive: isRoutineRecording
        ) else { return false }
        return isRunning || isRoutineRecording || cxlRecorder.isRecording || shouldPublishPerformerMonitorFrame
    }

    private func publishRigLayoutIfNeeded(_ layout: DJRigLayout?, usesManualRigGuide: Bool) {
        guard lastPublishedRigLayout != layout || lastPublishedUsesManualRigGuide != usesManualRigGuide else {
            return
        }

        lastPublishedRigLayout = layout
        lastPublishedUsesManualRigGuide = usesManualRigGuide

        Task { @MainActor in
            self.rigLayout = layout
            self.isUsingManualRigGuide = usesManualRigGuide
        }
    }

    /// Whether `publishHandTrackingIfNeeded` would suppress this observation.
    /// Pure function of the last-published state — kept separate so the trace
    /// recorder can record the same dedup outcome the builder will see.
    private func shouldDedupHandTracking(detected: Bool, position: CGPoint?, state: HandMotionState) -> Bool {
        let stateChanged = lastPublishedHandMotionState != state
        return !(lastPublishedHandDetected != detected
            || lastPublishedHandPosition != position
            || stateChanged)
    }

    /// Host-time presentation timestamp of a video sample buffer. Falls back
    /// to the current host clock when the buffer carries no valid PTS.
    private static func sampleBufferPresentationTime(_ sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid { return pts.seconds }
        if pts.isIndefinite { return CACurrentMediaTime() }
        return CACurrentMediaTime()
    }

    #if DEBUG
    /// Records one chronological movement-trace observation at enqueue time and
    /// returns its stable observation ID. DEBUG-only — the trace is the
    /// capture-evidence path; it must never depend on MainActor.
    ///
    /// `builderPosition`/`builderState`/`builderConfidence` are the ACTUAL builder
    /// input: they must be nil whenever the builder was not fed (dedup rejected,
    /// continuity-filled, or a miss/jump that never reached publication).
    @discardableResult
    private func recordMovementTraceObservation(
        kind: MovementTraceObservation.PointKind,
        presentationTime: Double,
        processingStartTime: Double,
        visionCompletionTime: Double?,
        trackerPoint: CGPoint?,
        trackerTime: Double,
        jointConfidence: Double?,
        builderPosition: Double?,
        builderState: HandMotionState?,
        builderConfidence: Double?,
        rawDirection: HandDirectionTracker.Direction?,
        idleReason: HandDirectionTracker.IdleReason?,
        trackerConfidence: Double?,
        semanticDirection: HandMotionState?,
        rejectedPoint: CGPoint?,
        dedupRejected: Bool
    ) -> Int {
        // The builder is only fed when the point actually reached publication
        // (not dedup-rejected). Record its inputs as nil otherwise.
        let fedToBuilder = !dedupRejected
        guard isRoutineRecording else { return -1 }
        let takeRelativeTime = max(0, processingStartTime - movementTraceRecordingStartHostTime)
        return movementTraceRecorder.recordObservation(
            kind: kind,
            presentationTime: presentationTime,
            processingStartTime: processingStartTime,
            visionCompletionTime: visionCompletionTime,
            takeRelativeTime: takeRelativeTime,
            trackerPoint: trackerPoint.map(MovementTraceObservation.Point.init),
            trackerTime: trackerTime,
            jointConfidence: jointConfidence,
            builderPoint: fedToBuilder ? builderPosition.map { .init(x: $0, y: 0) } : nil,
            builderState: fedToBuilder ? builderState.map { String(describing: $0) } : nil,
            builderConfidence: fedToBuilder ? builderConfidence : nil,
            rawDirection: rawDirection.map { String(describing: $0) },
            idleReason: idleReason?.rawValue,
            trackerConfidence: trackerConfidence,
            semanticDirection: semanticDirection.map { String(describing: $0) },
            rejectedPoint: rejectedPoint.map(MovementTraceObservation.Point.init),
            dedupRejected: dedupRejected
        )
    }
    #endif

    private func publishHandTrackingIfNeeded(
        detected: Bool,
        position: CGPoint?,          // display point (smoothed image space)
        state: HandMotionState,
        movementPosition: Double?,   // angular position for the builder
        movementConfidence: Double,  // evidence-based angular confidence for the builder
        observationID: Int? = nil
    ) {
        guard !shouldDedupHandTracking(detected: detected, position: position, state: state) else {
            #if DEBUG
            activeRoutineMovementDebugSession?.recordPublishHandTrackingDedupSkip()
            #endif
            return
        }
        #if DEBUG
        activeRoutineMovementDebugSession?.recordPublishHandTrackingCall()
        #endif

        let prevState = lastPublishedHandMotionState
        let stateChanged = prevState != state
        lastPublishedHandDetected = detected
        lastPublishedHandPosition = position
        lastPublishedHandMotionState = state

        // The legacy X-direction tracker's confidence is only a CXL/coach signal;
        // it must NEVER determine angular notation confidence. `movementConfidence`
        // (angular) is the notation authority.
        let motionConfidence = Double(handDirectionTracker.confidence)
        let cxlDir = cxlDirectionFrom(state)
        let cxlSrc = cxlSignalSource()
        let cxlPrevDir = cxlDirectionFrom(prevState)

        // Admit the builder task through the per-take gate. nil means admission
        // is closed (post-finalization or no active take) — the builder is then
        // never fed.
        let token = builderAdmissionGate.admit()
        #if DEBUG
        // Rejected admission must be recorded synchronously on the capture path,
        // not in an untracked MainActor task, so the skip metadata is already in
        // the frozen trace at export time.
        if token == nil, let observationID {
            movementTraceRecorder.recordBuilderExecution(
                index: observationID,
                executionTime: CACurrentMediaTime(),
                action: "skipped",
                rejectionReason: nil,
                finishedEventIndex: nil,
                skippedReason: "postFinalization"
            )
        }
        #endif
        Task { @MainActor in
            defer { token?.group.leave() }
            self.handDetected = detected
            self.handPosition = position
            self.handMotionState = state

            // A task may only mutate the builder if its take is still current.
            let isCurrentTake = token.map { builderAdmissionGate.isCurrent($0.generation) } ?? false
            let builder = self.activeRoutineDetectedNotationBuilder
            if token != nil, isCurrentTake, let builder, self.isRoutineRecording {
                builder.recordObservation(
                    state: state,
                    position: movementPosition,
                    confidence: movementConfidence,
                    now: CACurrentMediaTime(),
                    observationID: observationID
                )
                #if DEBUG
                self.publishRoutineMovementDiagnostics(self.activeRoutineMovementDebugSession?.snapshot())
                #endif
            } else if token != nil {
                #if DEBUG
                // Admitted, but recording stopped/finalized/superseded before this
                // task ran. Recorded here (inside the admitted task, before its
                // `leave()`), so the finalization barrier waits for it.
                if let observationID {
                    let skippedReason = (!isCurrentTake || builder == nil) ? "postFinalization" : "recordingStopped"
                    self.movementTraceRecorder.recordBuilderExecution(
                        index: observationID,
                        executionTime: CACurrentMediaTime(),
                        action: "skipped",
                        rejectionReason: nil,
                        finishedEventIndex: nil,
                        skippedReason: skippedReason
                    )
                }
                #endif
            }
            // token == nil: the postFinalization skip was already recorded
            // synchronously above; nothing more to do here.

            // CXL: record motion stroke on active-direction transitions.
            if self.cxlRecorder.isRecording && stateChanged {
                let wasActive = prevState == .movingLeft || prevState == .movingRight
                let nowActive = state == .movingLeft || state == .movingRight
                _ = cxlPrevDir  // suppress unused warning
                if nowActive || (wasActive && !nowActive) {
                    self.cxlRecorder.recordMotionStroke(
                        detectedDirection: cxlDir,
                        confidence: motionConfidence,
                        signalSource: cxlSrc,
                        handX: position.map { Double($0.x) },
                        handY: position.map { Double($0.y) }
                    )
                    self.publishCXLState()
                }
            }

            // CXL: periodic sample (throttled inside recordSample).
            if self.cxlRecorder.isRecording {
                self.cxlRecorder.recordSample(
                    targetDirection: nil,
                    detectedDirection: cxlDir,
                    handX: position.map { Double($0.x) },
                    handY: position.map { Double($0.y) },
                    motionConfidence: motionConfidence,
                    audioConfidence: self.recentAudioScratchConfidence,
                    signalSource: cxlSrc,
                    timingErrorMs: nil,
                    calibrationLocked: self.calibrationLocked
                )
                self.publishCXLState()
            }
        }
    }

    private func resetPublishedVideoState() {
        handDirectionTracker.reset()
        smoothedHandPoint = nil
        missedHandTrackingFrames = 0
        lastContinuityHandPoint = nil
        lastContinuityHandPointTime = 0
        #if DEBUG
        debugLastRawDirection = .idle
        #endif
        lastPublishedRigLayout = nil
        lastPublishedUsesManualRigGuide = false
        lastPublishedHandDetected = false
        lastPublishedHandPosition = nil
        lastPublishedHandMotionState = .searching
    }

    private func expanded(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        rect.insetBy(dx: -dx, dy: -dy)
    }

    private func applyPerspective(to layout: DJRigLayout?) -> DJRigLayout? {
        guard let layout else { return nil }

        let sortedZones = layout.zones.sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        let shouldUseDJPerspective = useDJPerspective && !isUsingDeskViewCamera
        let orderedRoles: [DJRigZone.Role] = shouldUseDJPerspective
            ? [.rightDeck, .mixer, .leftDeck]
            : [.leftDeck, .mixer, .rightDeck]

        let remappedZones = zip(sortedZones, orderedRoles).map { zone, role in
            DJRigZone(role: role, boundingBox: zone.boundingBox)
        }

        return DJRigLayout(zones: remappedZones, confidence: layout.confidence)
    }

    private func adjustedBoundingBox(_ rect: CGRect) -> CGRect {
        let widthScale = CGFloat(rigWidthScale)
        let heightScale = CGFloat(rigHeightScale)
        let offsetX = CGFloat(rigHorizontalOffset)
        let offsetY = CGFloat(rigVerticalOffset)

        let normalized = CaptureGuideEditModel.normalizedBounds
        let scaledWidth = min(max(rect.width * widthScale, 0.08), normalized.width)
        let scaledHeight = min(max(rect.height * heightScale, 0.08), normalized.height)
        let centerX = rect.midX + offsetX
        let centerY = rect.midY + offsetY

        let proposed = CGRect(
            x: centerX - (scaledWidth / 2),
            y: centerY - (scaledHeight / 2),
            width: scaledWidth,
            height: scaledHeight
        )

        return proposed.intersection(normalized)
    }

    private func adjustedBoundingBox(_ rect: CGRect, using adjustment: ZoneAdjustment) -> CGRect {
        let widthScale = CGFloat(adjustment.widthScale)
        let heightScale = CGFloat(adjustment.heightScale)
        let offsetX = CGFloat(adjustment.offsetX)
        let offsetY = CGFloat(adjustment.offsetY)

        let normalized = CaptureGuideEditModel.normalizedBounds
        let scaledWidth = min(max(rect.width * widthScale, 0.05), normalized.width)
        let scaledHeight = min(max(rect.height * heightScale, 0.05), normalized.height)
        let centerX = rect.midX + offsetX
        let centerY = rect.midY + offsetY

        let minX = max(normalized.minX, min(centerX - (scaledWidth / 2), normalized.maxX - scaledWidth))
        let minY = max(normalized.minY, min(centerY - (scaledHeight / 2), normalized.maxY - scaledHeight))

        return CGRect(x: minX, y: minY, width: scaledWidth, height: scaledHeight)
    }

    private var preferredDesktopDeckCamera: AVCaptureDevice? {
        availableVideoDevices.first(where: isBuiltInMacCamera) ?? availableVideoDevices.first
    }

    private var currentZoneTuning: DJRigZoneTuning {
        let base = isUsingDeskViewCamera ? DJRigZoneTuning.deskView : DJRigZoneTuning.standard
        return base.withMixerShare(CGFloat(mixerWidthRatio))
    }

    private var preferredDeskViewCamera: AVCaptureDevice? {
        if let selectedVideoDevice,
           let companionDeskViewCamera = selectedVideoDevice.companionDeskViewCamera {
            return companionDeskViewCamera
        }

        if let continuityCompanion = availableVideoDevices
            .filter({ !isDeskViewCamera($0) })
            .compactMap(\.companionDeskViewCamera)
            .first {
            return continuityCompanion
        }

        return availableVideoDevices.first(where: isDeskViewCamera)
    }

    private func uniqueVideoDevices(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seenDeviceIDs: Set<String> = []
        var uniqueDevices: [AVCaptureDevice] = []

        for device in devices where seenDeviceIDs.insert(device.uniqueID).inserted {
            uniqueDevices.append(device)
        }

        return uniqueDevices
    }

    private func isDeskViewCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .deskViewCamera || device.localizedName.localizedCaseInsensitiveContains("Desk View")
    }

    private func isBuiltInMacCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInWideAngleCamera || device.localizedName.localizedCaseInsensitiveContains("MacBook")
    }

    private func isPhoneContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera
            || device.modelID.localizedCaseInsensitiveContains("iPhone")
            || device.localizedName.localizedCaseInsensitiveContains("iPhone")
    }

    private func setZoneAdjustment(_ adjustment: ZoneAdjustment, for role: DJRigZone.Role) {
        var updated = zoneAdjustments
        if adjustment.isIdentity {
            updated.removeValue(forKey: role)
        } else {
            updated[role] = adjustment
        }
        zoneAdjustments = updated
    }

    private func clearFixedRigLayout(prioritizeDetection: Bool = false) {
        fixedRigLayout = nil
        fixedRigLayoutUsesManualGuide = false
        if prioritizeDetection {
            rigLayoutDetector.prioritizeNextDetection()
        }
    }

    private static func loadZoneAdjustments() -> [DJRigZone.Role: ZoneAdjustment] {
        guard let data = UserDefaults.standard.data(forKey: ScratchLabDesktopDefaultsKey.zoneAdjustmentsData),
              let storedAdjustments = try? JSONDecoder().decode([StoredZoneAdjustment].self, from: data) else {
            return [:]
        }

        return storedAdjustments.reduce(into: [:]) { partial, stored in
            guard let role = DJRigZone.Role(rawValue: stored.role) else { return }
            partial[role] = ZoneAdjustment(
                offsetX: stored.offsetX,
                offsetY: stored.offsetY,
                widthScale: stored.widthScale,
                heightScale: stored.heightScale
            )
        }
    }

    private static func persistZoneAdjustments(_ zoneAdjustments: [DJRigZone.Role: ZoneAdjustment]) {
        let storedAdjustments = zoneAdjustments.map { role, adjustment in
            StoredZoneAdjustment(
                role: role.rawValue,
                offsetX: adjustment.offsetX,
                offsetY: adjustment.offsetY,
                widthScale: adjustment.widthScale,
                heightScale: adjustment.heightScale
            )
        }.sorted { $0.role < $1.role }

        if let data = try? JSONEncoder().encode(storedAdjustments) {
            UserDefaults.standard.set(data, forKey: ScratchLabDesktopDefaultsKey.zoneAdjustmentsData)
        }
    }

    struct AudioPacket {
        let samples: [Float]
        let sampleRate: Double
    }

    private static let maximumAudioPacketFrameCount = 1_048_576
    private static let maximumAudioPacketChannelCount = 64

    /// Derives the conversion bound from Core Media's frame count and the declared channel
    /// layout. `AudioBuffer.mDataByteSize` is only proof that enough bytes are available; it
    /// must not become the iteration count because inconsistent metadata can otherwise create
    /// an effectively unbounded Range on the realtime capture queue.
    static func validatedAudioSampleCount(
        frameCount: Int,
        bufferChannelCount: Int,
        bytesPerSample: Int,
        availableByteCount: Int
    ) -> Int? {
        guard frameCount > 0,
              frameCount <= maximumAudioPacketFrameCount,
              bufferChannelCount > 0,
              bufferChannelCount <= maximumAudioPacketChannelCount,
              bytesPerSample > 0,
              availableByteCount >= 0 else {
            return nil
        }

        let (sampleCount, sampleCountOverflow) = frameCount.multipliedReportingOverflow(
            by: bufferChannelCount
        )
        guard !sampleCountOverflow else { return nil }

        let (requiredByteCount, requiredByteCountOverflow) = sampleCount.multipliedReportingOverflow(
            by: bytesPerSample
        )
        guard !requiredByteCountOverflow, requiredByteCount <= availableByteCount else { return nil }
        return sampleCount
    }

    static func audioPacket(from sampleBuffer: CMSampleBuffer) -> AudioPacket? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0,
              channelCount <= maximumAudioPacketChannelCount,
              frameCount > 0,
              frameCount <= maximumAudioPacketFrameCount else {
            return nil
        }

        let bytesPerSample: Int
        if isFloat && bitsPerChannel == 32 {
            bytesPerSample = MemoryLayout<Float>.size
        } else if !isFloat && bitsPerChannel == 16 {
            bytesPerSample = MemoryLayout<Int16>.size
        } else if !isFloat && bitsPerChannel == 32 {
            bytesPerSample = MemoryLayout<Int32>.size
        } else {
            return nil
        }

        let maximumBufferCount = isNonInterleaved ? channelCount : 1
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, maximumBufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: max(16, MemoryLayout<AudioBufferList>.alignment)
        )
        defer { rawPointer.deallocate() }
        let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferListPointer.pointee = AudioBufferList(
            mNumberBuffers: UInt32(maximumBufferCount),
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        guard !buffers.isEmpty, buffers.count <= maximumBufferCount else { return nil }
        if isNonInterleaved {
            guard buffers.count == channelCount,
                  buffers.allSatisfy({ $0.mNumberChannels == 1 }) else {
                return nil
            }
        } else {
            guard buffers.count == 1,
                  Int(buffers[0].mNumberChannels) == channelCount else {
                return nil
            }
        }

        var channelSamples: [[Float]] = []
        channelSamples.reserveCapacity(buffers.count)

        for buffer in buffers {
            guard let rawData = buffer.mData,
                  let sampleCount = validatedAudioSampleCount(
                    frameCount: frameCount,
                    bufferChannelCount: Int(buffer.mNumberChannels),
                    bytesPerSample: bytesPerSample,
                    availableByteCount: Int(buffer.mDataByteSize)
                  ) else {
                return nil
            }

            if isFloat && bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                channelSamples.append(Array(UnsafeBufferPointer(start: samples, count: sampleCount)))
            } else if bitsPerChannel == 16 {
                let samples = rawData.assumingMemoryBound(to: Int16.self)
                var converted: [Float] = []
                converted.reserveCapacity(sampleCount)
                for index in 0..<sampleCount {
                    converted.append(Float(samples[index]) / Float(Int16.max))
                }
                channelSamples.append(converted)
            } else if bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Int32.self)
                var converted: [Float] = []
                converted.reserveCapacity(sampleCount)
                for index in 0..<sampleCount {
                    converted.append(Float(samples[index]) / Float(Int32.max))
                }
                channelSamples.append(converted)
            }
        }

        guard !channelSamples.isEmpty else { return nil }

        let monoSamples: [Float]
        if buffers.count == 1 && channelCount > 1 && !isNonInterleaved {
            let interleaved = channelSamples[0]
            let frameCount = interleaved.count / channelCount
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channelIndex in 0..<channelCount {
                    frameSum += interleaved[(frameIndex * channelCount) + channelIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelCount)
            }
            monoSamples = downmixed
        } else if channelSamples.count > 1 {
            let frameCount = channelSamples.map(\.count).min() ?? 0
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channel in channelSamples {
                    frameSum += channel[frameIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelSamples.count)
            }
            monoSamples = downmixed
        } else {
            monoSamples = channelSamples[0]
        }

        return AudioPacket(samples: monoSamples, sampleRate: asbd.mSampleRate)
    }

    private static func level(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return min(max(rms * 10, 0), 1)
    }

    /// Smallest change in `audioLevel` that triggers a new publish.
    /// Below this, the meter is visually identical so we skip the
    /// `@Published` write to avoid needless root-view invalidation.
    private static let audioLevelPublishEpsilon: Float = 0.005

    /// Minimum interval between *forced* no-change publishes.  Keeps the
    /// meter from appearing permanently frozen when the actual level is
    /// perfectly flat.  Resets on every real change.
    private static let audioLevelPublishStaleInterval: CFTimeInterval = 0.50

    @MainActor
    func publishAudioSignalLevel(_ measuredLevel: Float?, receivedAt: CFTimeInterval = CACurrentMediaTime()) {
        lastReceivedAudioSampleTime = receivedAt

        guard let measuredLevel, measuredLevel.isFinite else {
            if !hasPublishedAudioLevel {
                audioLevel = 0
            }
            return
        }

        let sanitizedLevel = min(max(measuredLevel, 0), 1)
        let currentLevel = audioLevel.isFinite ? audioLevel : 0
        let candidateLevel = min(max((currentLevel * 0.55) + (sanitizedLevel * 0.45), 0), 1)

        let wasSilent = currentLevel <= Self.audioLevelPublishEpsilon
        let isSilent  = candidateLevel <= Self.audioLevelPublishEpsilon
        let signalEdgeChanged = wasSilent != isSilent

        let delta = abs(candidateLevel - currentLevel)
        let significantChange = delta >= Self.audioLevelPublishEpsilon

        let stale = receivedAt - lastPublishedAudioLevelTime >= Self.audioLevelPublishStaleInterval

        guard significantChange || signalEdgeChanged || stale else { return }

        lastPublishedAudioLevelTime = receivedAt
        audioLevel = candidateLevel
        hasPublishedAudioLevel = true
    }

    func refreshAudioSignalForCurrentTime(now: CFTimeInterval = CACurrentMediaTime()) {
        guard hasPublishedAudioLevel else { return }
        guard lastReceivedAudioSampleTime > 0,
              now - lastReceivedAudioSampleTime >= audioSignalStaleInterval else { return }
        resetAudioSignalLevel()
    }

    func resetAudioSignalLevel() {
        audioLevel = 0
        hasPublishedAudioLevel = false
        lastReceivedAudioSampleTime = 0
        lastPublishedAudioLevelTime = 0
    }

    private func appendRoutineAudioSampleBufferIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard isRoutineRecording || movieOutput.isRecording,
              let writer = activeRoutineAudioCaptureWriter else { return }
        writer.append(sampleBuffer)
        publishRoutineAudioCaptureDiagnostics(writer.diagnosticsSnapshot())
    }

    private func publishRoutineAudioCaptureDiagnostics(_ snapshot: RoutineAudioCaptureDiagnosticsSnapshot?) {
        Task { @MainActor in
            self.routineAudioBuffersReceived = snapshot?.buffersReceived ?? 0
            self.routineAudioBuffersAppended = snapshot?.buffersAppended ?? 0
            self.routineAudioBuffersSkipped = snapshot?.buffersSkipped ?? 0
            self.lastRoutineAudioWriterError = snapshot?.lastErrorMessage
        }
    }

    #if DEBUG
    private func publishRoutineMovementDiagnostics(_ snapshot: RoutineMovementDiagnosticsSnapshot?) {
        Task { @MainActor in
            self.routineMovementDiagnostics = snapshot
        }
    }

    // MARK: - Rane channel-map diagnostic (Phase 2, DEBUG only)

    /// Begin sampling the live capture device's raw multichannel stream. The
    /// capture session must already be running on the target audio input.
    func startChannelMapDiagnostic() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.channelMapDiagnosticActive = true
            self.channelMapDiagnosticChannels = []
            self.channelMapDiagnosticFrames = 0
            self.channelMapDiagnosticSampleRate = 0
            Task { @MainActor in
                self.isChannelMapDiagnosticRunning = true
                self.channelMapDiagnosticSnapshot = nil
                self.channelMapDiagnosticStatus =
                    "Sampling… play or scratch obvious program audio through the Rane now."
            }
        }
    }

    /// Stop sampling without waiting for the window to fill.
    func stopChannelMapDiagnostic() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let hadSamples = self.channelMapDiagnosticFrames > 0
            self.finishChannelMapDiagnosticLocked(reason: hadSamples ? nil : "No audio reached the diagnostic — check the input selection.")
        }
    }

    /// Called on `audioQueue` for every captured audio buffer while the
    /// diagnostic is active. Accumulates de-interleaved per-channel Float
    /// samples until the target window is filled, then analyses once.
    private func accumulateChannelMapDiagnosticSampleBufferIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard channelMapDiagnosticActive else { return }
        guard let decoded = Self.planarFloatChannels(from: sampleBuffer) else { return }

        if channelMapDiagnosticChannels.isEmpty {
            channelMapDiagnosticChannels = Array(
                repeating: [Float](),
                count: decoded.channels.count
            )
            channelMapDiagnosticSampleRate = decoded.sampleRate
        }
        guard decoded.channels.count == channelMapDiagnosticChannels.count else { return }

        for index in 0..<decoded.channels.count {
            channelMapDiagnosticChannels[index].append(contentsOf: decoded.channels[index])
        }
        channelMapDiagnosticFrames += decoded.channels.first?.count ?? 0

        if channelMapDiagnosticFrames >= channelMapDiagnosticTargetFrames {
            finishChannelMapDiagnosticLocked(reason: nil)
        }
    }

    /// `audioQueue`-isolated. Runs the probe (if any samples) and publishes.
    private func finishChannelMapDiagnosticLocked(reason: String?) {
        guard channelMapDiagnosticActive else { return }
        channelMapDiagnosticActive = false

        let channels = channelMapDiagnosticChannels
        let sampleRate = channelMapDiagnosticSampleRate
        channelMapDiagnosticChannels = []
        channelMapDiagnosticFrames = 0
        channelMapDiagnosticSampleRate = 0

        let snapshot = channels.isEmpty
            ? nil
            : MultichannelSignalProbe.analyze(planarChannels: channels, sampleRate: sampleRate)

        Task { @MainActor in
            self.isChannelMapDiagnosticRunning = false
            self.channelMapDiagnosticSnapshot = snapshot
            if let reason {
                self.channelMapDiagnosticStatus = reason
            } else if let snapshot {
                if let recommended = snapshot.recommendedPair {
                    self.channelMapDiagnosticStatus =
                        "Done. Program audio looks strongest on CH \(recommended.label). Verify against the report, then set it as the program pair."
                } else {
                    self.channelMapDiagnosticStatus =
                        "Done. No pair clearly carries program audio — play louder/obvious audio and re-run."
                }
                NSLog("[MacCaptureEngine] Channel-map diagnostic:\n%@", snapshot.reportText)
            } else {
                self.channelMapDiagnosticStatus = "Stopped before any audio was captured."
            }
        }
    }

    /// De-interleave a captured PCM buffer into one Float array per channel.
    /// Handles Float32 / Int16 / Int32, interleaved or non-interleaved.
    static func planarFloatChannels(
        from sampleBuffer: CMSampleBuffer
    ) -> (channels: [[Float]], sampleRate: Double)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0,
              channelCount <= maximumAudioPacketChannelCount,
              frameCount > 0,
              frameCount <= maximumAudioPacketFrameCount else {
            return nil
        }

        let bytesPerSample: Int
        if isFloat && bitsPerChannel == 32 {
            bytesPerSample = MemoryLayout<Float>.size
        } else if !isFloat && bitsPerChannel == 16 {
            bytesPerSample = MemoryLayout<Int16>.size
        } else if !isFloat && bitsPerChannel == 32 {
            bytesPerSample = MemoryLayout<Int32>.size
        } else {
            return nil
        }

        let bufferCount = isNonInterleaved ? channelCount : 1
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: max(16, MemoryLayout<AudioBufferList>.alignment)
        )
        defer { rawPointer.deallocate() }
        let listPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPointer.pointee = AudioBufferList(
            mNumberBuffers: UInt32(bufferCount),
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        guard !buffers.isEmpty else { return nil }

        func normalize(_ raw: UnsafeRawPointer, sampleIndex: Int) -> Float {
            if isFloat {
                return raw.assumingMemoryBound(to: Float.self)[sampleIndex]
            } else if bitsPerChannel == 16 {
                return Float(raw.assumingMemoryBound(to: Int16.self)[sampleIndex]) / Float(Int16.max)
            } else {
                return Float(raw.assumingMemoryBound(to: Int32.self)[sampleIndex]) / Float(Int32.max)
            }
        }

        var channels = Array(repeating: [Float](), count: channelCount)

        if isNonInterleaved {
            guard buffers.count == channelCount else { return nil }
            for channel in 0..<channelCount {
                guard let data = buffers[channel].mData else { return nil }
                let available = Int(buffers[channel].mDataByteSize) / bytesPerSample
                let count = min(frameCount, available)
                var out = [Float](repeating: 0, count: count)
                for index in 0..<count {
                    out[index] = normalize(data, sampleIndex: index)
                }
                channels[channel] = out
            }
        } else {
            guard buffers.count == 1, let data = buffers[0].mData else { return nil }
            let totalSamples = Int(buffers[0].mDataByteSize) / bytesPerSample
            let frames = min(frameCount, totalSamples / channelCount)
            for channel in 0..<channelCount {
                channels[channel] = [Float](repeating: 0, count: frames)
            }
            for frame in 0..<frames {
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    channels[channel][frame] = normalize(data, sampleIndex: base + channel)
                }
            }
        }

        return (channels, asbd.mSampleRate)
    }
    #endif

    private func startAudioSignalDecayTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(
            deadline: .now() + audioSignalDecayPollInterval,
            repeating: audioSignalDecayPollInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshAudioSignalForCurrentTime()
            }
        }
        audioSignalDecayTimer = timer
        timer.resume()
    }

    /// Polls the sample-playback controller's read position at ~25 Hz and
    /// hops a snapshot to the MainActor for the live read-position track.
    /// The controller's `currentPlaybackPositionSnapshot()` does its own
    /// `audioQueue.sync` read; this timer runs off that queue, so no
    /// deadlock. Idempotent.
    private func startPlaybackPositionPoll() {
        guard playbackPositionPollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        timer.schedule(
            deadline: .now(),
            repeating: Self.playbackPositionPollInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.scratchPlaybackController.currentPlaybackPositionSnapshot()
            let waveform = self.scratchPlaybackController.currentPlaybackWaveformSnapshot()
            Task { @MainActor in
                self.playbackPositionSnapshot = snapshot
                if self.playbackWaveformSnapshot != waveform {
                    self.playbackWaveformSnapshot = waveform
                }
            }
        }
        playbackPositionPollTimer = timer
        timer.resume()
    }

    // MARK: - MIDI Learn (Extended)

    /// Start learning a specific semantic action from incoming MIDI events.
    /// Replaces the legacy crossfader-only `startMIDILearn()`.
    func startMIDILearn(for action: MIDISemanticAction) {
        midiCaptureLock.lock()
        let calibrating = isCalibrating
        let curveCapturing = isCurveCapturing
        midiCaptureLock.unlock()
        // Learning, calibration, and curve capture must never run at the
        // same time — a fresh learn request always wins and abandons any
        // in-progress calibration or curve-capture session.
        if calibrating { cancelCalibration() }
        if curveCapturing { cancelCurveCalibration() }

        midiCaptureLock.lock()
        learnSessionAction = action
        midiLearnRequestID &+= 1
        let learnRequestID = midiLearnRequestID
        let eventCountAtStart = midiEventsReceivedCount
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "midiLearn") { [weak self] in
            guard let self else { return }
            self.activeMIDILearnAction = action
            // Drop any value carried over from a previous Learn session so the
            // panel shows "move the control now" until a fresh event lands.
            if self.midiLearnObservedRawValue != nil { self.midiLearnObservedRawValue = nil }
            // Crossfader keeps the original `.listening` state/feedback text so the
            // pre-existing crossfader-only UI and tests continue to see the same
            // behaviour as before multi-action learn was added.
            if action == .crossfader {
                if self.midiLearnState != .listening { self.midiLearnState = .listening }
                if self.midiLearnFeedback != "Listening..." { self.midiLearnFeedback = "Listening..." }
            } else {
                let nextState = MIDILearnState.listeningFor(action)
                if self.midiLearnState != nextState { self.midiLearnState = nextState }
                let fb = "Learn \(action.displayName): move the control now…"
                if self.midiLearnFeedback != fb { self.midiLearnFeedback = fb }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self else { return }
            let shouldWarn = self.midiCaptureLock.withLock {
                self.learnSessionAction != nil
                    && self.midiLearnRequestID == learnRequestID
                    && self.midiEventsReceivedCount == eventCountAtStart
            }
            guard shouldWarn else { return }
            let warning = action == .crossfader
                ? "No MIDI received. Check IAC Driver / MixEmergency MIDI Out."
                : "No MIDI received. Check your controller is connected and sending MIDI."
            self.publishOnMainAsync(field: "midiLearnFeedback") { [weak self] in
                guard let self, self.midiLearnFeedback != warning else { return }
                self.midiLearnFeedback = warning
            }
        }
    }

    /// Backward-compatible start — starts legacy crossfader-only learn.
    func startMIDILearn() {
        startMIDILearn(for: .crossfader)
    }

    /// Loads the validated right-deck platter sample
    /// one-revolution `dvs_ahhh` asset (`VirtualPlatter/ahhh.wav`,
    /// ~1.0474 s) with no automatic preview/playback — only loads it into
    /// `scratchPlaybackController`. Moving the right platter (channel 1
    /// CC6) is what produces audio, through the same direct-MIDI
    /// continuous drive DVS's renderer uses.
    ///
    /// Deliberately hardcoded, not parameterized: the hot-cue pad asset
    /// `ahhh.wav` (~4.4667 s) is longer than one physical platter
    /// revolution (`dvsLoopFrames`, ~1.8 s) and is rejected by
    /// `midiCoalescingTick`'s loop-fit guard — this button must always
    /// load the short, validated asset. Supporting longer samples on the
    /// direct-MIDI path is out of scope here (hot-cue/sample-mapping
    /// design, later).
    func loadPlatterTestSample() {
        guard allowsLocalScratchPlayback else {
            publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
                self?.platterTestLoadStatus = "ScratchLab audio is unavailable."
            }
            return
        }
        let sampleID = "dvs_ahhh"
        print("[ScratchSamplePlaybackBridge] platter test load requested · sampleID=\(sampleID)")
        let requested = scratchPlaybackController.load(sampleID: sampleID, playDiagnosticPreview: false)
        guard requested else {
            publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
                self?.platterTestLoadStatus = "not found: \(sampleID)"
            }
            return
        }
        // Bounded: `load` only queues a small bundled-WAV read on the
        // controller's own audio queue; draining it here from the explicit
        // main-thread button action lets the status reflect the real
        // outcome instead of just "a request was queued".
        scratchPlaybackController.waitForAudioQueue()
        let snapshot = scratchPlaybackController.diagnosticsSnapshot()
        publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
            guard let self else { return }
            if snapshot.loadedSampleID == sampleID {
                self.platterTestLoadStatus = "loaded: \(sampleID)"
            } else {
                self.platterTestLoadStatus = "load failed: \(snapshot.lastLoadError ?? "unknown")"
            }
        }
    }

    /// Plays the controller's bounded audible diagnostic using the exact
    /// bundled `dvs_ahhh` asset, then leaves that sample armed for right-deck
    /// platter movement. This is deliberately separate from
    /// `loadPlatterTestSample()`: applying a MIDI mapping must remain silent,
    /// while an explicit Test action must prove the real sample and macOS
    /// output chain are audible. Unloading first resets the controller's
    /// once-per-load preview guard, so every button press is a real test.
    func previewPlatterTestSample() {
        guard allowsLocalScratchPlayback else {
            publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
                self?.platterTestLoadStatus = "ScratchLab audio is unavailable."
            }
            return
        }
        let sampleID = "dvs_ahhh"
        print("[ScratchSamplePlaybackBridge] audible platter test requested · sampleID=\(sampleID)")
        scratchPlaybackController.unload()
        scratchPlaybackController.waitForAudioQueue()

        let requested = scratchPlaybackController.load(sampleID: sampleID, playDiagnosticPreview: true)
        guard requested else {
            publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
                self?.platterTestLoadStatus = "not found: \(sampleID)"
            }
            return
        }

        scratchPlaybackController.waitForAudioQueue()
        let snapshot = scratchPlaybackController.diagnosticsSnapshot()
        publishOnMainAsync(field: "platterTestLoadStatus") { [weak self] in
            guard let self else { return }
            if snapshot.loadedSampleID == sampleID, snapshot.engineRunning {
                self.platterTestLoadStatus = "audible test: \(sampleID)"
            } else {
                self.platterTestLoadStatus = "test failed: \(snapshot.lastLoadError ?? "audio engine unavailable")"
            }
        }
    }

    private func publishOnMainAsync(field: String, _ update: @escaping () -> Void) {
        let requestTime = CACurrentMediaTime()
        let requestThread = Thread.isMainThread ? "main" : "background"
        print("[SwiftUIStateGuard] publish request · field=\(field) thread=\(requestThread) time=\(String(format: "%.6f", requestTime))")

        DispatchQueue.main.async { [weak self] in
            if let self {
                let now = CACurrentMediaTime()
                if now - self.lastSwiftUIStateGuardLogTime >= self.swiftUIStateGuardLogInterval {
                    self.lastSwiftUIStateGuardLogTime = now
                    print("[SwiftUIStateGuard] async publish · field=\(field)")
                }
            }
            update()
        }
    }

    func cancelMIDILearn() {
        midiCaptureLock.lock()
        learnSessionAction = nil
        midiLearnRequestID &+= 1
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "midiLearn") { [weak self] in
            guard let self else { return }
            self.activeMIDILearnAction = nil
            if self.midiLearnObservedRawValue != nil { self.midiLearnObservedRawValue = nil }
            let nextState: MIDILearnState = self.crossfaderCCMapping.map { .learned($0) } ?? .idle
            if self.midiLearnState != nextState { self.midiLearnState = nextState }
            if self.midiLearnFeedback != "" { self.midiLearnFeedback = "" }
        }
    }

    /// Publishes the raw value of the event a Learn session actually consumed
    /// (CC value, or note number for a pad). `startMIDILearn(for:)` and
    /// `cancelMIDILearn()` clear it back to `nil` so the Learn panel never
    /// shows a stale pre-Learn value.
    private func publishMIDILearnObservedValue(_ value: Int?) {
        publishOnMainAsync(field: "midiLearnObservedRawValue") { [weak self] in
            guard let self, self.midiLearnObservedRawValue != value else { return }
            self.midiLearnObservedRawValue = value
        }
    }

    var canApplyVerifiedRaneOneMKIIMapping: Bool {
        !selectedMIDIInputSourceID.isEmpty
            && RaneOneMKIIVerifiedLearnedMapping.matches(deviceName: selectedMIDIInputSourceName)
    }

    /// Installs the already-verified Rane ONE MKII mixer and right-deck pad
    /// addresses into the selected device's learned mapping. This does not
    /// alter platter decoding, captured MIDI events, notation, or DVS.
    func applyVerifiedRaneOneMKIIMapping() {
        installVerifiedRaneOneMKIIMapping(overwriteExisting: true, reportsSuccess: true)
    }

    /// Applies the verified mixer/pad addresses and arms the existing
    /// right-deck platter renderer with the validated AHHH sample.
    func applyVerifiedRaneOneMKIIMappingAndLoadAhhh() {
        applyVerifiedRaneOneMKIIMapping()
        loadPlatterTestSample()
    }

    private func seedVerifiedRaneOneMKIIMappingIfNeeded(
        existingMapping: MIDIDeviceMapping?
    ) {
        guard canApplyVerifiedRaneOneMKIIMapping,
              !RaneOneMKIIVerifiedLearnedMapping.isComplete(existingMapping)
        else { return }
        installVerifiedRaneOneMKIIMapping(overwriteExisting: false, reportsSuccess: true)
    }

    private func installVerifiedRaneOneMKIIMapping(
        overwriteExisting: Bool,
        reportsSuccess: Bool
    ) {
        guard canApplyVerifiedRaneOneMKIIMapping else {
            publishOnMainAsync(field: "midiMappingError") { [weak self] in
                self?.midiMappingError = "Select the Rane ONE MKII MIDI source before applying its verified mapping."
            }
            return
        }

        midiCaptureLock.lock()
        learnSessionAction = nil
        midiLearnRequestID &+= 1
        midiCaptureLock.unlock()

        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            RaneOneMKIIVerifiedLearnedMapping.apply(
                to: &mapping,
                overwriteExisting: overwriteExisting
            )
        }, completion: { [weak self] mapping in
            guard let self, self.selectedMIDIInputSourceID == deviceID else { return }
            self.currentMIDIDeviceMapping = mapping
            self.midiMappingError = ""
            self.activeMIDILearnAction = nil

            if let crossfader = mapping.control(for: .crossfader) {
                let legacy = CrossfaderCCMapping(
                    channel: crossfader.channel,
                    controller: crossfader.controlNumber
                )
                self.applyLearnedCrossfaderMapping(legacy)
                self.crossfaderCCMapping = legacy
                self.midiLearnState = .learned(legacy)
            }
            if let crossfader = mapping.control(for: .crossfader) {
                self.pushResolvedCurve(for: crossfader)
            }
            if let rightUpfader = mapping.control(for: .rightUpfader) {
                self.pushResolvedCurve(for: rightUpfader)
            }
            if reportsSuccess {
                self.midiLearnFeedback = "Applied verified Rane ONE MKII mapping: faders and right-deck hot cues."
            }
        })
    }

    func clearCrossfaderMapping() {
        midiCaptureLock.lock()
        persistedCrossfaderMapping = nil
        learnSessionAction = nil
        midiLearnRequestID &+= 1
        midiCaptureLock.unlock()
        midiPersistenceDefaults.removeObject(forKey: ScratchLabDesktopDefaultsKey.crossfaderMIDIMapping)
        publishOnMainAsync(field: "midiLearn") { [weak self] in
            guard let self else { return }
            self.activeMIDILearnAction = nil
            self.crossfaderCCMapping = nil
            if self.midiLearnState != .idle { self.midiLearnState = .idle }
            if self.midiLearnFeedback != "" { self.midiLearnFeedback = "" }
        }
    }

    /// Legacy-compatibility adapter, NOT the authoritative UI-state
    /// publisher: writes the standalone pre-generalized-learn crossfader
    /// store (`persistedCrossfaderMapping` + the single-key
    /// `crossfaderMIDIMapping` UserDefaults entry) that launch-restore
    /// (`init`, `startDeviceDiscoveryAfterViewMount`) and
    /// `recordReceivedMIDICCEvent`'s mapped-control detection still read.
    /// Called at most once per learn session — the caller
    /// (`evaluateMIDILearnForCC`) has already atomically claimed and ended
    /// the session before calling this, so no session-state mutation
    /// happens here.
    ///
    /// Does NOT touch `crossfaderCCMapping`, `midiLearnState`, or
    /// `midiLearnFeedback` — `applyLearnedMapping`'s completion (run via
    /// `mutateDeviceMapping` on the same serial persistence queue) is the
    /// single authoritative publisher of those for every learned action,
    /// crossfader included. Publishing them here too raced that
    /// completion: `mutateDeviceMapping` round-trips through
    /// `midiMappingPersistenceQueue` before reaching main, so this
    /// function's now-removed direct `publishOnMainAsync` used to land on
    /// main *first* despite being called *second*, only for the delayed
    /// generic completion to overwrite it back to `.idle` moments later.
    private func applyLearnedCrossfaderMapping(_ mapping: CrossfaderCCMapping) {
        midiCaptureLock.lock()
        persistedCrossfaderMapping = mapping
        midiCaptureLock.unlock()
        midiMappingPersistenceQueue.async {
            if let data = try? JSONEncoder().encode(mapping) {
                self.midiPersistenceDefaults.set(data, forKey: ScratchLabDesktopDefaultsKey.crossfaderMIDIMapping)
            }
        }
    }

    // MARK: - Persistence Queue Helpers

    /// Enqueues a read-modify-write mutation of `deviceID`'s learned mapping on
    /// `midiMappingPersistenceQueue`. The load, `transform`, and save all run on
    /// that queue — never on the CoreMIDI callback or main — then `completion`
    /// is dispatched to main with the resulting mapping. Safe to call from the
    /// CoreMIDI callback: only captures value-type arguments and enqueues a
    /// block; performs no I/O itself.
    ///
    /// Because the queue is serial, calling this repeatedly in quick succession
    /// (even from different threads) always applies the mutations in the exact
    /// order they were enqueued — each one loads the result of the previous one,
    /// so a later mutation can never be overwritten by an earlier, still-in-flight
    /// write that captured a stale snapshot.
    private func mutateDeviceMapping(
        deviceID: String,
        deviceName: String,
        transform: @escaping (inout MIDIDeviceMapping) -> Void,
        completion: @escaping (MIDIDeviceMapping) -> Void
    ) {
        midiMappingPersistenceQueue.async { [weak self] in
            guard let self else { return }
            var mapping = self.midiMappingStore.load(deviceIdentifier: deviceID)
                ?? MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: deviceName)
            mapping.deviceName = deviceName  // refresh name in case device renamed
            transform(&mapping)
            self.midiMappingStore.save(mapping)
            DispatchQueue.main.async {
                completion(mapping)
            }
        }
    }

    /// Enqueues removal of a single action's mapping for `deviceID`, on the same
    /// serial queue as `mutateDeviceMapping` so ordering against in-flight writes
    /// is preserved. If no mappings remain afterward, the device's file is
    /// deleted entirely. `completion` receives the resulting mapping, or nil if
    /// the device now has no mappings (or never had any).
    private func enqueueRemoveAction(
        deviceID: String,
        action: MIDISemanticAction,
        completion: @escaping (MIDIDeviceMapping?) -> Void
    ) {
        midiMappingPersistenceQueue.async { [weak self] in
            guard let self else { return }
            guard var mapping = self.midiMappingStore.load(deviceIdentifier: deviceID) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            mapping.remove(action: action)
            if mapping.isEmpty {
                self.midiMappingStore.delete(deviceIdentifier: deviceID)
                DispatchQueue.main.async { completion(nil) }
            } else {
                self.midiMappingStore.save(mapping)
                DispatchQueue.main.async { completion(mapping) }
            }
        }
    }

    /// Enqueues deletion of ALL learned mappings for `deviceID`, on the same
    /// serial queue as the other mutation helpers.
    private func enqueueDeleteDevice(deviceID: String, completion: @escaping () -> Void) {
        midiMappingPersistenceQueue.async { [weak self] in
            self?.midiMappingStore.delete(deviceIdentifier: deviceID)
            DispatchQueue.main.async { completion() }
        }
    }

    /// Test-only: blocks until every mutation enqueued on
    /// `midiMappingPersistenceQueue` so far has completed its file I/O (the
    /// main-thread `completion` callback may still be pending one more run-loop
    /// turn after this returns — tests should follow with a brief `RunLoop.main.run`).
    func testOnly_waitForMappingPersistenceQueue() {
        midiMappingPersistenceQueue.sync {}
    }

    /// Test-only: counts how many times the coalesced MIDI-monitor publish
    /// block in `recordReceivedMIDICCEvent` has actually executed on main
    /// (not just been enqueued) — used to assert the flood-safety bound.
    private(set) var testOnly_midiMonitorPublishCount = 0

    /// Test-only: counts how many times the coalesced calibration-observed
    /// publish block in `evaluateCalibrationForCC` has actually executed on
    /// main (including stale-generation runs that bailed out without
    /// applying values) — used to assert the flood-safety bound.
    private(set) var testOnly_calibrationObservedPublishCount = 0

    // MARK: - New Multi-Action MIDI Learn Methods (Phase 3)

    /// Apply a learned mapping for any semantic action (crossfader, upfader, hot cue).
    /// Persists per-device via `MIDILearnedMappingStore`.
    /// Called at most once per learn session — the caller
    /// (`evaluateMIDILearnForCC` / `learnHotCueFromNote`) has already
    /// atomically claimed and ended the session before calling this, so no
    /// session-state mutation happens here. The mapping load/merge/save
    /// (file I/O + JSON) runs on `midiMappingPersistenceQueue`, never on the
    /// CoreMIDI callback or main, and all `@Published` UI-state writes happen
    /// only in the main-dispatched completion.
    /// Resolves `control`'s curve config against itself and pushes it to
    /// the playback controller, atomically resetting that control's gain
    /// contribution to unity in the same step (see
    /// `ScratchSamplePlaybackController.applyCrossfaderCurve`/
    /// `applyRightUpfaderCurve`). The controller never sees a
    /// `MIDIFaderCurveConfig` or performs any resolution itself — this is
    /// the single choke point where the persisted mapping (source of
    /// truth) is turned into the resolved runtime value the audio queue
    /// needs. A no-op for `.leftUpfader` and hot-cue actions: no audio
    /// call site consumes their curve in this branch.
    ///
    /// Must be called from every engine-side mutation that can change what
    /// curve applies to `.crossfader`/`.rightUpfader` — a fresh learn, a
    /// min/max recalibration, an inversion flip, a device switch/load, an
    /// explicit preset change, or a finished custom capture. Recalibration
    /// and inversion need this too (not just explicit curve edits):
    /// `resolvedResponse(for:)` re-derives a custom capture through the
    /// control's CURRENT min/max/inversion on every call, so the
    /// controller's cached resolved value goes stale the moment either
    /// changes unless it is re-pushed here. For the default (non-custom)
    /// curve this push resolves to the exact same fixed constants every
    /// time, so it is behaviorally invisible for any mapping that hasn't
    /// configured a custom curve.
    private func pushResolvedCurve(for control: MIDILearnedControl) {
        // Switch on the action FIRST — curve resolution is only ever
        // computed for the two actions that actually consume it. Hot cues
        // and `.unassigned` never reach `resolvedResponse(for:)` from
        // here at all (that function is also independently guarded
        // against them — see its own doc comment — but there is no reason
        // to compute a value this call site immediately discards).
        switch control.action {
        case .crossfader:
            scratchPlaybackController.applyCrossfaderCurve(control.resolvedCurveConfig.resolvedResponse(for: control))
        case .rightUpfader:
            scratchPlaybackController.applyRightUpfaderCurve(control.resolvedCurveConfig.resolvedResponse(for: control))
        default:
            break
        }
    }

    private func applyLearnedMapping(_ control: MIDILearnedControl) {
        let action = control.action
        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            mapping.upsert(control)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            self.midiMappingError = ""
            self.activeMIDILearnAction = nil
            // Single authoritative state transition for every learned
            // action. Crossfader keeps its original `.learned(mapping)`
            // state and "Learned Xfader: ..." wording — the pre-existing
            // crossfader-only UI, `midiCrossfaderMappingStatus`, and the
            // `473c3a3` regression test all key off that exact shape —
            // rather than the generic `.idle` this closure uses for every
            // other action. `applyLearnedCrossfaderMapping` (called just
            // before this by `evaluateMIDILearnForCC`, synchronously for
            // its legacy-persistence side effects) no longer publishes UI
            // state itself, so there is exactly one publish here.
            if action == .crossfader {
                let crossfaderMapping = CrossfaderCCMapping(channel: control.channel, controller: control.controlNumber)
                self.crossfaderCCMapping = crossfaderMapping
                let nextState = MIDILearnState.learned(crossfaderMapping)
                let nextFeedback = "Learned Xfader: \(crossfaderMapping.displayName)"
                if self.midiLearnState != nextState { self.midiLearnState = nextState }
                if self.midiLearnFeedback != nextFeedback { self.midiLearnFeedback = nextFeedback }
            } else {
                self.midiLearnState = .idle
                let fb = "Learned \(action.displayName): \(control.displayName)"
                if self.midiLearnFeedback != fb { self.midiLearnFeedback = fb }
            }
            // A fresh or replaced binding changes what CC (or none at all,
            // until now) drives this control — its old value (if any) is
            // not meaningful under the new binding, so resolve+push its
            // (freshly-learned, curveConfig == nil -> default) curve,
            // which also resets gain to unity until the newly mapped CC
            // actually sends a value.
            self.pushResolvedCurve(for: control)
        })
    }

    /// Atomically claims and ends the active hot-cue learn session (if any)
    /// under a single lock acquisition — at most one Note On event can ever
    /// win a given session, even under a burst of near-simultaneous presses —
    /// then learns the given Note On as that action's binding.
    ///
    /// - Returns: true if a hot-cue learn session was actually claimed by
    ///   this event (callers must not also resolve it as a production press).
    @discardableResult
    private func learnHotCueFromNote(channel: Int, noteNumber: Int) -> Bool {
        midiCaptureLock.lock()
        let claimedAction: MIDISemanticAction?
        if let action = learnSessionAction, action.hotCueIndex != nil {
            learnSessionAction = nil
            midiLearnRequestID &+= 1
            claimedAction = action
        } else {
            claimedAction = nil
        }
        midiCaptureLock.unlock()
        guard let action = claimedAction else { return false }

        // First real event from the pad being learned — surface its note
        // number to the Learn panel.
        publishMIDILearnObservedValue(noteNumber)

        let learned = MIDILearnedControl(
            action: action,
            messageType: .note,
            channel: channel,
            controlNumber: noteNumber,
            deck: nil,
            minValue: 0,
            maxValue: 127,
            inverted: false,
            learnedAt: Date(),
            isVerified: true,
            curveConfig: nil   // hot-cue action: curve never applies
        )
        applyLearnedMapping(learned)
        return true
    }

    /// Lock-protected, CoreMIDI-thread-safe read-only check: is a hot-cue
    /// learn session currently active? Does not claim or end the session —
    /// used only to decide whether to route a Note On event at all.
    private func isHotCueLearnSessionActive() -> Bool {
        midiCaptureLock.lock()
        defer { midiCaptureLock.unlock() }
        return learnSessionAction?.hotCueIndex != nil
    }

    /// Evaluates whether an active MIDI Learn session should consume this
    /// Control Change event (fader or hot-cue-via-CC learn), applying and
    /// persisting the mapping if so.
    ///
    /// The platter's CC6 flood (~800 Hz) is excluded before the lock is even
    /// touched — CC6 can never end or steal a Learn session. Every other
    /// controller number remains learnable (CC8, the Rane ONE MKII
    /// crossfader, included) — filtering is action-aware, not a blanket
    /// controller-number ban.
    ///
    /// Consumption is atomic: the active session is claimed-and-ended under a
    /// single lock acquisition, so at most one event can ever win it, even
    /// under a flood of near-simultaneous events.
    ///
    /// Called from the real CoreMIDI packet-parsing loop for every incoming
    /// CC message (except CC6-filtered ones); also callable directly from
    /// tests as a seam, since `receiveMIDIPacketList` itself is private and
    /// operates on raw `MIDIPacketList` bytes.
    func evaluateMIDILearnForCC(channel: Int, controller: Int, value: Int) -> MIDILearnCCConsumeResult {
        guard controller != 6 else {
            return MIDILearnCCConsumeResult(consumedByLearn: false, crossfaderMapping: nil)
        }

        // A Learn session must consume a genuinely new event from the control
        // being learned, not a stale one from another. When learning a
        // continuous control, ignore a CC whose (channel, controller) is
        // already mapped to a *different* continuous action — that is the
        // previously-touched control (typically the crossfader) still
        // streaming as Learn begins, and it must not instantly claim the
        // session. Hot-cue-via-CC learn is unaffected (a pad is not a
        // continuous stream). The session stays open for the real control.
        midiCaptureLock.lock()
        let pendingAction = learnSessionAction
        midiCaptureLock.unlock()
        if let pendingAction,
           pendingAction.hotCueIndex == nil,
           currentMIDIDeviceMapping?.controls.contains(where: {
               $0.messageType == .controlChange
                   && $0.channel == channel
                   && $0.controlNumber == controller
                   && $0.action != pendingAction
                   && $0.action.hotCueIndex == nil
           }) == true {
            return MIDILearnCCConsumeResult(consumedByLearn: false, crossfaderMapping: nil)
        }

        midiCaptureLock.lock()
        let claimedAction = learnSessionAction
        if claimedAction != nil {
            learnSessionAction = nil
            midiLearnRequestID &+= 1
        }
        midiCaptureLock.unlock()

        guard let learnAction = claimedAction else {
            return MIDILearnCCConsumeResult(consumedByLearn: false, crossfaderMapping: nil)
        }

        // First real event from the control being learned — surface its raw
        // value to the Learn panel (which otherwise has nothing to show but
        // the pre-Learn value).
        publishMIDILearnObservedValue(value)

        let deck: Int?
        switch learnAction {
        case .leftUpfader:  deck = 0
        case .rightUpfader: deck = 1
        default:            deck = nil
        }
        let learned = MIDILearnedControl(
            action: learnAction,
            messageType: .controlChange,
            channel: channel,
            controlNumber: controller,
            deck: deck,
            minValue: 0,
            maxValue: 127,
            inverted: false,
            learnedAt: Date(),
            isVerified: true,
            curveConfig: nil   // fresh binding: any curve customized for a PREVIOUS binding on this action must not carry over
        )
        applyLearnedMapping(learned)

        guard learnAction == .crossfader else {
            return MIDILearnCCConsumeResult(consumedByLearn: true, crossfaderMapping: nil)
        }
        // Also apply legacy crossfader mapping for backward compat.
        let crossfaderMapping = CrossfaderCCMapping(channel: channel, controller: controller)
        applyLearnedCrossfaderMapping(crossfaderMapping)
        return MIDILearnCCConsumeResult(consumedByLearn: true, crossfaderMapping: crossfaderMapping)
    }

    // MARK: - Continuous Control Calibration

    /// Begin a calibration session for an already-learned continuous action
    /// (crossfader, left/right upfader). No-op for hot-cue actions. Refuses to
    /// start while a MIDI Learn session or another calibration is active, or
    /// before the action has been learned at all — there is no binding to
    /// calibrate yet.
    func startCalibration(for action: MIDISemanticAction) {
        guard action.hotCueIndex == nil else { return }
        midiCaptureLock.lock()
        let learning = learnSessionAction != nil
        let alreadyCalibrating = isCalibrating
        let alreadyCurveCapturing = isCurveCapturing
        midiCaptureLock.unlock()
        guard !learning, !alreadyCalibrating, !alreadyCurveCapturing else { return }
        guard currentMIDIDeviceMapping?.control(for: action) != nil else {
            publishOnMainAsync(field: "calibrationError") { [weak self] in
                self?.calibrationError = "Learn \(action.displayName) before calibrating it."
            }
            return
        }
        midiCaptureLock.lock()
        isCalibrating = true
        calibratingAction = action
        calibrationMinAccumulator = 0
        calibrationMaxAccumulator = 0
        calibrationSawAnyEvent = false
        calibrationGeneration &+= 1
        isCalibrationObservedPublishPending = false
        // A fresh session's first live value must not be gated by leftover
        // throttle timing from a just-cancelled/finished session.
        lastCalibrationObservedPublishTime = 0
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "calibration") { [weak self] in
            guard let self else { return }
            self.activeCalibrationAction = action
            self.calibrationObservedMin = nil
            self.calibrationObservedMax = nil
            self.calibrationError = ""
        }
    }

    /// Cancel the active calibration session without persisting anything — the
    /// control's existing min/max/inversion (if any) are left untouched.
    func cancelCalibration() {
        midiCaptureLock.lock()
        isCalibrating = false
        calibratingAction = nil
        calibrationGeneration &+= 1
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "calibration") { [weak self] in
            guard let self else { return }
            self.activeCalibrationAction = nil
            self.calibrationObservedMin = nil
            self.calibrationObservedMax = nil
        }
    }

    // MARK: - Fader Curve Configuration
    //
    // Preset selection and custom "Set closed" / "Set full-on" capture.
    // Layered entirely on top of the existing learn/calibration machinery:
    // never touches a control's binding, min/max, or inversion. See
    // `pushResolvedCurve(for:)` above for how a change here reaches the
    // playback controller.

    /// Sets (and immediately persists) a non-custom preset for an
    /// already-learned continuous action. `.custom` is deliberately
    /// rejected here — selecting Custom must go through
    /// `startCurveCalibration`/`finishCurveCalibration` instead, so an
    /// incomplete custom configuration can never be persisted. Cancels any
    /// in-progress capture session for this action first (the user chose a
    /// complete preset instead of finishing the pending capture).
    func setCurvePreset(_ preset: FaderCurvePreset, for action: MIDISemanticAction) {
        guard preset != .custom else { return }
        guard action.hotCueIndex == nil else { return }
        guard FaderCurvePreset.availablePresets(for: action).contains(preset) else { return }

        midiCaptureLock.lock()
        let shouldCancelCurveCapture = isCurveCapturing && curveCaptureAction == action
        midiCaptureLock.unlock()
        if shouldCancelCurveCapture { cancelCurveCalibration() }

        guard let existingBeforeChange = currentMIDIDeviceMapping?.control(for: action) else { return }
        // Cheap pre-check (mirrors `setInversion`): selecting the preset
        // that's ALREADY effectively applied — whether explicitly
        // persisted or resolved from a nil `curveConfig`'s default — must
        // be a true no-op. Bailing out here, before ever enqueuing a
        // mutation, guarantees no write, no controller push, and no gain
        // reset happen (Defect 3) — not just that the eventual write is
        // skipped while the completion still acts as if something changed.
        guard existingBeforeChange.resolvedCurveConfig.preset != preset else { return }

        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            // Derive from the in-queue mapping — see `finishCalibration`.
            guard let existing = mapping.control(for: action) else { return }
            let newConfig = MIDIFaderCurveConfig(preset: preset, customCapture: nil)
            guard existing.curveConfig != newConfig else { return }
            let updated = MIDILearnedControl(
                action: existing.action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: existing.minValue,
                maxValue: existing.maxValue,
                inverted: existing.inverted,
                assignedSampleID: existing.assignedSampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: newConfig
            )
            mapping.upsert(updated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            if let control = mapping.control(for: action) {
                self.pushResolvedCurve(for: control)
            }
        })
    }

    /// Resets an action's curve to its migration-safe default (Sharp
    /// Scratch for the crossfader, Linear for upfaders), discarding any
    /// custom capture. A separate, explicit action from Cancel — unlike
    /// Cancel, this DOES persist immediately. Cancels any in-progress
    /// capture session for this action first.
    func resetCurve(for action: MIDISemanticAction) {
        guard action.hotCueIndex == nil else { return }
        midiCaptureLock.lock()
        let shouldCancelCurveCapture = isCurveCapturing && curveCaptureAction == action
        midiCaptureLock.unlock()
        if shouldCancelCurveCapture { cancelCurveCalibration() }

        guard let existingBeforeChange = currentMIDIDeviceMapping?.control(for: action) else { return }
        // Same true-no-op discipline as `setCurvePreset` (Defect 3's
        // class of bug applies here identically): resetting a curve
        // that's already at its default must not push/reset anything.
        guard existingBeforeChange.curveConfig != nil else { return }

        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            guard let existing = mapping.control(for: action), existing.curveConfig != nil else { return }
            let updated = MIDILearnedControl(
                action: existing.action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: existing.minValue,
                maxValue: existing.maxValue,
                inverted: existing.inverted,
                assignedSampleID: existing.assignedSampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: nil   // nil resolves to the action's default
            )
            mapping.upsert(updated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            if let control = mapping.control(for: action) {
                self.pushResolvedCurve(for: control)
            }
        })
    }

    /// Begins a pending custom-curve capture session for an already-learned
    /// continuous action. Deliberately does NOT change what curve is
    /// currently applied — the existing persisted preset/curve (if any)
    /// remains active, both in the saved mapping and in the controller,
    /// until `finishCurveCalibration()` succeeds. Mutually exclusive with
    /// MIDI Learn and min/max calibration (same lock-protected guard
    /// pattern as `startCalibration`). Freezes the device and exact
    /// binding identity the session watches — see `CurveCaptureBindingIdentity`.
    func startCurveCalibration(for action: MIDISemanticAction) {
        guard action.hotCueIndex == nil else { return }
        midiCaptureLock.lock()
        let learning = learnSessionAction != nil
        let calibrating = isCalibrating
        let alreadyCapturing = isCurveCapturing
        midiCaptureLock.unlock()
        guard !learning, !calibrating, !alreadyCapturing else { return }
        guard let existingControl = currentMIDIDeviceMapping?.control(for: action) else {
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Learn \(action.displayName) before setting a custom curve."
            }
            return
        }
        let deviceID = selectedMIDIInputSourceID
        let binding = CurveCaptureBindingIdentity(
            messageType: existingControl.messageType,
            channel: existingControl.channel,
            controlNumber: existingControl.controlNumber
        )
        midiCaptureLock.lock()
        isCurveCapturing = true
        curveCaptureAction = action
        curveCaptureDeviceID = deviceID
        curveCaptureBindingIdentity = binding
        curveCaptureLastRawValue = nil
        curveCapturePendingClosedRawValue = nil
        curveCapturePendingFullOnRawValue = nil
        curveCaptureGeneration &+= 1
        isCurveCapturePublishPending = false
        lastCurveCapturePublishTime = 0
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "curveCapture") { [weak self] in
            guard let self else { return }
            self.activeCurveCaptureAction = action
            self.curveCaptureHasClosedPoint = false
            self.curveCaptureHasFullOnPoint = false
            self.curveCaptureHasLiveValue = false
            self.curveCaptureCanFinish = false
            self.curveCaptureError = ""
        }
    }

    /// CoreMIDI-thread seam: records the latest raw value for an active
    /// capture session, if this CC event matches the session's FROZEN
    /// binding identity — captured once at `startCurveCalibration`, never
    /// re-read from `currentMIDIDeviceMapping` for this comparison. This
    /// is what makes the session immune to a mid-session relearn/replace
    /// of the same action silently retargeting it at a different physical
    /// control, and avoids touching the `@Published` mapping from the
    /// CoreMIDI thread entirely. The platter's CC6 flood and every
    /// unrelated fader/pad are ignored by construction (the frozen
    /// binding can never itself be CC6). Never writes to disk, never
    /// starts or affects MIDI Learn, never touches the learned binding.
    /// Bounded-rate UI publish, same throttle discipline as calibration's
    /// observed-value publish.
    ///
    /// Called from the real CoreMIDI packet-parsing loop for every
    /// incoming CC message; also callable directly from tests as a seam.
    func evaluateCurveCaptureForCC(channel: Int, controller: Int, value: Int) {
        midiCaptureLock.lock()
        let capturing = isCurveCapturing
        let binding = curveCaptureBindingIdentity
        midiCaptureLock.unlock()
        guard capturing, let binding else { return }
        guard binding.messageType == .controlChange,
              binding.channel == channel,
              binding.controlNumber == controller
        else { return }

        let now = CACurrentMediaTime()
        midiCaptureLock.lock()
        curveCaptureLastRawValue = value
        let shouldPublish = !isCurveCapturePublishPending
            && (now - lastCurveCapturePublishTime >= curveCapturePublishInterval)
        let generation = curveCaptureGeneration
        if shouldPublish {
            lastCurveCapturePublishTime = now
            isCurveCapturePublishPending = true
        }
        midiCaptureLock.unlock()

        guard shouldPublish else { return }

        publishOnMainAsync(field: "curveCaptureObserved") { [weak self] in
            guard let self else { return }
            self.midiCaptureLock.lock()
            let currentGeneration = self.curveCaptureGeneration
            self.isCurveCapturePublishPending = false
            self.midiCaptureLock.unlock()
            // A stale publication — enqueued before a Cancel, Finish, or a
            // new session started — must never resurrect this UI state.
            guard currentGeneration == generation else { return }
            if !self.curveCaptureHasLiveValue { self.curveCaptureHasLiveValue = true }
        }
    }

    /// Recomputes `curveCaptureCanFinish` from the current pending points
    /// and the active session's action, resolved against the CURRENT
    /// learned control's min/max/inversion. Main-thread only (reads/
    /// writes only `@Published` state). True only when both points exist,
    /// differ, and produce a finite, non-degenerate span — the identical
    /// guard `FaderCurveResponse.gain` itself applies, computed here so
    /// the UI can gate Finish before `finishCurveCalibration()` is ever
    /// called, per Defect 1.
    private func refreshCurveCaptureCanFinish() {
        midiCaptureLock.lock()
        let action = curveCaptureAction
        let closed = curveCapturePendingClosedRawValue
        let fullOn = curveCapturePendingFullOnRawValue
        midiCaptureLock.unlock()
        guard let action, let closed, let fullOn, closed != fullOn,
              let control = currentMIDIDeviceMapping?.control(for: action)
        else {
            curveCaptureCanFinish = false
            return
        }
        let zeroAt = control.normalizedValue(from: min(max(closed, 0), 127))
        let oneAt = control.normalizedValue(from: min(max(fullOn, 0), 127))
        curveCaptureCanFinish = zeroAt.isFinite && oneAt.isFinite && abs(oneAt - zeroAt) >= 1e-6
    }

    /// "Set closed" button: stashes whatever the latest matching raw value
    /// is RIGHT NOW as the pending closed point. Pending state only — no
    /// persistence.
    func captureCurveClosedPoint() {
        midiCaptureLock.lock()
        guard isCurveCapturing, let raw = curveCaptureLastRawValue else {
            midiCaptureLock.unlock()
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Move the control to its closed position first."
            }
            return
        }
        curveCapturePendingClosedRawValue = raw
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "curveCapture") { [weak self] in
            guard let self else { return }
            self.curveCaptureHasClosedPoint = true
            self.curveCaptureError = ""
            self.refreshCurveCaptureCanFinish()
        }
    }

    /// "Set full-on" button — mirrors `captureCurveClosedPoint`.
    func captureCurveFullOnPoint() {
        midiCaptureLock.lock()
        guard isCurveCapturing, let raw = curveCaptureLastRawValue else {
            midiCaptureLock.unlock()
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Move the control to its full-on position first."
            }
            return
        }
        curveCapturePendingFullOnRawValue = raw
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "curveCapture") { [weak self] in
            guard let self else { return }
            self.curveCaptureHasFullOnPoint = true
            self.curveCaptureError = ""
            self.refreshCurveCaptureCanFinish()
        }
    }

    /// Fully ends the active curve-capture session (Finish-succeeded or
    /// Cancel path): clears realtime session state under the lock, bumps
    /// the generation token, and resets every UI-facing mirror on main via
    /// `publishOnMainAsync` — the same dispatch discipline every other
    /// `@Published` mutation in this file uses, regardless of whether the
    /// caller happens to already be on main. `errorMessage` is published
    /// in the SAME main-thread block as the reset (nil leaves
    /// `curveCaptureError` untouched — used by the Finish-success path,
    /// which clears it itself afterward with fresh persisted state
    /// already applied).
    private func clearCurveCaptureSession(errorMessage: String? = nil) {
        midiCaptureLock.lock()
        isCurveCapturing = false
        curveCaptureAction = nil
        curveCaptureDeviceID = nil
        curveCaptureBindingIdentity = nil
        curveCaptureGeneration &+= 1
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "curveCapture") { [weak self] in
            guard let self else { return }
            self.activeCurveCaptureAction = nil
            self.curveCaptureHasClosedPoint = false
            self.curveCaptureHasFullOnPoint = false
            self.curveCaptureHasLiveValue = false
            self.curveCaptureCanFinish = false
            if let errorMessage {
                self.curveCaptureError = errorMessage
            }
        }
    }

    /// Requires two distinct captured raw positions that resolve to a
    /// finite, non-degenerate span through the CURRENT learned control's
    /// calibration, AND that the session's frozen device/binding identity
    /// still matches what's actually learned right now. Atomically
    /// persists `.custom` + the capture, then resolves and pushes it to
    /// the controller — this is the ONLY place a custom curve actually
    /// becomes active; selecting Custom or capturing individual points
    /// never does.
    ///
    /// Validation happens BEFORE the session is touched (Defect 1): an
    /// invalid Finish (missing/identical points, a degenerate resolved
    /// span, or a stale device/binding) leaves `isCurveCapturing`,
    /// `curveCaptureAction`, and every pending point exactly as they were
    /// — the capture UI stays open with a visible, actionable error, and
    /// the user can correct one point and Finish again without
    /// restarting, or Cancel. The session is cleared ONLY once the queued
    /// persistence mutation has actually applied the intended write; if a
    /// race causes that write to be silently skipped, the session is left
    /// active (never torn down early) so the completion's failure branch
    /// still has a live session to report against.
    func finishCurveCalibration() {
        midiCaptureLock.lock()
        let action = curveCaptureAction
        let closed = curveCapturePendingClosedRawValue
        let fullOn = curveCapturePendingFullOnRawValue
        let capturedDeviceID = curveCaptureDeviceID
        let capturedBinding = curveCaptureBindingIdentity
        midiCaptureLock.unlock()

        // No active session at all — nothing to validate or end.
        guard let action else { return }

        guard let closed, let fullOn else {
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Set both closed and full-on before finishing."
            }
            return
        }
        guard closed != fullOn else {
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Closed and full-on were the same position — move the control before capturing full-on, then try again."
            }
            return
        }

        // Identity check (Defect 2): the device and exact binding this
        // session started on must still be what's actually learned now.
        guard let capturedDeviceID, let capturedBinding,
              selectedMIDIInputSourceID == capturedDeviceID,
              let control = currentMIDIDeviceMapping?.control(for: action),
              control.messageType == capturedBinding.messageType,
              control.channel == capturedBinding.channel,
              control.controlNumber == capturedBinding.controlNumber
        else {
            clearCurveCaptureSession(errorMessage: "The MIDI mapping changed during capture — start again.")
            return
        }

        // Degeneracy check (Defect 1): distinct raw values can still
        // normalize to the same, or a near-identical, endpoint under
        // narrow calibration or extreme inversion — reject exactly like
        // `FaderCurveResponse.gain`'s own span guard would.
        let clampedClosed = min(max(closed, 0), 127)
        let clampedFullOn = min(max(fullOn, 0), 127)
        let zeroAt = control.normalizedValue(from: clampedClosed)
        let oneAt = control.normalizedValue(from: clampedFullOn)
        guard zeroAt.isFinite, oneAt.isFinite, abs(oneAt - zeroAt) >= 1e-6 else {
            publishOnMainAsync(field: "curveCaptureError") { [weak self] in
                self?.curveCaptureError = "Closed and full-on normalize to the same position under the current calibration — move the control further and capture full-on again."
            }
            return
        }

        let expectedConfig = MIDIFaderCurveConfig(
            preset: .custom,
            customCapture: FaderCurveCapture(closedRawValue: closed, fullOnRawValue: fullOn)
        )
        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            // Re-verify the frozen identity against the in-queue mapping —
            // never a main-thread snapshot that may predate an earlier
            // enqueued write (see `finishCalibration`). A mismatch here
            // means the binding changed between this call and the queued
            // write actually running; skip the write rather than
            // corrupting a different binding's curve.
            guard let existing = mapping.control(for: action),
                  existing.messageType == capturedBinding.messageType,
                  existing.channel == capturedBinding.channel,
                  existing.controlNumber == capturedBinding.controlNumber
            else { return }
            let updated = MIDILearnedControl(
                action: existing.action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: existing.minValue,
                maxValue: existing.maxValue,
                inverted: existing.inverted,
                assignedSampleID: existing.assignedSampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: expectedConfig
            )
            mapping.upsert(updated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            guard mapping.control(for: action)?.curveConfig == expectedConfig else {
                // The transform's identity re-check bailed: something
                // changed underneath this Finish between validation and
                // the queued write actually running. Nothing was
                // persisted — leave the session exactly as it was (never
                // torn down early, per Defect 1 point 5/6) so the error is
                // visible and the user can retry or Cancel.
                self.curveCaptureError = "The MIDI mapping changed while saving — try Finish again or Cancel."
                return
            }
            self.clearCurveCaptureSession(errorMessage: "")
            if let control = mapping.control(for: action) {
                self.pushResolvedCurve(for: control)
            }
        })
    }

    /// Discards pending capture state. No persistence write — the
    /// previously persisted curve (if any) and the controller's
    /// currently-applied resolved curve are both left byte-identical to
    /// before this session started.
    func cancelCurveCalibration() {
        clearCurveCaptureSession(errorMessage: "")
    }

    /// Evaluates whether this CC event matches a learned mixer control. The
    /// right upfader and crossfader keep feeding the existing scratch renderer;
    /// the left upfader always publishes a calibrated/curved gain for the
    /// macOS beat and demo players (unconditionally, independent of scratch
    /// gain), and separately mirrors into the same scratch-gain path as the
    /// right upfader ONLY when the device has no right-upfader mapping at
    /// all — right stays authoritative whenever it's mapped. Matching
    /// remains exact `(channel, controller)`, so the platter's CC6 flood
    /// cannot match any fader binding.
    ///
    /// Called from the real CoreMIDI packet-parsing loop for every incoming
    /// CC message; also callable directly from tests as a seam.
    func mappedMixerControlForCC(channel: Int, controller: Int) -> String? {
        guard let mapping = currentMIDIDeviceMapping else { return nil }
        for action in [
            MIDISemanticAction.crossfader,
            .leftUpfader,
            .rightUpfader
        ] {
            guard let control = mapping.control(for: action),
                  control.messageType == .controlChange,
                  control.channel == channel,
                  control.controlNumber == controller else {
                continue
            }
            return action.rawValue
        }
        return nil
    }

    func evaluateUserMixerGainForCC(channel: Int, controller: Int, value: Int) {
        guard let mapping = currentMIDIDeviceMapping else { return }
        if let leftUpfader = mapping.control(for: .leftUpfader),
           leftUpfader.messageType == .controlChange,
           leftUpfader.channel == channel,
           leftUpfader.controlNumber == controller {
            let normalizedPosition = leftUpfader.normalizedValue(from: value)
            let outputGain = FaderCurveResponse.gain(
                forNormalizedPosition: normalizedPosition,
                response: leftUpfader.resolvedCurveConfig.resolvedResponse(for: leftUpfader)
            )
            queueControllerActivity(.leftUpfader(rawValue: value, outputGain: outputGain))
        }
        if let rightUpfader = mapping.control(for: .rightUpfader),
           rightUpfader.messageType == .controlChange,
           rightUpfader.channel == channel,
           rightUpfader.controlNumber == controller {
            scratchPlaybackController.setRightUpfaderGain(rightUpfader.normalizedValue(from: value))
            queueControllerActivity(.rightUpfader(rawValue: value))
        } else if mapping.control(for: .rightUpfader) == nil,
                  let leftUpfader = mapping.control(for: .leftUpfader),
                  leftUpfader.messageType == .controlChange,
                  leftUpfader.channel == channel,
                  leftUpfader.controlNumber == controller {
            // Right upfader stays authoritative for scratch gain whenever the
            // device has one mapped at all — even for a CC event that isn't
            // its own (e.g. the left fader's CC on a different channel), so
            // it must never fall through to this branch. Only mirror left
            // upfader into the same gain path when there is no right-upfader
            // mapping on this device whatsoever, matching the iOS parity
            // fallback in `IOSMIDIControllerDispatcher.receive(_:)`.
            scratchPlaybackController.setRightUpfaderGain(leftUpfader.normalizedValue(from: value))
        }
        if let crossfader = mapping.control(for: .crossfader),
           crossfader.messageType == .controlChange,
           crossfader.channel == channel,
           crossfader.controlNumber == controller {
            scratchPlaybackController.setCrossfaderPosition(crossfader.normalizedValue(from: value))
            queueControllerActivity(.crossfader(rawValue: value))
        }
    }

    /// Coalesces high-rate controller input to at most one pending main-queue
    /// publication while retaining the newest value for every control.
    private func queueControllerActivity(_ update: ControllerActivityUpdate) {
        midiCaptureLock.lock()
        switch update {
        case .crossfader(let rawValue):
            pendingControllerActivity.crossfaderRawValue = rawValue
        case .leftUpfader(let rawValue, let outputGain):
            pendingControllerActivity.leftUpfaderRawValue = rawValue
            pendingControllerActivity.leftUpfaderOutputGain = outputGain
        case .rightUpfader(let rawValue):
            pendingControllerActivity.rightUpfaderRawValue = rawValue
        case .hotCue(let index, let sampleID):
            pendingControllerActivity.hotCueIndex = index
            pendingControllerActivity.hotCueSampleID = sampleID
        }
        let shouldSchedule = !isControllerActivityPublishPending
        if shouldSchedule {
            isControllerActivityPublishPending = true
        }
        midiCaptureLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.midiCaptureLock.lock()
            let snapshot = self.pendingControllerActivity
            self.isControllerActivityPublishPending = false
            self.midiCaptureLock.unlock()

            if self.liveCrossfaderRawValue != snapshot.crossfaderRawValue {
                self.liveCrossfaderRawValue = snapshot.crossfaderRawValue
            }
            if self.liveLeftUpfaderRawValue != snapshot.leftUpfaderRawValue {
                self.liveLeftUpfaderRawValue = snapshot.leftUpfaderRawValue
            }
            if self.liveRightUpfaderRawValue != snapshot.rightUpfaderRawValue {
                self.liveRightUpfaderRawValue = snapshot.rightUpfaderRawValue
            }
            if self.liveHotCueIndex != snapshot.hotCueIndex {
                self.liveHotCueIndex = snapshot.hotCueIndex
            }
            if self.liveHotCueSampleID != snapshot.hotCueSampleID {
                self.liveHotCueSampleID = snapshot.hotCueSampleID
            }
            if self.leftUpfaderOutputGain != snapshot.leftUpfaderOutputGain {
                self.leftUpfaderOutputGain = snapshot.leftUpfaderOutputGain
            }
            self.leftUpfaderOutputHandler?(snapshot.leftUpfaderOutputGain)
        }
    }

    /// Evaluates whether an active calibration session should accumulate this
    /// CC event's raw value. Only accumulates events on the EXACT (channel,
    /// controller) already learned for the action being calibrated — this is
    /// what makes calibration ignore unrelated controls and the platter's CC6
    /// flood, since neither can ever match a fader's already-learned binding
    /// (CC6 itself can never become a learned binding in the first place, per
    /// `evaluateMIDILearnForCC`'s platter-flood filter).
    ///
    /// Called from the real CoreMIDI packet-parsing loop for every incoming CC
    /// message; also callable directly from tests as a seam.
    func evaluateCalibrationForCC(channel: Int, controller: Int, value: Int) {
        midiCaptureLock.lock()
        let calibrating = isCalibrating
        let action = calibratingAction
        midiCaptureLock.unlock()
        guard calibrating, let action else { return }
        guard let learnedControl = currentMIDIDeviceMapping?.control(for: action) else { return }
        guard learnedControl.messageType == .controlChange,
              learnedControl.channel == channel,
              learnedControl.controlNumber == controller
        else { return }

        // Raw accumulation is unconditional and lossless: every matching
        // event updates the accumulator under the lock, regardless of
        // whether this particular event also triggers a UI publish below.
        let now = CACurrentMediaTime()
        midiCaptureLock.lock()
        if calibrationSawAnyEvent {
            calibrationMinAccumulator = min(calibrationMinAccumulator, value)
            calibrationMaxAccumulator = max(calibrationMaxAccumulator, value)
        } else {
            calibrationMinAccumulator = value
            calibrationMaxAccumulator = value
            calibrationSawAnyEvent = true
        }
        // Throttle the UI-facing publish to a bounded rate: at most one
        // publish in flight (`isCalibrationObservedPublishPending` gates
        // re-entry) and no faster than `calibrationPublishInterval` — never
        // one `DispatchQueue.main.async` per matching event. The queued
        // block re-reads the accumulator under the lock at execution time,
        // so it always reflects the newest values even if more events
        // arrived while it waited, and separately re-checks the generation
        // token to detect a cancel/finish/new-session that happened since
        // this publish was enqueued.
        let shouldPublish = !isCalibrationObservedPublishPending
            && (now - lastCalibrationObservedPublishTime >= calibrationPublishInterval)
        let generation = calibrationGeneration
        if shouldPublish {
            lastCalibrationObservedPublishTime = now
            isCalibrationObservedPublishPending = true
        }
        midiCaptureLock.unlock()

        guard shouldPublish else { return }

        publishOnMainAsync(field: "calibrationObserved") { [weak self] in
            guard let self else { return }
            self.midiCaptureLock.lock()
            let currentGeneration = self.calibrationGeneration
            let observedMin = self.calibrationMinAccumulator
            let observedMax = self.calibrationMaxAccumulator
            self.isCalibrationObservedPublishPending = false
            self.midiCaptureLock.unlock()
            self.testOnly_calibrationObservedPublishCount += 1

            // A stale publication — enqueued before a Cancel, Finish, or a
            // new calibration session started — must never restore or
            // overwrite the current calibration UI state.
            guard currentGeneration == generation else { return }
            self.calibrationObservedMin = observedMin
            self.calibrationObservedMax = observedMax
        }
    }

    /// Finish the active calibration session: validates the observed range
    /// and, if acceptable, persists it as the control's new min/max (keeping
    /// its current inversion — inversion is set independently via
    /// `setInversion(_:for:)`). Rejects — without persisting — an unusably
    /// narrow range or a session that observed no movement at all. Runs the
    /// persistence on `midiMappingPersistenceQueue`, never on main.
    func finishCalibration() {
        midiCaptureLock.lock()
        let action = calibratingAction
        let observedMin = calibrationMinAccumulator
        let observedMax = calibrationMaxAccumulator
        let sawEvent = calibrationSawAnyEvent
        isCalibrating = false
        calibratingAction = nil
        calibrationGeneration &+= 1
        midiCaptureLock.unlock()

        guard let action else { return }

        publishOnMainAsync(field: "calibration") { [weak self] in
            guard let self else { return }
            self.activeCalibrationAction = nil
            self.calibrationObservedMin = nil
            self.calibrationObservedMax = nil
        }

        guard sawEvent else {
            publishOnMainAsync(field: "calibrationError") { [weak self] in
                self?.calibrationError = "No movement observed for \(action.displayName) — move the control through its full travel, then finish calibration."
            }
            return
        }

        let observedRange = observedMax - observedMin
        guard observedRange >= Self.minimumCalibrationRange else {
            publishOnMainAsync(field: "calibrationError") { [weak self] in
                self?.calibrationError = "Calibration for \(action.displayName) covered too narrow a range (\(observedRange) of 127) — move the control through its full travel and finish again."
            }
            return
        }

        // Cheap pre-check on the main-thread cache for a fast, visible error —
        // the authoritative check happens again inside the queued transform
        // below, against whatever the mapping actually is by the time this
        // mutation runs (never a stale snapshot captured before enqueuing).
        guard currentMIDIDeviceMapping?.control(for: action) != nil else {
            publishOnMainAsync(field: "calibrationError") { [weak self] in
                self?.calibrationError = "\(action.displayName) is no longer learned; learn it again before calibrating."
            }
            return
        }

        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            // Derive the calibrated control from whatever is ACTUALLY in the
            // mapping at the moment this runs (which reflects every earlier
            // enqueued write, in order) — never from a value captured on the
            // caller's thread before this mutation was even enqueued.
            guard let existing = mapping.control(for: action) else { return }
            let calibrated = MIDILearnedControl(
                action: existing.action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: observedMin,
                maxValue: observedMax,
                inverted: existing.inverted,
                assignedSampleID: existing.assignedSampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: existing.curveConfig   // calibration doesn't touch the curve, only what raw values mean
            )
            mapping.upsert(calibrated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            self.calibrationError = ""
            // The control's raw-value-to-normalized mapping just changed.
            // A custom curve's endpoints are derived from raw values
            // through THIS mapping, so they must be re-resolved now, not
            // just reset to unity — pushResolvedCurve does both atomically.
            // For the default/fixed presets this resolves to the exact
            // same constants as before, so non-custom mappings see no
            // behavior change here.
            if let control = mapping.control(for: action) {
                self.pushResolvedCurve(for: control)
            }
        })
    }

    /// Sets (and persists) the inversion flag for an already-learned continuous
    /// action, independent of calibration — an explicit, standalone toggle.
    /// Runs the persistence on `midiMappingPersistenceQueue`, never on main.
    func setInversion(_ inverted: Bool, for action: MIDISemanticAction) {
        guard let existingBeforeChange = currentMIDIDeviceMapping?.control(for: action) else { return }
        // Cheap pre-check on the main-thread cache, mirroring the pattern
        // already used above: only an ACTUAL flip changes what the
        // control's raw values mean. A same-value call (e.g. a UI toggle
        // round-tripping) must not audibly reset gain for nothing.
        let didChange = existingBeforeChange.inverted != inverted
        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            // See `finishCalibration` — derive from the in-queue mapping, not a
            // main-thread snapshot that may predate an earlier in-flight write.
            guard let existing = mapping.control(for: action), existing.inverted != inverted else { return }
            let updated = MIDILearnedControl(
                action: existing.action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: existing.minValue,
                maxValue: existing.maxValue,
                inverted: inverted,
                assignedSampleID: existing.assignedSampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: existing.curveConfig   // inversion doesn't touch the curve, only what raw values mean
            )
            mapping.upsert(updated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            guard didChange else { return }
            // Inversion flips how raw values map to gain — a custom
            // curve's endpoints depend on that mapping, so re-resolve and
            // push (also resets to unity), same reasoning as
            // `finishCalibration`.
            if let control = mapping.control(for: action) {
                self.pushResolvedCurve(for: control)
            }
        })
    }

    /// Clear a learned mapping for a specific action, removing it from the
    /// device profile and persisting the change.
    func clearMapping(for action: MIDISemanticAction) {
        // A pending curve-capture session for this action refers to a
        // binding that's about to be removed — it can never be finished
        // meaningfully. Cancel it; nothing was persisted from it, so
        // there's nothing to roll back beyond the session state itself.
        midiCaptureLock.lock()
        let shouldCancelCurveCapture = isCurveCapturing && curveCaptureAction == action
        midiCaptureLock.unlock()
        if shouldCancelCurveCapture { cancelCurveCalibration() }

        let deviceID = selectedMIDIInputSourceID
        enqueueRemoveAction(deviceID: deviceID, action: action) { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            // Clear legacy state too if crossfader
            if action == .crossfader {
                self.midiCaptureLock.lock()
                self.persistedCrossfaderMapping = nil
                self.midiCaptureLock.unlock()
                UserDefaults.standard.removeObject(forKey: ScratchLabDesktopDefaultsKey.crossfaderMIDIMapping)
                self.crossfaderCCMapping = nil
                // The cleared control's last value must not keep muting
                // audio — only this control resets; the other's current
                // contribution is preserved.
                self.scratchPlaybackController.resetCrossfaderGainToUnity()
            } else if action == .rightUpfader {
                self.scratchPlaybackController.resetRightUpfaderGainToUnity()
            }
            if self.midiLearnState != .idle { self.midiLearnState = .idle }
            if self.midiLearnFeedback != "" { self.midiLearnFeedback = "" }
        }
    }

    /// Clear ALL learned mappings for the current device.
    func clearDeviceMappings() {
        midiCaptureLock.lock()
        let shouldCancelCurveCapture = isCurveCapturing
        midiCaptureLock.unlock()
        if shouldCancelCurveCapture { cancelCurveCalibration() }

        let deviceID = selectedMIDIInputSourceID
        enqueueDeleteDevice(deviceID: deviceID) { [weak self] in
            guard let self else { return }
            self.currentMIDIDeviceMapping = nil
            // Also clear legacy
            self.midiCaptureLock.lock()
            self.persistedCrossfaderMapping = nil
            self.midiCaptureLock.unlock()
            UserDefaults.standard.removeObject(forKey: ScratchLabDesktopDefaultsKey.crossfaderMIDIMapping)
            self.crossfaderCCMapping = nil
            // Neither control's mapping is trustworthy anymore.
            self.scratchPlaybackController.resetUserMixerGainToUnity()
            if self.midiLearnState != .idle { self.midiLearnState = .idle }
            if self.midiLearnFeedback != "" { self.midiLearnFeedback = "" }
        }
    }

    /// Load the learned device mapping for the currently selected MIDI source.
    /// Called whenever the selected MIDI source changes.
    func loadDeviceMappingForCurrentSource() {
        // A source change or mapping reload invalidates any in-progress
        // curve-capture session unconditionally (Defect 2) — its frozen
        // device ID can no longer be trusted to mean "the currently
        // selected device", regardless of which action it was capturing.
        // Same unconditional-regardless-of-action precedent as
        // `clearDeviceMappings`'s existing cancellation below.
        midiCaptureLock.lock()
        let shouldCancelCurveCapture = isCurveCapturing
        midiCaptureLock.unlock()
        if shouldCancelCurveCapture {
            clearCurveCaptureSession(errorMessage: "The MIDI source changed during capture — start again.")
        }

        // A MIDI source change is a new session for the learned-mixer gain
        // contributions, regardless of outcome below: empty source ID, a
        // successful load (even one with mappings for both controls), or a
        // load failure. Reset unconditionally, before any of those exit
        // paths, so a stale value from the previous device (e.g. a
        // crossfader last seen at 0) can never leak into the new session.
        // Both controls stay at unity until a fresh matching CC event
        // arrives under the (possibly new) mapping. Queued on `audioQueue`,
        // so it is ordered after any gain-setting calls already enqueued
        // from the previous device's last events and before any from the
        // new one.
        scratchPlaybackController.resetUserMixerGainToUnity()

        let deviceID = selectedMIDIInputSourceID
        guard !deviceID.isEmpty else {
            publishOnMainAsync(field: "currentMIDIDeviceMapping") { [weak self] in
                guard let self else { return }
                self.currentMIDIDeviceMapping = nil
                self.midiMappingError = ""
            }
            return
        }
        let loadedMapping: MIDIDeviceMapping?
        let mappingError: String
        do {
            loadedMapping = try midiMappingStore.loadOrThrow(deviceIdentifier: deviceID)
            mappingError = ""
        } catch {
            // Fail visibly and safely: no mapping is applied for this device rather
            // than risking a partially-decoded or wrong-schema mapping driving hardware.
            loadedMapping = nil
            mappingError = "Could not load saved MIDI mapping for \(selectedMIDIInputSourceName): \(error.localizedDescription)"
        }
        // Also restore legacy crossfader for backward compat
        if let mapping = loadedMapping?.control(for: .crossfader) {
            let legacy = CrossfaderCCMapping(channel: mapping.channel, controller: mapping.controlNumber)
            midiCaptureLock.lock()
            persistedCrossfaderMapping = legacy
            midiCaptureLock.unlock()
            publishOnMainAsync(field: "crossfaderCCMapping") { [weak self] in
                self?.crossfaderCCMapping = legacy
            }
        }
        publishOnMainAsync(field: "currentMIDIDeviceMapping") { [weak self] in
            guard let self else { return }
            self.currentMIDIDeviceMapping = loadedMapping
            self.midiMappingError = mappingError
        }

        // The new device may have an entirely different curve configured
        // than the previous one — push each control's resolved curve now,
        // rather than leaving the controller holding the PREVIOUS device's
        // stale resolved response until its next CC event happens to
        // arrive. Controls this device hasn't learned stay at the unity
        // reset already performed above (curve is moot while unmapped).
        if let crossfaderControl = loadedMapping?.control(for: .crossfader) {
            pushResolvedCurve(for: crossfaderControl)
        }
        if let rightUpfaderControl = loadedMapping?.control(for: .rightUpfader) {
            pushResolvedCurve(for: rightUpfaderControl)
        }
        if mappingError.isEmpty {
            seedVerifiedRaneOneMKIIMappingIfNeeded(existingMapping: loadedMapping)
        }
    }

    // MARK: - Hot-Cue Sample Assignment

    /// Assign a scratch sample ID to a learned hot-cue mapping for the current device.
    func assignSampleToHotCue(_ sampleID: String, hotCueIndex: Int) {
        guard let action = MIDISemanticAction.allCases.first(where: { $0.hotCueIndex == hotCueIndex }),
              !selectedMIDIInputSourceID.isEmpty,
              currentMIDIDeviceMapping?.control(for: action) != nil
        else { return }
        guard ScratchSamplePlaybackController.knownSampleIDs.contains(sampleID) else {
            midiMappingError = "Sample \"\(sampleID)\" is not available and was not assigned."
            return
        }
        let deviceID = selectedMIDIInputSourceID
        let deviceName = selectedMIDIInputSourceName
        mutateDeviceMapping(deviceID: deviceID, deviceName: deviceName, transform: { mapping in
            // Derive from the in-queue mapping — see `finishCalibration`.
            guard let existing = mapping.control(for: action) else { return }
            let updated = MIDILearnedControl(
                action: action,
                messageType: existing.messageType,
                channel: existing.channel,
                controlNumber: existing.controlNumber,
                deck: existing.deck,
                minValue: existing.minValue,
                maxValue: existing.maxValue,
                inverted: existing.inverted,
                assignedSampleID: sampleID,
                learnedAt: existing.learnedAt,
                isVerified: existing.isVerified,
                curveConfig: existing.curveConfig   // always nil for a hot-cue action; threaded for consistency
            )
            mapping.upsert(updated)
        }, completion: { [weak self] mapping in
            guard let self else { return }
            self.currentMIDIDeviceMapping = mapping
            self.midiMappingError = ""
        })
    }

    // MARK: - Hot-Cue Sample Resolution & Loading (Phase 4)

    /// True when `currentMIDIDeviceMapping` has a learned hot-cue action for
    /// this exact `(messageType, channel, controlNumber)` — the same
    /// membership check `resolveAndLoadHotCueSample` itself uses to find a
    /// match, hoisted so callers can cheaply skip entering the resolver (and
    /// its diagnostic trace) entirely for events that could never match.
    ///
    /// Diagnostic/routing-boundary fix, 2026-08-14: a hardware trace showed
    /// `resolveAndLoadHotCueSample` — and its `[HotCueTrace]` log — firing
    /// continuously for an unrelated, high-frequency CC stream (a fader/
    /// knob, CC6 on channel 1), drowning out the actual hot-cue sequence.
    /// Purely data-driven from the learned mapping/action registry — no
    /// hardcoded CC numbers — so generic MIDI Learn for any control/action
    /// pairing is unaffected; only genuinely unmapped-as-hot-cue traffic is
    /// filtered before it ever reaches the resolver.
    private func isHotCueCandidate(messageType: LearnedMIDIMessageType, channel: Int, controlNumber: Int) -> Bool {
        guard let mapping = currentMIDIDeviceMapping else { return false }
        let resolved = MIDIActionResolver.resolve(
            learnedType: messageType,
            channel: channel,
            controlNumber: controlNumber,
            value: 127,
            mapping: mapping
        )
        if case .hotCue(let action, _) = resolved { return action != nil }
        return false
    }

    /// Resolve a MIDI CC or Note On event against the current device's learned
    /// hot-cue mappings. If a mapping matches and has an assigned sample, dispatch
    /// the load through the serialized scratch-sample loading path.
    ///
    /// - Returns: `true` if the event matched a learned hot cue and a sample load
    ///   was requested (queued, not yet complete). `false` if no match or no sample.
    ///
    /// Threading: safe to call from the CoreMIDI callback — no file I/O, no blocking
    /// dispatch, no SwiftUI access. Only enqueues a load onto the controller's private
    /// audio queue.
    private func resolveAndLoadHotCueSample(
        messageType: LearnedMIDIMessageType,
        channel: Int,
        controlNumber: Int,
        value: Int
    ) -> Bool {
        #if DEBUG
        // Intermittent hot-cue-retrigger investigation (2026-08-14): every
        // call, unconditionally — including early-outs (release events, no
        // learned mapping, no match) — so a duplicate call for the same
        // physical press is visible even when it doesn't end up matching.
        print("[HotCueTrace] resolveAndLoadHotCueSample called · messageType=\(messageType) " +
              "channel=\(channel) controlNumber=\(controlNumber) value=\(value)")
        #endif
        // Only handle press events (not release).
        guard value > 0 else { return false }
        guard let mapping = currentMIDIDeviceMapping else { return false }

        // Resolve the hot-cue action through the shared semantic resolver
        // (learned hot-cue mapping only — a nil action means the pad-router
        // fallback, which is not the production hot-cue load path).
        let resolved = MIDIActionResolver.resolve(
            learnedType: messageType,
            channel: channel,
            controlNumber: controlNumber,
            value: value,
            mapping: mapping
        )
        // Extract the learned hot-cue action for display, then let the shared
        // trigger resolver make the "should fire" decision. No transport gating
        // on macOS — the platter-driven hot-cue path has no transport toggle.
        guard case .hotCue(let action, _) = resolved, let action else {
            return false
        }
        let decision = HotCueTriggerResolver.resolve(action: resolved)
        guard decision.shouldTrigger, let sampleID = decision.sampleID else {
            return false
        }
        guard allowsLocalScratchPlayback else {
            print("[HotCueAutoLoad] suppressed · ScratchLab audio unavailable")
            return false
        }

        queueControllerActivity(.hotCue(index: action.hotCueIndex ?? 0, sampleID: sampleID))

        print("[HotCueAutoLoad] matched · action=\(action.displayName) sample=\(sampleID) channel=\(channel) control=\(controlNumber)")
        // Enqueue the load onto the controller's private audio queue — no file I/O
        // or blocking on the MIDI callback.
        // A hot-cue press must only arm platter-controlled playback. The
        // controller's diagnostic preview plays the first 350 ms through a
        // separate player node; enabling it here duplicates the vocal onset
        // immediately before the continuous renderer starts at the cue point.
        let requested = scratchPlaybackController.load(
            sampleID: sampleID,
            playDiagnosticPreview: false
        )
        #if DEBUG
        if requested {
            testOnly_hotCueLoadObserver?(sampleID)
        }
        #endif
        if !requested {
            print("[HotCueAutoLoad] load request rejected · sampleID=\(sampleID)")
            // Fail visibly: a hot cue pointing at a removed/missing sample should be
            // obvious in the UI, not a silent no-op on the pad press.
            publishOnMainAsync(field: "midiMappingError") { [weak self] in
                let message = "\(action.displayName) is mapped to missing sample \"\(sampleID)\"."
                if self?.midiMappingError != message { self?.midiMappingError = message }
            }
        }
        return requested
    }

    private func setupMIDIClient() {
        guard midiClient == 0 else { return }
        MIDIClientCreate("ScratchLab.MIDICapture" as CFString, nil, nil, &midiClient)
        guard midiClient != 0 else { return }
        MIDIInputPortCreateWithBlock(midiClient, "ScratchLab.MIDIIn" as CFString, &midiInputPort) { [weak self] packetList, _ in
            self?.receiveMIDIPacketList(packetList)
        }
    }

    private func openMIDIInputForRecording() {
        midiCaptureLock.lock()
        capturedMidiCCEvents = []
        midiRecordingStartTime = CACurrentMediaTime()
        #if DEBUG
        debugMidiEventsCapturedThisTake = 0
        #endif
        midiCaptureLock.unlock()
        reconnectSelectedMIDIInput()
    }

    private func closeMIDIInput() {
        guard midiInputPort != 0 else { return }
        for endpoint in midiSourceEndpoints.values {
            MIDIPortDisconnectSource(midiInputPort, endpoint)
        }
        midiCaptureLock.lock()
        midiConnectedSourceName = ""
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "midiListeningState") { [weak self] in
            guard let self else { return }
            let next = self.availableMIDISources.isEmpty ? "Not Connected" : "Source Selected"
            if self.midiListeningState != next { self.midiListeningState = next }
        }
    }

    private func drainCapturedMidiCCEvents() -> [CaptureCore.RawMixerMIDIEvent] {
        midiCaptureLock.lock()
        defer {
            capturedMidiCCEvents = []
            midiRecordingStartTime = 0
            midiCaptureLock.unlock()
        }
        return capturedMidiCCEvents
    }

    /// Non-destructive counterpart to `drainCapturedMidiCCEvents()`, guarded
    /// by the exact same `midiCaptureLock` as the append site
    /// (`recordReceivedMIDICCEvent`) and the destructive drain above, so
    /// append/snapshot/drain can never race. For `LivePerformedNotationTracker`
    /// (a live, in-progress preview) — never used by finalization, which
    /// keeps using the destructive drain unchanged.
    func capturedMidiCCEventsSnapshot() -> [CaptureCore.RawMixerMIDIEvent] {
        midiCaptureLock.lock()
        defer { midiCaptureLock.unlock() }
        return capturedMidiCCEvents
    }

    /// Opens a `capturedMidiCCEvents` accumulation window for a Practice
    /// attempt's live-notation tracker, WITHOUT touching MIDI port
    /// connection (already independently established elsewhere) or any
    /// Capture-only state (sidecar, movement-debug session,
    /// `activeRoutineDetectedNotationBuilder`). `recordReceivedMIDICCEvent`
    /// only appends while `midiRecordingStartTime > 0`, so this is what
    /// makes the same accumulator Capture drains at finalization also fill
    /// during Practice — same buffer, same append/lock semantics, no second
    /// capture path. A no-op while a real Capture take is already recording
    /// (`midiRecordingStartTime` already nonzero), so it can never reset an
    /// in-progress take's events.
    func beginLiveMIDICapture() {
        midiCaptureLock.lock()
        if midiRecordingStartTime == 0 {
            capturedMidiCCEvents = []
            midiRecordingStartTime = CACurrentMediaTime()
        }
        midiCaptureLock.unlock()
    }

    /// Closes the accumulation window `beginLiveMIDICapture()` opened, when
    /// nothing else owns it. Never touches state while
    /// `isRoutineRecording == true` — Capture's own finalization path
    /// (`drainCapturedMidiCCEvents()`) remains the sole owner of ending a
    /// real take's window.
    func endLiveMIDICaptureIfIdle() {
        guard !isRoutineRecording else { return }
        midiCaptureLock.lock()
        capturedMidiCCEvents = []
        midiRecordingStartTime = 0
        midiCaptureLock.unlock()
    }

    /// Non-destructive camera-fallback movement snapshot for
    /// `LivePerformedNotationTracker` — the exact same builder/method
    /// `completeRoutineFinalization` reads (`activeRoutineDetectedNotationBuilder?
    /// .movementEvents(now:)`), never a second reconstruction algorithm.
    /// `nil` (not an empty array) when no camera builder is active at all,
    /// so the tracker can distinguish "no camera source" from "camera
    /// source present but has seen no movement yet."
    func cameraMovementEventsSnapshot(now: CFTimeInterval) -> [CaptureCore.DetectedNotationRecordMovementEvent]? {
        activeRoutineDetectedNotationBuilder?.movementEvents(now: now)
    }

    /// Builds the small dependency bundle `LivePerformedNotationTracker`
    /// polls — MIDI-controller-preferred, camera-fallback, matching
    /// `completeRoutineFinalization`'s own precedence
    /// (`resolvedControllerMovementEvents`/`usesControllerMovement`). Kept
    /// as plain closures (not a reference to `self`) so the tracker itself
    /// has no dependency on `MacCaptureEngine` and is independently
    /// testable with synthetic data sources.
    func makeLivePerformedNotationDataSource() -> LivePerformedNotationDataSource {
        LivePerformedNotationDataSource(
            selectedMIDISourceName: { [weak self] in self?.selectedMIDIInputSourceName ?? "Not Connected" },
            capturedMidiCCEventsSnapshot: { [weak self] in self?.capturedMidiCCEventsSnapshot() ?? [] },
            cameraMovementEventsSnapshot: { [weak self] now in self?.cameraMovementEventsSnapshot(now: now) }
        )
    }

    private func receiveMIDIPacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        ScratchLabPerformanceSignpost.event(
            "MIDIReceived",
            count: Int(packetListPtr.pointee.numPackets)
        )
        let now = CACurrentMediaTime()
        midiCaptureLock.lock()
        let startTime = midiRecordingStartTime
        let deviceName = midiConnectedSourceName
        midiCaptureLock.unlock()

        // CONFIRMED root cause: the original code obtained the first packet
        // pointer via `withUnsafePointer(to: packetListPtr.pointee.packet)`.
        // That passes the packet *by value* into a generic parameter — Swift
        // copies it into a temporary, and the pointer `withUnsafePointer`
        // hands back is only valid for that call's duration. The original
        // code kept using it afterwards (in the loop below), which is a
        // dangling-pointer read of whatever now occupies that stack slot.
        // The invalid decoded values reported immediately before the crash
        // (e.g. "CC ch11 cc134 val144") are consistent with exactly this:
        // stale/reused stack bytes being read as if they were live MIDI
        // data. The crash itself then trapped in `rawBytes[i]` inside
        // `withUnsafeBytes(of: packetPtr.pointee.data)` — also reachable
        // from that same dangling pointer, since whatever garbage occupied
        // `.length` at that point could easily exceed the 256-byte capacity
        // `withUnsafeBytes(of:)` can ever expose for the fixed-size `data`
        // tuple declared in CoreMIDI's header.
        //
        // No captured diagnostic recorded the actual `MIDIPacket.length` at
        // crash time, so it is NOT confirmed that Rane hardware itself ever
        // delivers a real packet longer than 256 bytes — CoreMIDI's header
        // does allow it ("[length] may be larger than 256 bytes if the
        // packet is dynamically allocated"), so reading exactly `length`
        // bytes from live storage below is correct defensive coverage of
        // that documented possibility, not a claim that this is what Rane
        // produced.
        //
        // The fix: never take the address of a `.pointee` value copy.
        // Compute `packet`'s real byte offset within `MIDIPacketList` and
        // point directly into CoreMIDI's own backing storage — mirroring
        // the C reference pattern in CoreMIDI's own header
        // (`&packetList->packet[0]`) and exactly how `data` below is read.
        let packetFieldOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        var packetPtr = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(packetListPtr).advanced(by: packetFieldOffset))
            .assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<Int(packetListPtr.pointee.numPackets) {
            let length = Int(packetPtr.pointee.length)
            // Same fix applied to `data`: read exactly `length` bytes from
            // the packet's live storage via its real field offset, rather
            // than `withUnsafeBytes(of: packetPtr.pointee.data)`, which can
            // only ever see the fixed 256-byte tuple `data` is declared
            // with — regardless of the packet's actual `length`.
            let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
            let rawBytes = UnsafeRawBufferPointer(
                start: UnsafeRawPointer(packetPtr).advanced(by: dataOffset),
                count: length
            )
            MIDIChannelMessageParser.parse(rawBytes) { [self] message in
                dispatchMIDIChannelVoiceMessage(
                    message,
                    deviceName: deviceName,
                    startTime: startTime,
                    now: now
                )
            }
            packetPtr = MIDIPacketNext(packetPtr)
        }
    }

    #if DEBUG
    /// Test-only seam: `receiveMIDIPacketList` is private and is the only
    /// entry point that reads a real `MIDIPacketList`/`MIDIPacket`
    /// allocation the way CoreMIDI actually delivers one — a synthetic
    /// `[UInt8]` array cannot exercise the live-pointer fix above, so this
    /// thin passthrough is unavoidable for regression coverage of the fixed
    /// crash. DEBUG-only: never compiled into a Release build.
    func testOnly_receiveMIDIPacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        receiveMIDIPacketList(packetListPtr)
    }

    /// Test-only seam: `currentMIDIDeviceMapping` is `private(set)` and
    /// normally only changes through the async, disk-backed
    /// `mutateDeviceMapping`/`midiMappingPersistenceQueue` path. Hotcue
    /// dispatch tests need a learned mapping in place synchronously, without
    /// touching real file I/O or the persistence queue. DEBUG-only: never
    /// compiled into a Release build.
    func testOnly_setDeviceMapping(_ mapping: MIDIDeviceMapping?) {
        currentMIDIDeviceMapping = mapping
    }

    /// Test-only seam: `scratchPlaybackController` is private. Fader-gain
    /// tests need to verify `evaluateUserMixerGainForCC` actually reached
    /// it — there is no other observable effect to assert on from outside
    /// this file. DEBUG-only: never compiled into a Release build.
    var testOnly_scratchPlaybackController: ScratchSamplePlaybackController { scratchPlaybackController }

    /// Test-only observation hook: fires exactly when `resolveAndLoadHotCueSample`
    /// dispatches a real load to `scratchPlaybackController`. Exists so Hotcue
    /// regression tests can count/inspect loads without adding spy/call-count
    /// state to the production `ScratchSamplePlaybackController`. DEBUG-only:
    /// never compiled into a Release build.
    var testOnly_hotCueLoadObserver: ((_ sampleID: String) -> Void)?
    #endif

    /// Dispatches one fully-decoded channel-voice message to the existing
    /// CC / Note-On pipelines. Behaviourally identical to the dispatch
    /// logic that used to be inlined in `receiveMIDIPacketList`'s byte
    /// loop — only how the bytes were extracted and framed has changed.
    /// `message.data1`/`data2` are guaranteed `< 0x80` by
    /// `MIDIChannelMessageParser`.
    private func dispatchMIDIChannelVoiceMessage(
        _ message: MIDIChannelMessageParser.Message,
        deviceName: String,
        startTime: CFTimeInterval,
        now: CFTimeInterval
    ) {
        let statusByte = message.status
        let rawChannel = Int(statusByte & 0x0F)
        let rawData1 = Int(message.data1)

        if statusByte & 0xF0 == 0xB0 {
            guard let data2 = message.data2 else { return }
            let channel = rawChannel
            let controller = rawData1
            let value = Int(data2)

            midiCaptureLock.lock()
            var currentMapping = persistedCrossfaderMapping
            midiCaptureLock.unlock()

            let learnResult = evaluateMIDILearnForCC(channel: channel, controller: controller, value: value)
            if let overrideMapping = learnResult.crossfaderMapping {
                currentMapping = overrideMapping
            }
            evaluateCalibrationForCC(channel: channel, controller: controller, value: value)
            evaluateCurveCaptureForCC(channel: channel, controller: controller, value: value)
            evaluateUserMixerGainForCC(channel: channel, controller: controller, value: value)

            let mappedControl = mappedMixerControlForCC(channel: channel, controller: controller)
                ?? ((currentMapping?.channel == channel && currentMapping?.controller == controller)
                    ? MIDISemanticAction.crossfader.rawValue
                    : nil)
            if mappedControl == "crossfader" {
                ScratchLabPerformanceSignpost.event("FaderMap", count: value)
            }
            // CC6 platter fast path: feed tracker → playback controller.
            // Verified Rane ONE MKII: left platter = ch=0 CC6,
            // right platter = ch=1 CC6. Pads are ch=4/ch=5 (NOT platter).
            // Both decks are tracked here for diagnostics, but only the
            // right platter (channel 1 / Deck 2) may ever drive the single
            // loaded scratch sample — product decision 2026-08-09. The left
            // platter (channel 0) stays tracked/diagnostic-only and never
            // reaches the playback controller.
            if controller == 6, channel == 0 || channel == 1 {
                platterTracker.ingest(channel: channel, value: value)
                let steps = platterTracker.accumulatedSteps(for: channel)
                let direction = platterTracker.recentDirection(for: channel)
                let bridgeNow = CACurrentMediaTime()
                if bridgeNow - lastScratchPlaybackBridgeLogTime >= scratchPlaybackBridgeLogInterval {
                    lastScratchPlaybackBridgeLogTime = bridgeNow
                    print("[ScratchSamplePlaybackBridge] platter forwarding · steps=\(steps) direction=\(String(describing: direction))")
                }
                // Suppress the raw MIDI CC6 path while DVS/timecode
                // motion is driving playback, so the two sources never
                // publish to the playback controller at the same time.
                if channel == ScratchPlatterTracker.rightChannel, !dvsPlaybackDriveActive {
                    if scratchPlaybackController.midiUsesContinuousRenderer {
                        // The controller's own coalescing timer
                        // independently samples the tracker at a bounded
                        // cadence (see `configureMIDIPlatterProvider`) — no
                        // per-event forwarding, keeping this CoreMIDI
                        // receive callback bounded and non-blocking.
                    } else {
                        // Rate-limited inside the controller (~60 Hz); CC6
                        // events fire at ~800 Hz so the controller drops
                        // excess updates. Legacy grain rollback path only.
                        scratchPlaybackController.positionDidChange(
                            steps: steps,
                            direction: direction
                        )
                    }
                }
            }
            // CC8 crossfader: diagnostics/MIDI-learn only.
            // Not wired to scratch sample playback until the crossfader
            // feature is designed and approved. No audio-path side effects.
            recordReceivedMIDICCEvent(
                sourceName: deviceName,
                channel: channel,
                controller: controller,
                value: value,
                mappedControl: mappedControl,
                timestamp: now,
                recordingStartTime: startTime,
                consumedByLearn: learnResult.consumedByLearn
            )
#if DEBUG
            // Raw pad diagnostic — only for non-platter, non-crossfader CCs.
            // CC6 (platter) floods at ~800Hz and must never trigger UI updates.
            // Dispatched to main to avoid @Published contention on the MIDI thread.
            if controller != 6,
               currentMapping?.controller != controller {
                let diag = "CC ch\(channel + 1) cc\(controller) val\(value)"
                publishOnMainAsync(field: "lastRawPadDiagnostic") { [weak self] in
                    self?.lastRawPadDiagnostic = diag
                }
                print("[RanePad] \(diag)")
            }
#endif
        } else if statusByte >= 0x80 {
            switch statusByte & 0xF0 {
            case 0x80, 0x90, 0xA0, 0xE0:
                guard let data2 = message.data2 else { return }
                let rawData2 = Int(data2)
                // Only route Note On events from known Rane pad channels to the pad preview path.
                // Start/Stop (note=0 ch=0/ch=1), PFL (note=27 ch=0/ch=1), SYNC (note=2
                // ch=1), and all PitchBend/PolyAT events must not enter the pad router.
                // Exception: while a hot-cue learn is active, route Note On from ANY
                // channel — a hot cue on a device other than the validated Rane pad
                // channels (e.g. a Pioneer S9) must still be learnable.
                if statusByte & 0xF0 == 0x90,
                   (rawChannel == 4 || rawChannel == 5 || rawChannel == 6
                    || isHotCueLearnSessionActive()) {
                    receiveNoteOnPadEvent(
                        channel: rawChannel,
                        noteNumber: rawData1,
                        velocity: rawData2
                    )
                }
#if DEBUG
                // Raw diagnostic — only for pad channels to avoid flooding the
                // diagnostic label with transport/PFL/PitchBend events.
                if rawChannel == 4 || rawChannel == 5 || rawChannel == 6 {
                    let kind: String
                    switch statusByte & 0xF0 {
                    case 0x90: kind = "Note On"
                    case 0x80: kind = "Note Off"
                    case 0xA0: kind = "PolyAT"
                    case 0xE0: kind = "PitchBend"
                    default:   kind = "MIDI"
                    }
                    let diag = "\(kind) ch\(rawChannel + 1) d1=\(rawData1) d2=\(rawData2)"
                    publishOnMainAsync(field: "lastRawPadDiagnostic") { [weak self] in
                        self?.lastRawPadDiagnostic = diag
                    }
                    print("[RanePad] \(diag)")
                }
#endif
            default:
                // 0xC0/0xD0 (Program Change / Channel Pressure) and any
                // other status byte: no downstream action on this path
                // today — matches original behaviour, which only ever
                // consumed these bytes without dispatching them anywhere.
                break
            }
        }
    }

    var selectedMIDIInputSourceName: String {
        availableMIDISources.first(where: { $0.id == selectedMIDIInputSourceID })?.name ?? "Not Connected"
    }

    var midiMonitorStatusLine: String {
        if availableMIDISources.isEmpty {
            return "Not Connected"
        }
        if midiEventsReceivedCount == 0 {
            return "\(selectedMIDIInputSourceName) · \(lastMIDICCMessage)"
        }
        return "\(selectedMIDIInputSourceName) · \(lastMIDIEventSummary)"
    }

    var midiCrossfaderMappingStatus: String {
        if let mapping = crossfaderCCMapping {
            return "Learned Xfader: \(mapping.displayName)"
        }
        return "Crossfader not learned"
    }

    func refreshMIDISources() {
        let discoveredSources = discoverMIDISources()
        midiSourceEndpoints = Dictionary(uniqueKeysWithValues: discoveredSources.map { ($0.choice, $0.endpoint) })
        let choices = discoveredSources.map(\.choice)
        availableMIDISources = choices
        availableMIDISourceNames = choices.map(\.name)
        selectedMIDIInputSourceID = MacCaptureEngine.resolveMIDISourceSelectionID(
            currentSelectionID: selectedMIDIInputSourceID,
            availableSources: choices
        )
        if selectedMIDIInputSourceID.isEmpty {
            publishOnMainAsync(field: "midiListeningState") { [weak self] in
                guard let self, self.midiListeningState != "Not Connected" else { return }
                self.midiListeningState = "Not Connected"
            }
        }
        reconnectSelectedMIDIInput()
    }

    /// Monitors/records an already-classified CC event. This function must
    /// NEVER learn, persist, cancel, or change any mapping — the sole,
    /// action-aware learn consumer is `evaluateMIDILearnForCC`, called
    /// earlier in the packet-parsing loop; its result determines
    /// `mappedControl` and `consumedByLearn` before this function ever runs.
    func recordReceivedMIDICCEvent(
        sourceName: String,
        channel: Int,
        controller: Int,
        value: Int,
        mappedControl: String? = nil,
        timestamp: Double = CACurrentMediaTime(),
        recordingStartTime: CFTimeInterval? = nil,
        consumedByLearn: Bool = false
    ) {
        midiCaptureLock.lock()
        let effectiveMapping = persistedCrossfaderMapping
        midiCaptureLock.unlock()

        let effectiveMappedControl = mappedControl
            ?? ((effectiveMapping?.channel == channel && effectiveMapping?.controller == controller) ? "crossfader" : nil)
        let normalizedValue = Double(value) / 127.0
        // Rane ONE MK2 pad candidate labelling — diagnostic only; no routing, no scoring.
        let padLabel = RaneOneMK2PadCandidateLabeler.label(channel: channel, cc: controller, value: value)
        let summary: String
        let ccMessage: String
        if let padLabel {
            summary = padLabel
            ccMessage = "CC\(controller) Ch\(channel + 1) Value\(value)"
        } else {
            summary = "Received CC\(controller) Ch\(channel + 1) Value\(value)"
            ccMessage = "CC\(controller) Ch\(channel + 1) Value\(value)"
        }

        // Gated pad-to-sample preview — diagnostic only; no scoring, no routing.
        if let sampleID = ScratchBankPadEventRouter.sampleID(
            channel: channel, cc: controller, value: value,
            isEnabled: isScratchBankMIDIPreviewEnabled
        ) {
            scratchBankPadPreviewCallback?(sampleID)
        }

        // Production hot-cue auto-load: resolve CC pad events through the learned device
        // mapping. Not gated behind isScratchBankMIDIPreviewEnabled — that toggle is a
        // DEBUG-only diagnostic preview switch, unrelated to the production hot-cue
        // mapping/load feature, which must work in Release too.
        // Skipped when this exact event was just consumed by MIDI Learn — a control
        // being (re-)learned must never also fire a stale/colliding hot-cue load on
        // the same physical press. Also skipped entirely for CC addresses with no
        // learned hot-cue action at all (routing-boundary fix, 2026-08-14) — see
        // `isHotCueCandidate`'s doc comment; a continuous CC stream (fader, platter)
        // must never enter the hot-cue resolver just to immediately no-op.
        if !consumedByLearn, isHotCueCandidate(messageType: .controlChange, channel: channel, controlNumber: controller) {
            _ = resolveAndLoadHotCueSample(messageType: .controlChange, channel: channel, controlNumber: controller, value: value)
        }

        // Scratch bank pad monitor label — diagnostic only; no scoring, no routing.
        // Updated on every recognised pad CC (press or release) at full fidelity.
        // The monitor UI reads this @Published property independently of the
        // throttled summary/counter path.
        if let compactLabel = Self.compactScratchBankPadLabel(
            channel: channel, cc: controller, value: value,
            isPreviewEnabled: isScratchBankMIDIPreviewEnabled
        ) {
            publishOnMainAsync(field: "lastScratchBankPadLabel") { [weak self] in
                self?.lastScratchBankPadLabel = compactLabel
            }
        }

        // Throttle @Published UI-monitor updates to a bounded ~4 Hz —
        // unconditionally; Learn mode must never disable this. At most one
        // coalesced publish is ever pending on main: if one is already
        // queued, this event's data is simply folded into the next batch
        // (`isMidiMonitorPublishPending` gates re-entry) instead of queuing
        // another `DispatchQueue.main.async`. The queued block re-reads the
        // batched state at execution time, so it always publishes the
        // newest values even if more events arrived while it waited.
        // Full-fidelity MIDI capture (capturedMidiCCEvents + debug counters)
        // is never throttled — only the SwiftUI-facing string/counter
        // properties are rate-limited to avoid flooding the main actor.
        let now = CACurrentMediaTime()
        midiCaptureLock.lock()
        batchedMidiEventCount += 1
        batchedMidiCCMessage = ccMessage
        batchedMidiSummary = summary
        // When live input is suspended for Review, skip UI monitor updates
        // unless a recording is active (recording capture is never suspended).
        // MIDI events still flow to capturedMidiCCEvents at full fidelity.
        let suspendedForReview = isLiveInputSuspendedForReview && !isRoutineRecording
        let shouldPublish = !suspendedForReview
            && !isMidiMonitorPublishPending
            && (now - lastMidiMonitorPublishTime >= midiMonitorPublishInterval)
        if shouldPublish {
            lastMidiMonitorPublishTime = now
            isMidiMonitorPublishPending = true
        }
        midiCaptureLock.unlock()

        if shouldPublish {
            publishOnMainAsync(field: "midiMonitor") { [weak self] in
                guard let self else { return }
                self.midiCaptureLock.lock()
                let count = self.batchedMidiEventCount
                self.batchedMidiEventCount = 0
                let latestCC = self.batchedMidiCCMessage
                let latestSummary = self.batchedMidiSummary
                self.isMidiMonitorPublishPending = false
                self.midiCaptureLock.unlock()

                self.midiEventsReceivedCount += count
                self.lastMIDICCMessage = latestCC
                self.lastMIDIEventSummary = latestSummary
                // Avoid identical-value @Published writes — each one triggers
                // objectWillChange.send(), which SwiftUI flags as "Modifying
                // state during view update" when it lands inside an active
                // update transaction.  This path fires at up to 4 Hz during
                // active controller input; "Listening" → "Listening" is the
                // overwhelming majority case.
                if self.midiListeningState != "Listening" {
                    self.midiListeningState = "Listening"
                }
                // Re-check state fresh here rather than using a snapshot
                // captured before dispatch: `applyLearnedCrossfaderMapping`
                // (called earlier in this same event when listening) queues
                // its own main-actor publish that sets `midiLearnState = .learned(...)`
                // and the correct "Learned Xfader: ..." feedback first. Using a
                // stale snapshot here would unconditionally overwrite that with the
                // generic "Received CC..." summary on the very event that just
                // committed the mapping; the fresh re-check correctly no-ops once
                // the learn has already landed.
                if self.midiLearnState == .listening, self.midiLearnFeedback != latestSummary {
                    self.midiLearnFeedback = latestSummary
                }
                self.testOnly_midiMonitorPublishCount += 1
            }
        }

        let startTime = recordingStartTime ?? midiRecordingStartTime
        guard startTime > 0 else { return }

        let event = CaptureCore.RawMixerMIDIEvent(
            timestamp: timestamp,
            takeRelativeTime: max(0, timestamp - startTime),
            deviceName: sourceName,
            channel: channel,
            controller: controller,
            value: value,
            normalizedValue: normalizedValue,
            mappedControl: effectiveMappedControl
        )
        midiCaptureLock.lock()
        capturedMidiCCEvents.append(event)
        #if DEBUG
        debugMidiEventsCapturedThisTake += 1
        #endif
        midiCaptureLock.unlock()
    }

    static func resolveMIDISourceSelectionID(
        currentSelectionID: String,
        availableSources: [MIDIInputSourceChoice]
    ) -> String {
        guard !availableSources.isEmpty else { return "" }
        if availableSources.contains(where: { $0.id == currentSelectionID }) {
            return currentSelectionID
        }
        if let iacBus = availableSources.first(where: { $0.name == "IAC Driver Bus 1" }) {
            return iacBus.id
        }
        return availableSources.first?.id ?? ""
    }

    /// Resolves the device identity used to decode right-platter CC6 telemetry.
    ///
    /// The app's ACTUALLY SELECTED MIDI source is the only authoritative device
    /// — never "whichever device happened to emit the first channel-1 CC6
    /// event" (arrival-order nondeterministic, and it silently mixes devices).
    /// Returns `nil` when the selected source is unavailable, or did not itself
    /// emit right-platter CC6, so a mixed / mis-routed stream fails closed
    /// instead of decoding another device's (or the other deck's) ring counter.
    static func platterDeviceNameForDecode(
        selectedMIDISourceName: String,
        capturedMidi: [CaptureCore.RawMixerMIDIEvent]
    ) -> String? {
        let name = selectedMIDISourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Not Connected" else { return nil }
        guard capturedMidi.contains(where: {
            $0.deviceName == name && $0.controller == 6 && $0.channel == 1
        }) else {
            return nil
        }
        return name
    }

    /// Finalization-routing helper: decode right-platter CC6 telemetry into
    /// movement events, FAILING CLOSED when the selected MIDI source is absent
    /// or did not itself emit CC6.
    ///
    /// This is the exact helper `completeRoutineFinalization` uses. It must
    /// never pass a nil device name into `derivePlatterMovementEvents`, because
    /// a nil device disables that decoder's device filter and would accept
    /// every channel-1 CC6 device (including another controller / deck).
    static func resolvedControllerMovementEvents(
        selectedMIDISourceName: String,
        capturedMidi: [CaptureCore.RawMixerMIDIEvent]
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        guard let deviceName = platterDeviceNameForDecode(
            selectedMIDISourceName: selectedMIDISourceName,
            capturedMidi: capturedMidi
        ) else {
            return []
        }
        return CaptureCore.derivePlatterMovementEvents(
            from: capturedMidi, controller: 6, channel: 1, deviceName: deviceName)
    }

    /// Live/provisional counterpart to `resolvedControllerMovementEvents`,
    /// used by `LivePerformedNotationTracker`. Same fail-closed device
    /// resolution, same controller/channel filter, same decode core — the
    /// only difference is the trailing open stroke is returned separately
    /// instead of being force-closed into a committed event. Never used by
    /// `completeRoutineFinalization`.
    static func resolvedControllerMovementEventsWithProvisional(
        selectedMIDISourceName: String,
        capturedMidi: [CaptureCore.RawMixerMIDIEvent]
    ) -> CaptureCore.PlatterMovementDecodeResult {
        guard let deviceName = platterDeviceNameForDecode(
            selectedMIDISourceName: selectedMIDISourceName,
            capturedMidi: capturedMidi
        ) else {
            return CaptureCore.PlatterMovementDecodeResult(committedEvents: [], provisionalMovement: nil)
        }
        return CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: capturedMidi, controller: 6, channel: 1, deviceName: deviceName)
    }

    // MARK: - Scratch Bank Pad Monitor Label

    /// Builds a compact human-readable label for a scratch bank pad CC event.
    ///
    /// - Returns: A label like `"Deck 1 Pad 1 → ahhh · played"`,
    ///   `"Deck 1 Pad 1 → ahhh · gated"`, or `"Deck 1 Pad 1 · (no sample)"`,
    ///   or `nil` if the (channel, cc) pair is not a recognised Rane pad CC.
    ///
    /// Pad mapping (Rane ONE MK2 large pads, hot-cue mode):
    /// - Deck 1: ch4 CC20–27  → pads 1–8
    /// - Deck 2: ch5 CC20–27  → pads 1–8
    static func compactScratchBankPadLabel(
        channel: Int, cc: Int, value: Int,
        isPreviewEnabled: Bool
    ) -> String? {
        // Only channel 4 or 5.
        guard channel == 4 || channel == 5 else { return nil }
        // Only large-pad CC range 20–27.
        guard cc >= 20, cc <= 27 else { return nil }
        // Ignore release (value 0).
        guard value > 0 else { return nil }

        let deck = channel - 3  // ch4 → 1, ch5 → 2
        let pad = cc - 20 + 1   // CC20 → pad 1, CC27 → pad 8

        let sampleID = ScratchBankPadEventRouter.sampleID(
            channel: channel, cc: cc, value: value,
            isEnabled: true // resolve mapping regardless of gate for monitor display
        )

        if let sampleID {
            let status = isPreviewEnabled ? "played" : "gated"
            return "Deck \(deck) Pad \(pad) → \(sampleID) · \(status)"
        } else {
            return "Deck \(deck) Pad \(pad) · (no sample)"
        }
    }

    // MARK: - Scratch Bank Note Pad Monitor Label

    /// Builds a compact label for a confirmed Rane ONE MK2 Note On pad event.
    ///
    /// Confirmed hardware: ch5/ch6 in MIDI Monitor (channels 4/5, 0-indexed), notes 20–27.
    /// Label format: `"Deck N Pad N → sampleID · played"` / `"· gated"` / `"· (no sample)"`.
    /// Returns nil for Note Off (velocity 0), wrong channel, or out-of-range note.
    static func compactScratchBankNotePadLabel(
        channel: Int, noteNumber: Int, velocity: Int,
        isPreviewEnabled: Bool
    ) -> String? {
        guard channel == 4 || channel == 5 else { return nil }
        guard noteNumber >= 20, noteNumber <= 27 else { return nil }
        guard velocity > 0 else { return nil }

        let deck = channel - 3  // ch4 → 1, ch5 → 2
        let padNumber = noteNumber - 20 + 1
        let sampleID = ScratchBankPadEventRouter.sampleID(
            channel: channel, noteNumber: noteNumber, velocity: velocity,
            isEnabled: true
        )
        if let sampleID {
            let status = isPreviewEnabled ? "played" : "gated"
            return "Deck \(deck) Pad \(padNumber) → \(sampleID) · \(status)"
        } else {
            return "Deck \(deck) Pad \(padNumber) · (no sample)"
        }
    }

    // MARK: - Note On Pad Preview

    /// Routes a Note On event through the Scratch Bank pad preview and monitor label path.
    /// Called from `receiveMIDIPacketList` for every Note On byte received.
    /// Also usable as a test seam — callers inject channel/noteNumber/velocity directly.
    func receiveNoteOnPadEvent(channel: Int, noteNumber: Int, velocity: Int) {
        guard velocity > 0 else { return }

        // MIDI Learn: atomically claims and ends a hot-cue session if one is
        // active and matches; returns false (and falls through) otherwise.
        if learnHotCueFromNote(channel: channel, noteNumber: noteNumber) {
            return
        }

        print("[RanePad] TEMP diagnostic note received · channel=\(channel) note=\(noteNumber) velocity=\(velocity)")
        let routedSampleID = ScratchBankPadEventRouter.sampleID(
            channel: channel, noteNumber: noteNumber, velocity: velocity,
            isEnabled: isScratchBankMIDIPreviewEnabled
        )
        if let sampleID = routedSampleID {
            scratchBankPadPreviewCallback?(sampleID)
        }

        // Production hot-cue auto-load: resolve Note On events through the learned device
        // mapping. Not gated behind isScratchBankMIDIPreviewEnabled — see CC path above.
        // Skipped entirely for notes with no learned hot-cue action at all
        // (routing-boundary fix, 2026-08-14) — see `isHotCueCandidate`'s doc
        // comment; `productionMatched` below reuses the same check rather than
        // scanning `currentMIDIDeviceMapping` twice.
        let productionMatched = isHotCueCandidate(messageType: .note, channel: channel, controlNumber: noteNumber)
        if productionMatched {
            _ = resolveAndLoadHotCueSample(messageType: .note, channel: channel, controlNumber: noteNumber, value: velocity)
        }

        // TEMP HARDWARE DIAGNOSTIC: direct-load dvs_ahhh for captured Rane hot cue
        // notes while keeping the existing ch4/ch5 fallback active during hardware
        // proofing. This fires only when the production hot-cue path above did NOT
        // resolve a sample. Loads `dvs_ahhh`, not the legacy raw `ahhh` — product
        // decision 2026-08-14: dvs_ahhh is the only user-facing "Ahh" sample.
        // DEBUG-only (2026-08-21 crash-hardening pass): this is a hardware-proofing
        // bootstrap for devices that have not yet been through MIDI Learn — the
        // supported, documented flow is the learned-mapping path above. Compiled
        // out of Release so it can never silently auto-trigger playback for an
        // end user on an unconfigured device; still available in Debug builds for
        // Karl's own hardware testing.
        #if DEBUG
        let isTemporaryAhhhFallback =
            ((channel == 4 || channel == 5) && (noteNumber == 20 || noteNumber == 24)) ||
            (channel == 6 && noteNumber == 20)
        if isTemporaryAhhhFallback,
           routedSampleID == nil,
           !productionMatched,
           allowsLocalScratchPlayback {
            print("[RanePad] TEMP diagnostic direct load · sampleID=dvs_ahhh channel=\(channel) note=\(noteNumber) velocity=\(velocity)")
            scratchPlaybackController.load(sampleID: "dvs_ahhh", playDiagnosticPreview: false)
            testOnly_hotCueLoadObserver?("dvs_ahhh")
        }
        #endif
        if let label = Self.compactScratchBankNotePadLabel(
            channel: channel, noteNumber: noteNumber, velocity: velocity,
            isPreviewEnabled: isScratchBankMIDIPreviewEnabled
        ) {
            publishOnMainAsync(field: "lastScratchBankPadLabel") { [weak self] in
                self?.lastScratchBankPadLabel = label
            }
        }
    }

    // TEMP HARDWARE DIAGNOSTIC: one clean proof path from known-good Rane CC8
    // input into platter-owned sample playback, bypassing pad routing/gates.
    // Loads `dvs_ahhh`, not the legacy raw `ahhh` — product decision 2026-08-14:
    // dvs_ahhh is the only user-facing "Ahh" sample.
    private func handleTemporaryDirectAhhhTrigger(rawValue: Int) {
        guard allowsLocalScratchPlayback else { return }
        if rawValue > 120, tempDirectAhhhTriggerArmed {
            tempDirectAhhhTriggerArmed = false
            print("[ScratchSamplePlaybackBridge] TEMP direct ahhh trigger fired · source=cc8 raw=\(rawValue)")
            scratchPlaybackController.load(sampleID: "dvs_ahhh", playDiagnosticPreview: false)
        } else if rawValue < 20, !tempDirectAhhhTriggerArmed {
            tempDirectAhhhTriggerArmed = true
            print("[ScratchSamplePlaybackBridge] TEMP direct ahhh trigger reset · source=cc8 raw=\(rawValue)")
        }
    }

    private func reconnectSelectedMIDIInput() {
        guard midiInputPort != 0 else { return }
        closeMIDIInput()
        guard let selectedSource = availableMIDISources.first(where: { $0.id == selectedMIDIInputSourceID }),
              let endpoint = midiSourceEndpoints[selectedSource] else {
            publishOnMainAsync(field: "midiListeningState") { [weak self] in
                guard let self else { return }
                let next = self.availableMIDISources.isEmpty ? "Not Connected" : "Source Missing"
                if self.midiListeningState != next { self.midiListeningState = next }
            }
            return
        }

        midiCaptureLock.lock()
        midiConnectedSourceName = selectedSource.name
        midiCaptureLock.unlock()
        MIDIPortConnectSource(midiInputPort, endpoint, nil)
        // Load any saved device mapping for this source.
        loadDeviceMappingForCurrentSource()
        publishOnMainAsync(field: "midiListeningState") { [weak self] in
            guard let self, self.midiListeningState != "Listening" else { return }
            self.midiListeningState = "Listening"
        }
    }

    private func resetMIDIMonitoringState() {
        midiCaptureLock.lock()
        batchedMidiEventCount = 0
        batchedMidiCCMessage = ""
        batchedMidiSummary = "No MIDI received yet"
        lastMidiMonitorPublishTime = 0
        pendingControllerActivity = PendingControllerActivity()
        isControllerActivityPublishPending = false
        midiCaptureLock.unlock()
        publishOnMainAsync(field: "midiMonitorReset") { [weak self] in
            guard let self else { return }
            self.midiEventsReceivedCount = 0
            self.lastMIDIEventSummary = "No MIDI received yet"
            self.lastMIDICCMessage = "CC -- Ch -- Value --"
            if self.midiLearnFeedback != "" { self.midiLearnFeedback = "" }
            self.midiLearnObservedRawValue = nil
            self.lastScratchBankPadLabel = ""
            self.liveCrossfaderRawValue = nil
            self.liveLeftUpfaderRawValue = nil
            self.liveRightUpfaderRawValue = nil
            self.liveHotCueIndex = nil
            self.liveHotCueSampleID = nil
            self.leftUpfaderOutputGain = 1.0
            self.leftUpfaderOutputHandler?(1.0)
#if DEBUG
            self.lastRawPadDiagnostic = ""
#endif
        }
    }

    private struct MIDISourceEndpoint {
        let choice: MIDIInputSourceChoice
        let endpoint: MIDIEndpointRef
    }

    private func discoverMIDISources() -> [MIDISourceEndpoint] {
        var sources: [MIDISourceEndpoint] = []
        let sourceCount = MIDIGetNumberOfSources()
        guard sourceCount > 0 else { return sources }

        for index in 0..<sourceCount {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            var unmanagedName: Unmanaged<CFString>?
            let propertyStatus = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
            let trimmedName = (propertyStatus == noErr ? unmanagedName?.takeRetainedValue() as String? : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var uniqueID = MIDIUniqueID(0)
            let uniqueIDStatus = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            let sourceID = uniqueIDStatus == noErr ? "midi_\(uniqueID)" : "endpoint_\(endpoint)"

            if let trimmedName, !trimmedName.isEmpty {
                sources.append(
                    MIDISourceEndpoint(
                        choice: MIDIInputSourceChoice(id: sourceID, name: trimmedName),
                        endpoint: endpoint
                    )
                )
            }
        }

        return sources.sorted { lhs, rhs in
            lhs.choice.name.localizedCaseInsensitiveCompare(rhs.choice.name) == .orderedAscending
        }
    }

    /// Returns true when the hand would need to travel faster than `maxVelocity`
    /// normalised image-units per second to reach `to` from `from` in `elapsed`
    /// seconds. Rejects Vision noise spikes before they contaminate the platter
    /// timeline or direction tracker. Tested via `VisionCaptureGateTests`.
    static func isImpossibleHandJump(
        from: CGPoint,
        to: CGPoint,
        elapsed: TimeInterval,
        maxVelocity: Double = 4.5
    ) -> Bool {
        guard elapsed > 0 else { return false }
        let dx = abs(Double(to.x) - Double(from.x))
        return (dx / elapsed) > maxVelocity
    }

    #if DEBUG
    /// Snapshot of detection counters for in-session debugging.
    struct DebugStats {
        let framesReceived: Int
        let framesAnalyzed: Int
        let handObservationsFound: Int
        let directionChanges: Int
        let missedFrames: Int
        let visionReturnedHand: Int
        let trackedPointReturnedNil: Int
        let trackedPointReturnedPoint: Int
        let jointsInspectedTotal: Int
        let jointsRejectedLowConfidence: Int
        let jointsRejectedOutsideROI: Int
        let jointsAcceptedCandidates: Int
        let jointsRelaxedAccepted: Int
        let continuityFilledSamples: Int
        let impossibleJumpRejects: Int
        let jointConfidenceThreshold: Float
        let observeSkippedNotRecording: Int
        let observeAttempted: Int
        let midiEventsCapturedThisTake: Int
        let rawEndTimeEqualsStart: Int
        let rawMovementEventsCreated: Int
        let normalizedMovementCount: Int
        let fusedMovementCount: Int
        let trustedDirectionalCount: Int
        let finalRecordMovementCount: Int
        let trustDropNotFused: Int
        let trustDropLowConfidence: Int
        let trustDropLowAudioOverlap: Int
        let notationSource: String
        let currentROI: CGRect
        let audioScratchCount: Int
        // Movement funnel counters (from RoutineMovementDiagnosticsSnapshot)
        let builderInputAccepted: Int
        let builderInputRejectedDirection: Int
        let builderRejectedSteady: Int
        let builderRejectedSearching: Int
        let steadyInsufficientHistory: Int
        let steadyDisplacementTooSmall: Int
        let steadyVelocityTooLow: Int
        let builderInputExtended: Int
        let publishHandTrackingCalls: Int
        let publishHandTrackingDedupSkips: Int
        let activeMovementStarts: Int
        let activeMovementFinishAttempts: Int
        let mergedSegments: Int
        let builderSamplesReceived: Int
        let rawDropReasons: [String: Int]
        let normalizedDropReasons: [String: Int]
        let trustDropReasons: [String: Int]
        let platterObserveFromSession: Int
        let platterObserveSkippedFromSession: Int
        let impossibleJumpFromSession: Int
        // Direction tracker displacement/velocity distribution
        let displacementAbsMin: Double
        let displacementAbsMax: Double
        let velocityAbsMin: Double
        let velocityAbsMax: Double
        let dispBucketBelow002: Int
        let dispBucket002to005: Int
        let dispBucket005to010: Int
        let dispBucket010to020: Int
        let dispBucketAbove020: Int
        let velBucketBelow003: Int
        let velBucket003to006: Int
        let velBucket006to010: Int
        let velBucket010to020: Int
        let velBucketAbove020: Int
        let historyCount1: Int
        let historyCount2: Int
        let historyCount3: Int
        let historyCount4: Int
        // Direction tracker commit-latency diagnostics
        let trackerRawDirectionAppearedMoving: Int
        let trackerCommittedDirectionChanges: Int
        let trackerPendingResetBeforeCommit: Int
        let trackerCommitLatency1: Int
        let trackerCommitLatency2: Int
        let trackerCommitLatency3Plus: Int
        let trackedXMin: Double
        let trackedXMax: Double
        let trackedYMin: Double
        let trackedYMax: Double
        let replaySourceLabel: String
        /// Number of events trusted through the deterministic replay
        /// path (always zero for live captures).
        let replaySourceTrusted: Int
    }

    func captureDebugStats() -> DebugStats {
        let midiCount = midiCaptureLock.withLock { debugMidiEventsCapturedThisTake }
        let diag = routineMovementDiagnostics
        return DebugStats(
            framesReceived: debugFramesReceived,
            framesAnalyzed: debugFramesAnalyzed,
            handObservationsFound: debugHandObservationsFound,
            directionChanges: debugDirectionChanges,
            missedFrames: debugMissedFrameCount,
            visionReturnedHand: debugVisionReturnedHand,
            trackedPointReturnedNil: debugTrackedPointReturnedNil,
            trackedPointReturnedPoint: debugTrackedPointReturnedPoint,
            jointsInspectedTotal: debugJointsInspectedTotal,
            jointsRejectedLowConfidence: debugJointsRejectedLowConfidence,
            jointsRejectedOutsideROI: debugJointsRejectedOutsideROI,
            jointsAcceptedCandidates: debugJointsAcceptedCandidates,
            jointsRelaxedAccepted: debugJointsRelaxedAccepted,
            continuityFilledSamples: debugContinuityFilledSamples,
            impossibleJumpRejects: debugImpossibleJumpRejects,
            jointConfidenceThreshold: isRoutineRecording ? recordingJointConfidenceThreshold : standardJointConfidenceThreshold,
            observeSkippedNotRecording: debugObserveSkippedNotRecording,
            observeAttempted: debugObserveAttempted,
            midiEventsCapturedThisTake: midiCount,
            rawEndTimeEqualsStart: diag?.rawDropReasons["endTimeEqualsStart"] ?? 0,
            rawMovementEventsCreated: diag?.rawMovementEventsCreated ?? 0,
            normalizedMovementCount: diag?.normalizedMovementEvents ?? 0,
            fusedMovementCount: diag?.fusedMovementEvents ?? 0,
            trustedDirectionalCount: diag?.trustedDirectionalEvents ?? 0,
            finalRecordMovementCount: diag?.finalRecordMovementEvents ?? 0,
            trustDropNotFused: diag?.trustDropReasons["notFused"] ?? 0,
            trustDropLowConfidence: diag?.trustDropReasons["lowConfidence"] ?? 0,
            trustDropLowAudioOverlap: diag?.trustDropReasons["lowAudioOverlap"] ?? 0,
            notationSource: lastRoutineDetectedNotation?.notationSource ?? "none",
            currentROI: debugLastROI,
            audioScratchCount: scratchDetectionCount,
            builderInputAccepted: diag?.builderInputAccepted ?? 0,
            builderInputRejectedDirection: diag?.builderInputRejectedDirection ?? 0,
            builderRejectedSteady: diag?.builderRejectedSteady ?? 0,
            builderRejectedSearching: diag?.builderRejectedSearching ?? 0,
            steadyInsufficientHistory: diag?.steadyInsufficientHistory ?? 0,
            steadyDisplacementTooSmall: diag?.steadyDisplacementTooSmall ?? 0,
            steadyVelocityTooLow: diag?.steadyVelocityTooLow ?? 0,
            builderInputExtended: diag?.builderInputExtended ?? 0,
            publishHandTrackingCalls: diag?.publishHandTrackingCalls ?? 0,
            publishHandTrackingDedupSkips: diag?.publishHandTrackingDedupSkips ?? 0,
            activeMovementStarts: diag?.activeMovementStarts ?? 0,
            activeMovementFinishAttempts: diag?.activeMovementFinishAttempts ?? 0,
            mergedSegments: diag?.mergedSegments ?? 0,
            builderSamplesReceived: diag?.builderSamplesReceived ?? 0,
            rawDropReasons: diag?.rawDropReasons ?? [:],
            normalizedDropReasons: diag?.normalizedDropReasons ?? [:],
            trustDropReasons: diag?.trustDropReasons ?? [:],
            platterObserveFromSession: diag?.platterObserveAttempted ?? 0,
            platterObserveSkippedFromSession: diag?.platterObserveSkippedNotRecording ?? 0,
            impossibleJumpFromSession: diag?.impossibleJumpRejects ?? 0,
            displacementAbsMin: handDirectionTracker.displacementAbsMin.isFinite ? Double(handDirectionTracker.displacementAbsMin) : 0,
            displacementAbsMax: Double(handDirectionTracker.displacementAbsMax),
            velocityAbsMin: handDirectionTracker.velocityAbsMin.isFinite ? Double(handDirectionTracker.velocityAbsMin) : 0,
            velocityAbsMax: Double(handDirectionTracker.velocityAbsMax),
            dispBucketBelow002: handDirectionTracker.dispBucketBelow002,
            dispBucket002to005: handDirectionTracker.dispBucket002to005,
            dispBucket005to010: handDirectionTracker.dispBucket005to010,
            dispBucket010to020: handDirectionTracker.dispBucket010to020,
            dispBucketAbove020: handDirectionTracker.dispBucketAbove020,
            velBucketBelow003: handDirectionTracker.velBucketBelow003,
            velBucket003to006: handDirectionTracker.velBucket003to006,
            velBucket006to010: handDirectionTracker.velBucket006to010,
            velBucket010to020: handDirectionTracker.velBucket010to020,
            velBucketAbove020: handDirectionTracker.velBucketAbove020,
            historyCount1: handDirectionTracker.historyCount1,
            historyCount2: handDirectionTracker.historyCount2,
            historyCount3: handDirectionTracker.historyCount3,
            historyCount4: handDirectionTracker.historyCount4,
            trackerRawDirectionAppearedMoving: handDirectionTracker.rawDirectionAppearedMoving,
            trackerCommittedDirectionChanges: handDirectionTracker.committedDirectionChanges,
            trackerPendingResetBeforeCommit: handDirectionTracker.pendingRawDirectionResetBeforeCommit,
            trackerCommitLatency1: handDirectionTracker.commitLatency1,
            trackerCommitLatency2: handDirectionTracker.commitLatency2,
            trackerCommitLatency3Plus: handDirectionTracker.commitLatency3Plus,
            trackedXMin: handDirectionTracker.trackedPointXMin.isFinite ? Double(handDirectionTracker.trackedPointXMin) : 0,
            trackedXMax: Double(handDirectionTracker.trackedPointXMax),
            trackedYMin: handDirectionTracker.trackedPointYMin.isFinite ? Double(handDirectionTracker.trackedPointYMin) : 0,
            trackedYMax: Double(handDirectionTracker.trackedPointYMax),
            replaySourceLabel: "live",
            replaySourceTrusted: 0
        )
    }

    static func summarizeDebugCounters(_ counters: [String: Int]) -> String {
        guard !counters.isEmpty else { return "none" }
        return counters
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    /// DEBUG synthetic replay: replays the last drained platter-position
    /// timeline through a fresh direction-tracker → builder → normalizer →
    /// fusion pipeline and populates `frozenReviewDiagnostics`.
    ///
    /// Fidelity (direction diagnosis): **identical**.
    /// `PlatterPositionRecorder.observe` stores
    /// `position[i] = Σ(rawTrackedPoint.x[j] - rawTrackedPoint.x[j-1])`.
    /// The direction tracker computes `dx = position[i] - position[i-1]`
    /// = `rawTrackedPoint.x[i] - rawTrackedPoint.x[i-1]`, identical to the
    /// live pass. Timestamps are take-relative; `dt` is identical.
    /// Velocity, displacement, committed direction, and steady-idle reasons
    /// are thus identical to the live-capture pass.
    ///
    /// NOT identical (confidence, dedup, y-axis):
    /// - Confidence: platter records `1.0`; the replay uses tracker-derived
    ///   confidence which may differ from the live `publishHandTrackingIfNeeded`
    ///   path. This affects normalization confidence-drop rates.
    /// - Y-axis: not persisted in the platter timeline; stubbed at `0.5`.
    ///   HandDirectionTracker only uses `dx` (not `dy`), so direction is
    ///   unaffected, but builder position depends on x only.
    /// - Publish dedup: every sample feeds the builder (live may skip
    ///   unchanged state/position pairs via `publishHandTrackingIfNeeded`).
    /// - Audio: no audio events in replay (normalization has no burst rescue).
    ///   `normDrops` and `trustDrops` may differ from live.
    ///
    /// Thresholds are unchanged. No capture/ROI/notation behaviour changes.
    @discardableResult
    func replayDiagnosticsFromPlatterTimeline() -> DebugStats? {
        // Try in-memory timeline first, then disk-saved raw platter timeline.
        let timeline: PlatterPositionTimeline?
        if let mem = lastDrainedPlatterPositionTimeline, !mem.samples.isEmpty {
            timeline = mem
        } else if let loaded = Self.loadLatestSavedPlatterTimeline() {
            timeline = loaded
        } else {
            publishFrozenReviewDiagnostics(nil)
            return nil
        }
        guard let timeline, !timeline.samples.isEmpty else {
            publishFrozenReviewDiagnostics(nil)
            return nil
        }

        // Fresh pipeline — mirrors the live capture path.
        let tracker = HandDirectionTracker()
        let debugSession = RoutineMovementDebugSession(handPoseInterval: activeHandPoseInterval)
        let builder = RoutineDetectedNotationBuilder(
            startedAt: timeline.startTime,
            debugSession: debugSession
        )

        // Replay each sample through tracker → builder.
        // Tracker receives sample.position directly (identical dx/dt to live).
        // Builder receives a reconstructed [0,1] coordinate from cumulative
        // deltas since sample.position is integrated displacement, not an
        // absolute normalized hand-point x.
        var runningX: Double = 0.5
        var lastPlatterPosition: Double = timeline.samples.first?.position ?? 0
        for sample in timeline.samples {
            let delta = sample.position - lastPlatterPosition
            runningX += delta
            runningX = min(max(runningX, 0), 1)
            lastPlatterPosition = sample.position

            let trackerPoint = CGPoint(x: sample.position, y: 0.5)
            let builderPoint = CGPoint(x: runningX, y: 0.5)
            let now = sample.time

            let direction = tracker.recordObservation(rawPoint: trackerPoint, at: now)
            let movementState = handMotionState(from: direction)

            // Mirror live debugging: record samples + direction changes.
            debugSession.recordSample(
                rawPoint: trackerPoint,
                displayedPoint: builderPoint,
                confidence: Double(tracker.confidence),
                rawDirection: direction,
                semanticState: movementState
            )

            // Record steady-idle reason from replay tracker.
            if movementState == .steady {
                debugSession.recordSteadyIdleReason(tracker.lastIdleReason)
            }

            // Feed builder (no dedup — every sample, synthetic path).
            builder.recordObservation(
                state: movementState,
                position: runningX,
                confidence: Double(tracker.confidence),
                now: now
            )
        }

        // Drain builder + normalize (no audio events in replay).
        let rawEvents = builder.movementEvents(now: timeline.endTime)
        let normalizer = RoutineNotationEventNormalizer()
        _ = normalizer.normalize(
            events: rawEvents,
            audioEvents: [],
            debugSession: debugSession
        )
        let fusionEngine = RoutineNotationFusionEngine()
        _ = fusionEngine.snapshot(
            audioSnapshot: ScratchAudioNotationSnapshot(audioEvents: [], confidence: nil),
            motionEvents: rawEvents,
            detectedLabel: lastScratchDetection?.scratchName,
            labelSource: lastScratchDetection == nil ? "unknown" : "detected",
            labelConfidence: lastScratchDetection?.confidence,
            debugSession: debugSession,
            isReplaySource: true
        )

        // Populate frozenReviewDiagnostics from replay output.
        let diag = debugSession.snapshot()
        let stats = DebugStats(
            framesReceived: diag.handObservationsReceived,
            framesAnalyzed: diag.handObservationsReceived,
            handObservationsFound: diag.handObservationsReceived,
            directionChanges: diag.semanticDirectionChanges,
            missedFrames: 0,
            visionReturnedHand: diag.handObservationsReceived,
            trackedPointReturnedNil: 0,
            trackedPointReturnedPoint: diag.handObservationsReceived,
            jointsInspectedTotal: 0,
            jointsRejectedLowConfidence: 0,
            jointsRejectedOutsideROI: 0,
            jointsAcceptedCandidates: 0,
            jointsRelaxedAccepted: 0,
            continuityFilledSamples: 0,
            impossibleJumpRejects: 0,
            jointConfidenceThreshold: recordingJointConfidenceThreshold,
            observeSkippedNotRecording: 0,
            observeAttempted: diag.handObservationsReceived,
            midiEventsCapturedThisTake: 0,
            rawEndTimeEqualsStart: diag.rawDropReasons["endTimeEqualsStart"] ?? 0,
            rawMovementEventsCreated: diag.rawMovementEventsCreated,
            normalizedMovementCount: diag.normalizedMovementEvents,
            fusedMovementCount: diag.fusedMovementEvents,
            trustedDirectionalCount: diag.trustedDirectionalEvents,
            finalRecordMovementCount: diag.finalRecordMovementEvents,
            trustDropNotFused: diag.trustDropReasons["notFused"] ?? 0,
            trustDropLowConfidence: diag.trustDropReasons["lowConfidence"] ?? 0,
            trustDropLowAudioOverlap: diag.trustDropReasons["lowAudioOverlap"] ?? 0,
            notationSource: lastRoutineDetectedNotation?.notationSource ?? "replay:platterSynthetic",
            currentROI: debugLastROI,
            audioScratchCount: 0,
            builderInputAccepted: diag.builderInputAccepted,
            builderInputRejectedDirection: diag.builderInputRejectedDirection,
            builderRejectedSteady: diag.builderRejectedSteady,
            builderRejectedSearching: diag.builderRejectedSearching,
            steadyInsufficientHistory: diag.steadyInsufficientHistory,
            steadyDisplacementTooSmall: diag.steadyDisplacementTooSmall,
            steadyVelocityTooLow: diag.steadyVelocityTooLow,
            builderInputExtended: diag.builderInputExtended,
            publishHandTrackingCalls: diag.builderSamplesReceived,
            publishHandTrackingDedupSkips: 0,
            activeMovementStarts: diag.activeMovementStarts,
            activeMovementFinishAttempts: diag.activeMovementFinishAttempts,
            mergedSegments: diag.mergedSegments,
            builderSamplesReceived: diag.builderSamplesReceived,
            rawDropReasons: diag.rawDropReasons,
            normalizedDropReasons: diag.normalizedDropReasons,
            trustDropReasons: diag.trustDropReasons,
            platterObserveFromSession: timeline.samples.count,
            platterObserveSkippedFromSession: 0,
            impossibleJumpFromSession: 0,
            displacementAbsMin: tracker.displacementAbsMin.isFinite ? Double(tracker.displacementAbsMin) : 0,
            displacementAbsMax: Double(tracker.displacementAbsMax),
            velocityAbsMin: tracker.velocityAbsMin.isFinite ? Double(tracker.velocityAbsMin) : 0,
            velocityAbsMax: Double(tracker.velocityAbsMax),
            dispBucketBelow002: tracker.dispBucketBelow002,
            dispBucket002to005: tracker.dispBucket002to005,
            dispBucket005to010: tracker.dispBucket005to010,
            dispBucket010to020: tracker.dispBucket010to020,
            dispBucketAbove020: tracker.dispBucketAbove020,
            velBucketBelow003: tracker.velBucketBelow003,
            velBucket003to006: tracker.velBucket003to006,
            velBucket006to010: tracker.velBucket006to010,
            velBucket010to020: tracker.velBucket010to020,
            velBucketAbove020: tracker.velBucketAbove020,
            historyCount1: tracker.historyCount1,
            historyCount2: tracker.historyCount2,
            historyCount3: tracker.historyCount3,
            historyCount4: tracker.historyCount4,
            trackerRawDirectionAppearedMoving: tracker.rawDirectionAppearedMoving,
            trackerCommittedDirectionChanges: tracker.committedDirectionChanges,
            trackerPendingResetBeforeCommit: tracker.pendingRawDirectionResetBeforeCommit,
            trackerCommitLatency1: tracker.commitLatency1,
            trackerCommitLatency2: tracker.commitLatency2,
            trackerCommitLatency3Plus: tracker.commitLatency3Plus,
            trackedXMin: tracker.trackedPointXMin.isFinite ? Double(tracker.trackedPointXMin) : 0,
            trackedXMax: Double(tracker.trackedPointXMax),
            trackedYMin: tracker.trackedPointYMin.isFinite ? Double(tracker.trackedPointYMin) : 0,
            trackedYMax: Double(tracker.trackedPointYMax),
            replaySourceLabel: "replay:platterSynthetic",
            replaySourceTrusted: diag.replaySourceTrusted
        )
        publishFrozenReviewDiagnostics(stats)
        return stats
    }

    /// Load the most recent raw platter timeline saved at finalize time.
    /// Persist raw platter timeline + funnel diagnostic text alongside the
    /// sidecar so replay works after relaunch and diagnostics are inspectable.
    private func writeReplayDiagnosticsToDisk(diag: DebugStats?) {
        guard let sidecarURL = activeRoutineRecordingSidecarURL else { return }
        let baseName = sidecarURL.deletingPathExtension().lastPathComponent
        let dir = sidecarURL.deletingLastPathComponent()

        // Save raw platter timeline as Codable JSON.
        var platterWriteError: String? = nil
        if let tl = lastDrainedPlatterPositionTimeline {
            let platterURL = dir.appendingPathComponent("\(baseName)_raw_platter_timeline.json")
            do {
                try JSONEncoder().encode(tl).write(to: platterURL, options: .atomic)
            } catch {
                platterWriteError = error.localizedDescription
            }
        } else {
            platterWriteError = "lastDrainedPlatterPositionTimeline nil"
        }

        // Write human-readable funnel diagnostics.
        let label = diag?.replaySourceLabel ?? "nil"
        let rawDrops = diag?.rawDropReasons ?? [:]
        let normDrops = diag?.normalizedDropReasons ?? [:]
        let trustDrops = diag?.trustDropReasons ?? [:]
        let dvsNotationDiagnostics = timecodeNotationDiagnostics
        func dropStr(_ d: [String: Int]) -> String {
            d.isEmpty ? "none" : d.sorted(by: { $0.value > $1.value }).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        let lines = [
            "replay_executed=true",
            "platter_write_error=\(platterWriteError ?? "none")",
            "[source=\(label)]",
            "platterAttempted=\(diag?.platterObserveFromSession ?? 0) builderAcc=\(diag?.builderInputAccepted ?? 0) builderRej=\(diag?.builderInputRejectedDirection ?? 0) (steady=\(diag?.builderRejectedSteady ?? 0) searching=\(diag?.builderRejectedSearching ?? 0)) builderExt=\(diag?.builderInputExtended ?? 0)",
            "[steadyBreakdown] insufficientHistory=\(diag?.steadyInsufficientHistory ?? 0) displacementTooSmall=\(diag?.steadyDisplacementTooSmall ?? 0) velocityTooLow=\(diag?.steadyVelocityTooLow ?? 0)",
            "[dispDist] min=\(String(format: "%.4f", diag?.displacementAbsMin ?? 0)) max=\(String(format: "%.4f", diag?.displacementAbsMax ?? 0)) <2=\(diag?.dispBucketBelow002 ?? 0) 2-5=\(diag?.dispBucket002to005 ?? 0) 5-10=\(diag?.dispBucket005to010 ?? 0) 10-20=\(diag?.dispBucket010to020 ?? 0) >20=\(diag?.dispBucketAbove020 ?? 0)",
            "[velDist] min=\(String(format: "%.4f", diag?.velocityAbsMin ?? 0)) max=\(String(format: "%.4f", diag?.velocityAbsMax ?? 0)) <3=\(diag?.velBucketBelow003 ?? 0) 3-6=\(diag?.velBucket003to006 ?? 0) 6-10=\(diag?.velBucket006to010 ?? 0) 10-20=\(diag?.velBucket010to020 ?? 0) >20=\(diag?.velBucketAbove020 ?? 0)",
            "[trackedRange] x=[\(String(format: "%.4f", diag?.trackedXMin ?? 0)),\(String(format: "%.4f", diag?.trackedXMax ?? 0))] y=[\(String(format: "%.4f", diag?.trackedYMin ?? 0)),\(String(format: "%.4f", diag?.trackedYMax ?? 0))]",
            "[histCounts] 1=\(diag?.historyCount1 ?? 0) 2=\(diag?.historyCount2 ?? 0) 3=\(diag?.historyCount3 ?? 0) 4=\(diag?.historyCount4 ?? 0)",
            "[commitLatency] appeared=\(diag?.trackerRawDirectionAppearedMoving ?? 0) committed=\(diag?.trackerCommittedDirectionChanges ?? 0) reset=\(diag?.trackerPendingResetBeforeCommit ?? 0) L1=\(diag?.trackerCommitLatency1 ?? 0) L2=\(diag?.trackerCommitLatency2 ?? 0) L3+=\(diag?.trackerCommitLatency3Plus ?? 0)",
            "[raw=\(diag?.rawMovementEventsCreated ?? 0) norm=\(diag?.normalizedMovementCount ?? 0) fused=\(diag?.fusedMovementCount ?? 0) trusted=\(diag?.trustedDirectionalCount ?? 0) final=\(diag?.finalRecordMovementCount ?? 0)]",
            "[pubCalls=\(diag?.publishHandTrackingCalls ?? 0) pubSkips=\(diag?.publishHandTrackingDedupSkips ?? 0) starts=\(diag?.activeMovementStarts ?? 0) attempts=\(diag?.activeMovementFinishAttempts ?? 0) merges=\(diag?.mergedSegments ?? 0)]",
            "[rawDrops=\(dropStr(rawDrops))]",
            "[normDrops=\(dropStr(normDrops))]",
            "[trustDrops=\(dropStr(trustDrops))]",
            "[dvsNotation] lastDecision=\(dvsNotationDiagnostics.lastDecision?.rawValue ?? "notEvaluated") decisions=\(dvsNotationDiagnostics.totalDecisionCount) accumulatedSamples=\(dvsNotationDiagnostics.accumulatedSampleCount) finalizedSamples=\(dvsNotationDiagnostics.finalizedSampleCount) finalizedEvents=\(dvsNotationDiagnostics.finalizedEventCount)",
            "[dvsNotationDecisionCounts] \(dvsNotationDiagnostics.decisionCountsDescription(includingZeros: true))",
            "replay_source_label=\(label)",
        ]
        let text = lines.joined(separator: "\n")
        let funnelURL = dir.appendingPathComponent("\(baseName)_funnel_diag.txt")
        try? text.write(to: funnelURL, atomically: true, encoding: .utf8)
    }

    /// Publishes the synthetic-replay `DebugStats` on the MainActor. The replay
    /// path runs on `finalizationQueue` (a background thread), so writing
    /// `frozenReviewDiagnostics` (`@Published`) directly here triggers the
    /// "Publishing changes from background threads is not allowed" warning.
    private func publishFrozenReviewDiagnostics(_ stats: DebugStats?) {
        Task { @MainActor in
            self.frozenReviewDiagnostics = stats
        }
    }

    private static func loadLatestSavedPlatterTimeline() -> PlatterPositionTimeline? {
        let dirs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = dirs.first else { return nil }
        let capturesDir = base
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineCaptures", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: capturesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return nil }
        let matching = files.filter { $0.lastPathComponent.hasSuffix("_raw_platter_timeline.json") }
        let sorted = matching.sorted {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d0 > d1
        }
        guard let latest = sorted.first,
              let data = try? Data(contentsOf: latest),
              let timeline = try? JSONDecoder().decode(PlatterPositionTimeline.self, from: data)
        else { return nil }
        return timeline
    }
    #endif
}

private extension HandDirectionTracker.Direction {
    var debugName: String {
        switch self {
        case .idle:
            return "idle"
        case .movingForward:
            return "movingForward"
        case .movingBackward:
            return "movingBackward"
        case .searching:
            return "searching"
        }
    }
}

private extension MacCaptureEngine.HandMotionState {
    var debugName: String {
        switch self {
        case .searching:
            return "searching"
        case .steady:
            return "steady"
        case .movingLeft:
            return "movingLeft"
        case .movingRight:
            return "movingRight"
        }
    }
}

extension MacCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            ScratchLabPerformanceSignpost.event(
                "AudioBufferReceived",
                count: Int(CMSampleBufferGetNumSamples(sampleBuffer))
            )
            appendRoutineAudioSampleBufferIfNeeded(sampleBuffer)
            #if DEBUG
            accumulateChannelMapDiagnosticSampleBufferIfNeeded(sampleBuffer)
            #endif
        }
        guard shouldProcessCaptureSamples else { return }
        let signpostID = ScratchLabPerformanceSignpost.begin("CaptureFrameProcess")
        defer { ScratchLabPerformanceSignpost.end("CaptureFrameProcess", signpostID) }

        if output is AVCaptureVideoDataOutput {
            processVideoSampleBuffer(sampleBuffer)
        } else {
            processAudioSampleBuffer(sampleBuffer)
        }
    }
}

extension MacCaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        if let audioURL = pendingRoutineOutputAudioURL {
            do {
                try scratchPlaybackController.beginRoutineOutputCapture(
                    destinationURL: audioURL
                )
            } catch {
                pendingRoutineOutputAudioURL = nil
                let message = error.localizedDescription
                Task { @MainActor in
                    self.reportRoutineRecordingIssue(message)
                }
                output.stopRecording()
                return
            }
        }
        Task { @MainActor in
            self.isRoutineRecording = true
            self.routineRecordingStatus = "Recording \(fileURL.lastPathComponent)"
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        pendingRoutineOutputAudioURL = nil
        audioQueue.sync {
            let snapshot = self.activeRoutineAudioCaptureWriter?.diagnosticsSnapshot()
            self.activeRoutineAudioCaptureWriter = nil
            self.publishRoutineAudioCaptureDiagnostics(snapshot)
        }
        scratchPlaybackController.finishRoutineOutputCapture { [weak self] outcome in
            guard let self else { return }
            let finalError: Error?
            switch outcome {
            case let .exported(audioURL, frames, sampleRate, samples):
                self.activeRoutineAudioNotationDetector?.process(
                    samples: samples,
                    sampleRate: sampleRate
                )
                Task { @MainActor in
                    self.onboardOutputCaptureStatus = "Captured \(frames) onboard AHHH frames for this take."
                    let muxError: Error?
                    do {
                        try await RoutineReviewMovieMuxer.replaceAudioTrack(
                            videoURL: outputFileURL,
                            onboardAudioURL: audioURL
                        )
                        muxError = nil
                    } catch {
                        muxError = error
                    }
                    self.finalizeRoutineRecording(
                        outputFileURL: outputFileURL,
                        error: error ?? muxError
                    )
                }
                return
            case .empty:
                finalError = error ?? ScratchSamplePlaybackController.RoutineOutputCaptureError.emptyCapture
            case .notArmed:
                finalError = error ?? ScratchSamplePlaybackController.RoutineOutputCaptureError.playbackEngineNotRunning
            case let .error(captureError):
                finalError = error ?? captureError
            }

            Task { @MainActor in
                // finalizeRoutineRecording returns immediately and schedules
                // its second half through the admission gate.
                self.finalizeRoutineRecording(
                    outputFileURL: outputFileURL,
                    error: finalError
                )
            }
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let red = Double((int >> 16) & 0xFF) / 255.0
        let green = Double((int >> 8) & 0xFF) / 255.0
        let blue = Double(int & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Per-observation movement trace (DEBUG diagnostic)

// DEBUG-only per-observation movement trace for capture diagnosis. Records
// EVERY hand-tracking observation a routine take processes — the raw tracked
// point, the smoothed point, the tracker's raw direction and idle reason, the
// semantic direction, the publication-dedup outcome, and both the PROPOSED
// (enqueued) and ACTUAL (executed) builder inputs — so the movement-loss
// diagnosis can be reproduced offline without reconstructing observations from
// the integrated platter timeline (which drops raw X/Y, joint confidence,
// Vision misses, continuity substitutions, publication timing, and MainActor
// delay).
//
// Pure Foundation + CoreGraphics; no SwiftUI, no Vision, no I/O beyond Codable
// encoding. The recorder is wired and drained by MacCaptureEngine under
// `#if DEBUG`; Release builds are unaffected.

/// One chronological hand-tracking observation.
struct MovementTraceObservation: Codable, Equatable {
    /// How the observation originated.
    enum PointKind: String, Codable, Equatable {
        /// A real Vision point fed to the tracker and builder.
        case real
        /// A short-gap continuity fill: the platter recorder is fed the last
        /// point, but the tracker and builder are intentionally frozen.
        case continuityFill
        /// No point returned: the tracker is fed a miss, the builder is not fed.
        case miss
        /// A real point rejected as an impossible positional jump; the tracker
        /// is fed exactly one miss (this is the only trace record for the frame).
        case jumpRejected
    }

    /// A normalised [0,1] image-space point.
    struct Point: Codable, Equatable {
        let x: Double
        let y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        init(_ point: CGPoint) {
            self.init(x: Double(point.x), y: Double(point.y))
        }

        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    /// Monotonic, take-local observation ID, assigned BEFORE the observation
    /// is enqueued to the builder, so the actual builder result can be
    /// attached back to this exact observation.
    let index: Int
    let kind: PointKind

    // Host-time timestamps (seconds).
    let presentationTime: Double        // capture/presentation timestamp (authoritative)
    let processingStartTime: Double     // when processing began
    let visionCompletionTime: Double?   // when Vision finished (nil for miss/continuity)
    let takeRelativeTime: Double        // take-relative seconds

    // Actual tracker input (nil for miss/jump/continuity — the tracker is fed
    // a miss or nothing instead).
    let trackerPoint: Point?
    let trackerTime: Double             // `at` passed to the tracker (host seconds)

    // Enqueue info (recorded at publication time, before the MainActor hop).
    let enqueueTime: Double             // when the builder task was enqueued (host seconds)
    let enqueueSequence: Int            // monotonic enqueue order

    // Actual builder input. nil when the builder did NOT process this
    // observation (dedup rejected, continuity-filled, or never reached
    // publication). These values are identical to what was enqueued — position,
    // state, and confidence are captured before the MainActor hop.
    /// Actual scalar movement position the builder received, stored in `x`;
    /// `y` is reserved as zero. Current camera capture supplies angular platter
    /// position here, not the smoothed image-space display point.
    let builderPoint: Point?
    let builderState: String?           // HandMotionState the builder received
    let builderConfidence: Double?      // tracker confidence the builder received

    // Actual builder execution (recorded by the builder on the MainActor, keyed
    // by `index`). nil when the builder never executed this observation.
    let builderExecutionTime: Double?   // actual MainActor `now`
    let builderExecutionSequence: Int?  // actual execution order
    let builderAction: String?          // started / extended / rejected / finished
    let builderRejectionReason: String? // steady/searching or raw drop reason
    let finishedEventIndex: Int?        // builder event index when action == finished
    let builderSkippedReason: String?   // nil=executed; "recordingStopped"/"postFinalization"/"wrongInstance"

    // Tracker diagnostics (live, for comparison with replay).
    let rawDirection: String?           // committed tracker direction
    let idleReason: String?             // tracker idle reason (when idle)
    let trackerConfidence: Double?      // tracker confidence after this observation
    let semanticDirection: String?      // HandMotionState derived from the direction
    let jointConfidence: Double?        // winning joint's Vision confidence (real only)
    let rejectedPoint: Point?           // jumpRejected: the raw point that was rejected (diagnostic)

    /// Whether publication dedup suppressed this observation (so the builder
    /// was not fed even though a point/state was available).
    let dedupRejected: Bool
}

/// The on-disk format of a `take-NNN_movement_trace.json` file.
struct MovementTraceExport: Codable, Equatable {
    let schemaVersion: String
    let takeID: String
    let takeNumber: Int
    /// Host-time anchor of the recording start (used by replay to reproduce
    /// builder-relative elapsed times).
    let recordingStartHostTime: Double
    /// Host-time the builder was drained at finalization. The builder's drain
    /// advances the final active movement's `furthestTime` to this instant, so
    /// the exact replay must drain at the SAME time to reproduce the event's
    /// `endTime` exactly.
    let finalizationHostTime: Double
    let observations: [MovementTraceObservation]
}

/// The on-disk format of a `take-NNN_movement_diagnostics.json` file: the
/// completed aggregate `RoutineMovementDiagnosticsSnapshot` plus the take
/// identity the export coordinator fills in.
struct MovementDiagnosticsExport: Codable, Equatable {
    let schemaVersion: String
    let takeID: String
    let takeNumber: Int
    let diagnostics: MacCaptureEngine.RoutineMovementDiagnosticsSnapshot
}

/// Accumulates a chronological movement trace for one routine take.
///
/// Serialized by a lock: observations are recorded on the video queue, the
/// builder reports its execution on the MainActor, and the drain happens on the
/// AVCaptureFileOutput delegate queue at take finalization — the same
/// serialized-ownership discipline the platter recorder uses.
final class MovementTraceRecorder {

    private let lock = NSLock()
    private var observations: [MovementTraceObservation] = []
    private var nextIndex = 0
    private var nextEnqueueSequence = 0
    private var nextBuilderExecutionSequence = 0

    /// The host-time anchor the replay should use for builder-relative time.
    private(set) var recordingStartHostTime: Double = 0

    init() {}

    func startRecording(at hostTime: Double) {
        lock.lock()
        observations.removeAll(keepingCapacity: true)
        nextIndex = 0
        nextEnqueueSequence = 0
        nextBuilderExecutionSequence = 0
        recordingStartHostTime = hostTime
        lock.unlock()
    }

    /// Records one observation at enqueue time and returns its stable
    /// observation ID. Called on the video queue.
    @discardableResult
    func recordObservation(
        kind: MovementTraceObservation.PointKind,
        presentationTime: Double,
        processingStartTime: Double,
        visionCompletionTime: Double?,
        takeRelativeTime: Double,
        trackerPoint: MovementTraceObservation.Point?,
        trackerTime: Double,
        jointConfidence: Double?,
        builderPoint: MovementTraceObservation.Point?,
        builderState: String?,
        builderConfidence: Double?,
        rawDirection: String?,
        idleReason: String?,
        trackerConfidence: Double?,
        semanticDirection: String?,
        rejectedPoint: MovementTraceObservation.Point?,
        dedupRejected: Bool
    ) -> Int {
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        let enqueueSequence = nextEnqueueSequence
        nextEnqueueSequence += 1
        let observation = MovementTraceObservation(
            index: index,
            kind: kind,
            presentationTime: presentationTime,
            processingStartTime: processingStartTime,
            visionCompletionTime: visionCompletionTime,
            takeRelativeTime: takeRelativeTime,
            trackerPoint: trackerPoint,
            trackerTime: trackerTime,
            enqueueTime: processingStartTime,
            enqueueSequence: enqueueSequence,
            builderPoint: builderPoint,
            builderState: builderState,
            builderConfidence: builderConfidence,
            builderExecutionTime: nil,
            builderExecutionSequence: nil,
            builderAction: nil,
            builderRejectionReason: nil,
            finishedEventIndex: nil,
            builderSkippedReason: nil,
            rawDirection: rawDirection,
            idleReason: idleReason,
            trackerConfidence: trackerConfidence,
            semanticDirection: semanticDirection,
            jointConfidence: jointConfidence,
            rejectedPoint: rejectedPoint,
            dedupRejected: dedupRejected
        )
        observations.append(observation)
        lock.unlock()
        return index
    }

    /// Records the actual builder execution for observation `index`. Called on
    /// the MainActor by the builder itself.
    func recordBuilderExecution(
        index: Int,
        executionTime: Double,
        action: String,
        rejectionReason: String?,
        finishedEventIndex: Int?,
        skippedReason: String?
    ) {
        lock.lock()
        guard let position = observations.indices.first(where: { observations[$0].index == index }) else {
            lock.unlock()
            return
        }
        let executionSequence = nextBuilderExecutionSequence
        nextBuilderExecutionSequence += 1
        let current = observations[position]
        observations[position] = MovementTraceObservation(
            index: current.index,
            kind: current.kind,
            presentationTime: current.presentationTime,
            processingStartTime: current.processingStartTime,
            visionCompletionTime: current.visionCompletionTime,
            takeRelativeTime: current.takeRelativeTime,
            trackerPoint: current.trackerPoint,
            trackerTime: current.trackerTime,
            enqueueTime: current.enqueueTime,
            enqueueSequence: current.enqueueSequence,
            builderPoint: current.builderPoint,
            builderState: current.builderState,
            builderConfidence: current.builderConfidence,
            builderExecutionTime: executionTime,
            builderExecutionSequence: executionSequence,
            builderAction: action,
            builderRejectionReason: rejectionReason,
            finishedEventIndex: finishedEventIndex,
            builderSkippedReason: skippedReason,
            rawDirection: current.rawDirection,
            idleReason: current.idleReason,
            trackerConfidence: current.trackerConfidence,
            semanticDirection: current.semanticDirection,
            jointConfidence: current.jointConfidence,
            rejectedPoint: current.rejectedPoint,
            dedupRejected: current.dedupRejected
        )
        lock.unlock()
    }

    func export(takeID: String, takeNumber: Int, finalizationHostTime: Double) -> MovementTraceExport {
        lock.lock()
        let snapshot = observations
        lock.unlock()
        return MovementTraceExport(
            schemaVersion: "scratchlab_movement_trace_v1",
            takeID: takeID,
            takeNumber: takeNumber,
            recordingStartHostTime: recordingStartHostTime,
            finalizationHostTime: finalizationHostTime,
            observations: snapshot
        )
    }
}

/// Replays an exported movement trace through the REAL live pipeline
/// (`HandDirectionTracker → RoutineDetectedNotationBuilder →
/// RoutineNotationEventNormalizer → RoutineNotationFusionEngine`) to reproduce
/// the live take's result offline.
///
/// Unlike the legacy platter-timeline replay, this consumes the recorded
/// observation trace directly. Two replay modes are provided:
///   • `idealReplay` — feeds the builder in enqueue order with frame/sample
///     time, the idealised (no MainActor delay, no skip) pipeline. Baseline.
///   • `exactReplay` — feeds the builder in the ACTUAL recorded execution order
///     with the ACTUAL execution time, skipping observations whose builder task
///     never executed. Reproduces the live builder sequence.
enum MovementTraceReplay {

    /// Maps a tracker direction to its semantic `HandMotionState`, mirroring
    /// `MacCaptureEngine.handMotionState(from:)`.
    static func semanticState(from direction: HandDirectionTracker.Direction) -> MacCaptureEngine.HandMotionState {
        switch direction {
        case .movingForward: return .movingLeft   // camera +X → semantic backward
        case .movingBackward: return .movingRight // camera −X → semantic forward
        case .idle: return .steady
        case .searching: return .searching
        }
    }

    /// Parses a recorded `builderState` string back into a `HandMotionState`.
    static func semanticState(from string: String) -> MacCaptureEngine.HandMotionState? {
        switch string {
        case "movingLeft": return .movingLeft
        case "movingRight": return .movingRight
        case "steady": return .steady
        case "searching": return .searching
        default: return nil
        }
    }

    private enum BuilderOrder { case ideal, exact }

    private static func runPipeline(
        observations: [MovementTraceObservation],
        audioEvents: [ScratchAudioNotationEventCandidate],
        handPoseInterval: CFTimeInterval,
        order: BuilderOrder,
        drainTime: Double?
    ) -> (snapshot: MacCaptureEngine.RoutineMovementDiagnosticsSnapshot,
          events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        let tracker = HandDirectionTracker()
        let debugSession = MacCaptureEngine.RoutineMovementDebugSession(handPoseInterval: handPoseInterval)
        let builder = MacCaptureEngine.RoutineDetectedNotationBuilder(
            startedAt: observations.first?.presentationTime ?? 0,
            debugSession: debugSession
        )
        var states: [Int: MacCaptureEngine.HandMotionState] = [:]

        // Pass 1: feed the tracker in enqueue order, mirroring the live
        // tracker-side debug recording (recordSample + steady idle reasons).
        for observation in observations {
            let direction: HandDirectionTracker.Direction
            switch observation.kind {
            case .real:
                if let point = observation.trackerPoint {
                    direction = tracker.recordObservation(rawPoint: point.cgPoint, at: observation.trackerTime)
                } else {
                    direction = tracker.recordMiss()
                }
            case .miss, .jumpRejected:
                direction = tracker.recordMiss()
            case .continuityFill:
                continue
            }
            let state = semanticState(from: direction)
            states[observation.index] = state
            if observation.kind == .real {
                debugSession.recordSample(
                    rawPoint: observation.trackerPoint?.cgPoint,
                    displayedPoint: observation.builderPoint?.cgPoint,
                    confidence: observation.trackerConfidence ?? 0,
                    rawDirection: direction,
                    semanticState: state
                )
            }
            if state == .steady {
                debugSession.recordSteadyIdleReason(tracker.lastIdleReason)
            }
        }

        // Pass 2: feed the builder in the requested order.
        let ordered: [MovementTraceObservation]
        switch order {
        case .ideal:
            ordered = observations
        case .exact:
            ordered = observations
                .filter { $0.builderExecutionSequence != nil }
                .sorted { ($0.builderExecutionSequence ?? 0) < ($1.builderExecutionSequence ?? 0) }
        }
        for observation in ordered {
            // Dedup-rejected and never-published observations are NEVER fed.
            guard !observation.dedupRejected,
                  let stateString = observation.builderState,
                  let state = semanticState(from: stateString),
                  observation.builderPoint != nil || observation.builderState != nil else { continue }
            // Exact replay honours actual execution time and skips.
            if order == .exact {
                guard observation.builderSkippedReason == nil,
                      let executionTime = observation.builderExecutionTime else { continue }
                builder.recordObservation(
                    state: state,
                    position: observation.builderPoint.map { Double($0.x) },
                    confidence: observation.builderConfidence ?? 0,
                    now: executionTime
                )
            } else {
                builder.recordObservation(
                    state: state,
                    position: observation.builderPoint.map { Double($0.x) },
                    confidence: observation.builderConfidence ?? 0,
                    now: observation.enqueueTime
                )
            }
        }

        let rawEvents = builder.movementEvents(
            now: drainTime ?? observations.last?.presentationTime ?? 0
        )
        let snapshot = MacCaptureEngine.RoutineNotationFusionEngine().snapshot(
            audioSnapshot: ScratchAudioNotationSnapshot(audioEvents: audioEvents, confidence: nil),
            motionEvents: rawEvents,
            detectedLabel: nil,
            labelSource: "unknown",
            labelConfidence: nil,
            debugSession: debugSession
        )
        return (debugSession.snapshot(), snapshot.recordMovementEvents)
    }

    /// Idealised replay: builder fed in enqueue order with frame time. No
    /// MainActor delay, no skip. This is the comparison baseline.
    static func idealReplay(
        observations: [MovementTraceObservation],
        audioEvents: [ScratchAudioNotationEventCandidate],
        handPoseInterval: CFTimeInterval,
        drainTime: Double? = nil
    ) -> (snapshot: MacCaptureEngine.RoutineMovementDiagnosticsSnapshot,
          events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        runPipeline(observations: observations, audioEvents: audioEvents,
                    handPoseInterval: handPoseInterval, order: .ideal, drainTime: drainTime)
    }

    /// Exact replay: builder fed in the ACTUAL recorded execution order with
    /// the ACTUAL execution time; observations whose builder task was skipped
    /// or never executed are excluded. `drainTime` is the live finalization
    /// instant (recorded in the trace) so the drain reproduces the event's
    /// `endTime` exactly.
    static func exactReplay(
        observations: [MovementTraceObservation],
        audioEvents: [ScratchAudioNotationEventCandidate],
        handPoseInterval: CFTimeInterval,
        drainTime: Double? = nil
    ) -> (snapshot: MacCaptureEngine.RoutineMovementDiagnosticsSnapshot,
          events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        runPipeline(observations: observations, audioEvents: audioEvents,
                    handPoseInterval: handPoseInterval, order: .exact, drainTime: drainTime)
    }
}

// MARK: - Builder admission gate

/// Per-take, lock-protected admission gate for notation-builder tasks.
///
/// The finalization barrier must be race-free: video processing keeps running
/// while a take finalizes, so a bare `DispatchGroup.enter()` can happen after
/// `wait()` has already returned (the group reaches zero and a later `enter()`
/// escapes the barrier). This gate makes admission and closing share one lock:
///
///   • `open()` starts a new take's window with a fresh generation and group.
///   • `admit()` atomically checks "still open for this generation" and enters
///     the group, returning a token tied to that generation.
///   • `close()` atomically closes admission first, so every later `admit()`
///     returns nil; the returned group is then waited on.
///   • `isCurrent(_:)` lets an admitted task skip mutating a builder that has
///     already been replaced by a later take.
///
/// `wait()` runs on the AVCaptureFileOutput delegate queue, never on the
/// MainActor, so it cannot block the MainActor waiting for itself.
final class BuilderAdmissionGate {
    private let lock = NSLock()
    private var generation = 0
    private var isOpen = false
    private var group = DispatchGroup()

    /// A token tied to one take: its generation and the group to `leave()`.
    struct Token {
        let generation: Int
        let group: DispatchGroup
    }

    /// Opens admission for a new take and returns its generation.
    @discardableResult
    func open() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        isOpen = true
        group = DispatchGroup()
        return generation
    }

    /// Atomically admits an enqueue if the gate is open. Returns the token to
    /// `leave()` on completion, or nil if admission is closed (or the take was
    /// replaced). The check and `enter()` share one lock — never a bare boolean
    /// checked separately from `DispatchGroup.enter()`.
    func admit() -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return nil }
        group.enter()
        return Token(generation: generation, group: group)
    }

    /// Atomically closes admission. Returns the group to `wait()` on. After
    /// this, every later `admit()` returns nil.
    func close() -> DispatchGroup {
        lock.lock(); defer { lock.unlock() }
        isOpen = false
        return group
    }

    /// Whether `generation` is still the active generation. Used by an admitted
    /// task to avoid mutating a builder that belongs to a later take.
    func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }
}

/// Accumulated-deadline hand-pose cadence scheduler.
///
/// The previous gate (`now - lastAccepted >= interval`) reset its timestamp to
/// the ACCEPTED frame, so a 30 fps source (≈33 ms) against a 40 ms interval
/// could only accept every ≈66 ms — quantizing 30 fps to ≈15 fps. This
/// scheduler advances an accumulated deadline instead, preserving phase, so the
/// achieved rate tracks `1/interval` (≈25 fps for a 40 ms interval) rather than
/// half of it.
///
/// A drift guard re-anchors the deadline after a stall so a catch-up burst
/// cannot fire back-to-back. `reset()` is called at the start of each take so
/// scheduling never bleeds across takes. Purely deterministic: `now` is passed
/// in, never read from the clock.
struct HandPoseCadenceScheduler {
    private(set) var interval: CFTimeInterval
    private var nextDeadline: CFTimeInterval = -.infinity

    init(interval: CFTimeInterval) {
        self.interval = interval
    }

    /// Whether the frame arriving at `now` should be analyzed. Advances the
    /// accumulated deadline when it returns `true`.
    mutating func shouldProcess(frameAt now: CFTimeInterval) -> Bool {
        if nextDeadline == -.infinity {
            nextDeadline = now + interval
            return true
        }
        guard now >= nextDeadline else { return false }
        nextDeadline += interval
        if nextDeadline <= now {
            // Fell behind (stall then burst) — re-anchor rather than fire a
            // catch-up burst of back-to-back frames.
            nextDeadline = now + interval
        }
        return true
    }

    /// Reset the accumulated phase; call at the start of a take.
    mutating func reset() {
        nextDeadline = -.infinity
    }
}

// MARK: - Temporally-stable hand anchor

/// One joint's contribution to the hand anchor.
struct HandAnchorSample: Equatable {
    let location: CGPoint
    let confidence: Float
}

enum HandAnchorMode: String, Equatable {
    /// Confidence-weighted palm/base anchor (wrist + MCP ring) — temporally
    /// stable because it does not track a single fingertip that can flicker.
    case base
    /// Single highest-confidence fingertip — fallback only, used when the base
    /// is unavailable.
    case tipFallback
}

/// The resolved hand anchor for one frame.
struct HandAnchorSelection: Equatable {
    let point: CGPoint
    let confidence: Float
    let mode: HandAnchorMode
    /// Joint names that formed the anchor (identity, for diagnostics).
    let jointNames: [String]
    /// Whether the anchor identity (mode or joint set) changed this frame.
    let switched: Bool
}

/// Pure anchor math: confidence-weighted base anchor + fingertip fallback.
/// No Vision, no state — deterministic and unit-testable.
enum HandAnchorMath {
    /// Wrist + MCP/CMC joints that form the stable palm/base anchor.
    static let baseJointNames = ["wrist", "thumbCMC", "indexMCP", "middleMCP", "ringMCP", "littleMCP"]
    /// Fingertip joints used as the fallback anchor.
    static let tipJointNames = ["thumbTip", "indexTip", "middleTip", "ringTip", "littleTip"]

    /// Confidence-weighted palm/base anchor from the wrist + MCP ring. Requires
    /// the wrist (the anchor core) plus at least one MCP joint; returns nil
    /// otherwise so the caller can fall back to a fingertip. The wrist carries
    /// the palm's translational motion while the MCP joints pin its orientation,
    /// so the weighted point does not jump when a single finger curls.
    static func baseAnchor(
        from joints: [String: HandAnchorSample]
    ) -> (point: CGPoint, confidence: Float, jointNames: [String])? {
        guard joints["wrist"] != nil else { return nil }
        var weightedX = 0.0, weightedY = 0.0, totalWeight = 0.0
        var names: [String] = []
        for name in baseJointNames {
            guard let sample = joints[name], sample.confidence > 0 else { continue }
            let w = Double(sample.confidence)
            weightedX += Double(sample.location.x) * w
            weightedY += Double(sample.location.y) * w
            totalWeight += w
            names.append(name)
        }
        let hasMCP = names.contains(where: { $0 != "wrist" })
        guard hasMCP, totalWeight > 0 else { return nil }
        let confidence = Float(totalWeight / Double(names.count))
        return (CGPoint(x: weightedX / totalWeight, y: weightedY / totalWeight),
                confidence, names.sorted())
    }

    /// Highest-confidence fingertip (fallback). Returns nil when no tip is
    /// present.
    static func bestTipAnchor(
        from joints: [String: HandAnchorSample]
    ) -> (point: CGPoint, confidence: Float, jointNames: [String])? {
        let best = tipJointNames
            .compactMap { name -> (String, HandAnchorSample)? in
                joints[name].map { (name, $0) }
            }
            .max { $0.1.confidence < $1.1.confidence }
        guard let best else { return nil }
        return (best.1.location, best.1.confidence, [best.0])
    }
}

/// Temporally-stable hand anchor: prefers the base (wrist + MCP) anchor and
/// holds it across brief losses, falling back to a fingertip only when the base
/// is gone for longer (or was never present), and reacquiring the base as soon
/// as it returns. Holds are TIME-BOUNDED (not frame-counted), so behaviour is
/// identical at any frame rate; after the holds expire the tracker returns nil
/// so the caller enters its miss path (and a stale anchor never feeds the
/// angular tracker). Pure and deterministic — Vision joint samples + host time
/// are passed in.
struct HandAnchorTracker {
    /// Seconds the base (wrist + MCP) anchor is held after the base is lost,
    /// before falling back to a fingertip.
    static let baseHoldDuration: Double = 0.12
    /// Seconds a fingertip fallback is held after the tip is lost, before the
    /// anchor expires entirely (returns nil → caller miss path).
    static let tipHoldDuration: Double = 0.10

    private var last: HandAnchorSelection?
    /// Host time of the last REAL (non-held) anchor observation. nil until the
    /// first anchor is seen.
    private var lastSeenTime: Double?

    mutating func update(joints: [String: HandAnchorSample], at time: Double) -> HandAnchorSelection? {
        if let base = HandAnchorMath.baseAnchor(from: joints) {
            let switched = last?.mode != .base || last?.jointNames != base.jointNames
            let selection = HandAnchorSelection(
                point: base.point, confidence: base.confidence, mode: .base,
                jointNames: base.jointNames, switched: switched)
            last = selection
            lastSeenTime = time
            return selection
        }

        let tip = HandAnchorMath.bestTipAnchor(from: joints)

        // Base lost briefly: hold the base anchor. `lastSeenTime` is NOT
        // advanced, so the hold is bounded by real elapsed time since the base
        // was last seen.
        if let last, last.mode == .base, let lastSeenTime,
           time - lastSeenTime <= Self.baseHoldDuration {
            let held = HandAnchorSelection(
                point: last.point, confidence: last.confidence, mode: .base,
                jointNames: last.jointNames, switched: false)
            self.last = held
            return held
        }

        // Fall back to a fingertip.
        if let tip {
            let switched = last?.mode != .tipFallback || last?.jointNames != tip.jointNames
            let selection = HandAnchorSelection(
                point: tip.point, confidence: tip.confidence, mode: .tipFallback,
                jointNames: tip.jointNames, switched: switched)
            last = selection
            lastSeenTime = time
            return selection
        }

        // Tip lost briefly: hold the tip anchor.
        if let last, last.mode == .tipFallback, let lastSeenTime,
           time - lastSeenTime <= Self.tipHoldDuration {
            return last
        }

        // No base, no tip, and any hold has expired — the anchor is lost.
        return nil
    }

    mutating func reset() {
        last = nil
        lastSeenTime = nil
    }
}

// MARK: - Physical platter rotation (angular direction, not raw camera X)

/// Signed rotational direction around the platter centre.
enum PlatterRotationDirection: String, Equatable {
    case counterClockwise  // positive angular displacement
    case clockwise         // negative angular displacement
    case idle
    case searching
}

/// Why a platter-rotation observation was rejected (fail-closed).
enum PlatterRotationRejection: String, Equatable {
    case tooCloseToCentre
    case implausibleJump
    case unreliableGeometry
}

/// One platter-rotation observation result.
struct PlatterRotationObservation: Equatable {
    /// Wrapped angle in [-π, π] around the centre.
    let angle: Double
    /// Unwrapped cumulative angle — the continuous angular position preserved
    /// for notation geometry.
    let continuousAngle: Double
    /// Signed angular displacement since the previous accepted sample.
    let angularDisplacement: Double
    /// Signed angular velocity (radians/second).
    let angularVelocity: Double
    let direction: PlatterRotationDirection
    let rejection: PlatterRotationRejection?
}

/// Pure angular math + the single documented camera orientation contract.
enum PlatterRotationMath {
    /// Angle of `point` around `centre`, in [-π, π], via `atan2(dy, dx)`.
    static func angle(of point: CGPoint, centre: CGPoint) -> Double {
        atan2(Double(point.y - centre.y), Double(point.x - centre.x))
    }

    /// Signed shortest angular difference `to - from`, in (-π, π], correctly
    /// unwrapping across the ±π boundary (so 179° → -179° is +2°, not -358°).
    static func shortestSignedDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        else if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// The single documented camera orientation contract: positive angular
    /// displacement (counter-clockwise) maps to record "forward", negative
    /// (clockwise) to "backward". PROVISIONAL — mirrors the CC6 decoder's sign
    /// contract and is the ONE place to flip if a hardware correlation shows it
    /// inverted. `isMirrored` compensates for a mirrored camera feed, whose
    /// handedness is flipped relative to physical motion.
    static func recordDirection(
        for direction: PlatterRotationDirection,
        isMirrored: Bool
    ) -> MacCaptureEngine.LiveRecordDirection? {
        switch direction {
        case .counterClockwise: return isMirrored ? .backward : .forward
        case .clockwise: return isMirrored ? .forward : .backward
        case .idle, .searching: return nil
        }
    }

    /// Evidence-based angular movement confidence, combining the independent
    /// evidence channels into one [0,1] value. The legacy X-direction tracker's
    /// confidence must NEVER feed angular notation — this is the angular
    /// authority (anchor confidence, geometry confidence, displacement/velocity
    /// quality, hysteresis state, and observation freshness).
    static func angularConfidence(
        anchorConfidence: Double,      // 0…1 — Vision joint confidence of the stable anchor
        geometryConfidence: Double,    // 0…1 — platter/rig geometry confidence
        angularSpeed: Double,          // abs radians/second — displacement/velocity quality
        direction: PlatterRotationDirection,  // hysteresis state
        freshnessSeconds: Double       // seconds since the last valid observation
    ) -> Double {
        let anchor = min(1, max(0, anchorConfidence))
        let geometry = min(1, max(0, geometryConfidence))
        // Sustained angular speed is strong evidence of real motion; near-zero
        // speed (jitter) is weak evidence.
        let speedQuality = min(1, angularSpeed / 2.0)
        // A committed direction is more trustworthy than a pending/idle one.
        let commitFactor: Double
        switch direction {
        case .counterClockwise, .clockwise: commitFactor = 1.0
        case .idle: commitFactor = 0.4
        case .searching: commitFactor = 0.0
        }
        // A just-observed anchor is fully trusted; a held/stale one decays.
        let freshness = max(0, 1 - freshnessSeconds / 0.5)
        let confidence = anchor * geometry * (0.4 + 0.6 * speedQuality) * commitFactor * freshness
        return min(1, max(0, confidence))
    }
}

/// Stateful platter-rotation tracker: derives signed angular displacement and
/// velocity around a platter centre from successive hand-anchor points, with
/// centre rejection, implausible-jump rejection, and commit/hold hysteresis —
/// all on ELAPSED TIME (not frame counts), so timing behaviour is identical at
/// 15/25/30/60 fps. Never raw camera-space X. Purely deterministic; `time` is
/// passed in.
struct PlatterRotationTracker {
    static let velocityThreshold: Double = 0.30        // rad/s to count as moving
    static let displacementThreshold: Double = 0.03    // rad net displacement per window
    static let commitDuration: Double = 0.08           // seconds of agreeing direction before commit
    static let holdDuration: Double = 0.12             // seconds to hold direction after a miss
    static let resetDuration: Double = 0.35            // seconds of miss before searching
    static let historyCapacity = 4
    static let minRadius: Double = 0.02                // reject points too close to centre
    static let maxAngularVelocity: Double = 12.0       // rad/s ceiling for jump rejection

    private struct Sample {
        let angle: Double
        let time: Double
    }

    private var history: [Sample] = []
    private var committed: PlatterRotationDirection = .idle
    private var pending: PlatterRotationDirection = .idle
    private var pendingSince: Double?
    private(set) var direction: PlatterRotationDirection = .idle
    private(set) var continuousAngle: Double = 0
    private var lastAngle: Double?
    private var lastTime: Double?
    /// Host time of the last successful observation (freshness + miss hold/reset).
    private(set) var lastObservationTime: Double?

    /// Process a successful anchor observation at `point` around `centre`.
    @discardableResult
    mutating func observe(point: CGPoint, centre: CGPoint, at time: Double) -> PlatterRotationObservation {
        let dx = Double(point.x - centre.x)
        let dy = Double(point.y - centre.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= Self.minRadius else {
            return PlatterRotationObservation(
                angle: 0, continuousAngle: continuousAngle, angularDisplacement: 0,
                angularVelocity: 0, direction: .idle, rejection: .tooCloseToCentre)
        }

        let angle = atan2(dy, dx)
        var displacement = 0.0
        var velocity = 0.0

        if let lastAngle {
            displacement = PlatterRotationMath.shortestSignedDelta(from: lastAngle, to: angle)
            if let lastTime {
                let dt = max(time - lastTime, 0.001)
                velocity = displacement / dt
                guard abs(velocity) <= Self.maxAngularVelocity else {
                    return PlatterRotationObservation(
                        angle: angle, continuousAngle: continuousAngle, angularDisplacement: 0,
                        angularVelocity: velocity, direction: .idle, rejection: .implausibleJump)
                }
            }
            continuousAngle += displacement
        }
        lastAngle = angle
        lastTime = time
        lastObservationTime = time

        history.append(Sample(angle: continuousAngle, time: time))
        if history.count > Self.historyCapacity {
            history.removeFirst()
        }

        let raw = computeRawDirection()
        updateCommitted(with: raw, at: time)
        direction = committed
        return PlatterRotationObservation(
            angle: angle, continuousAngle: continuousAngle, angularDisplacement: displacement,
            angularVelocity: velocity, direction: direction, rejection: nil)
    }

    /// Process a missed frame (no usable anchor). Holds the last committed
    /// direction for `holdDuration`, then drops to idle, then searching after
    /// `resetDuration` — all measured in elapsed time since the last observation.
    @discardableResult
    mutating func miss(at time: Double) -> PlatterRotationDirection {
        if let lastObservationTime, time - lastObservationTime >= Self.resetDuration {
            history.removeAll()
            committed = .idle
            pending = .idle
            pendingSince = nil
            direction = .searching
            return .searching
        }
        if let lastObservationTime, time - lastObservationTime <= Self.holdDuration {
            direction = committed
            return direction
        }
        direction = .idle
        return .idle
    }

    mutating func reset() {
        history.removeAll()
        committed = .idle
        pending = .idle
        pendingSince = nil
        direction = .idle
        continuousAngle = 0
        lastAngle = nil
        lastTime = nil
        lastObservationTime = nil
    }

    private func computeRawDirection() -> PlatterRotationDirection {
        guard history.count >= 2 else { return .idle }

        var weightedVelocity = 0.0
        var totalWeight = 0.0
        for i in 1..<history.count {
            let dt = max(history[i].time - history[i - 1].time, 0.001)
            let delta = history[i].angle - history[i - 1].angle
            let stepVelocity = delta / dt
            let weight = Double(i)
            weightedVelocity += stepVelocity * weight
            totalWeight += weight
        }
        let netDisplacement = history[history.count - 1].angle - history[0].angle
        guard totalWeight > 0, abs(netDisplacement) >= Self.displacementThreshold else {
            return .idle
        }
        let velocity = weightedVelocity / totalWeight
        if velocity > Self.velocityThreshold { return .counterClockwise }
        if velocity < -Self.velocityThreshold { return .clockwise }
        return .idle
    }

    private mutating func updateCommitted(with raw: PlatterRotationDirection, at time: Double) {
        if raw == pending {
            // Same pending direction: commit once it has persisted for
            // `commitDuration` (elapsed time, frame-rate independent).
            if committed != raw, let since = pendingSince, time - since >= Self.commitDuration {
                committed = raw
            }
        } else {
            pending = raw
            pendingSince = time
            // Idle/searching commit immediately (no hysteresis).
            if raw == .idle || raw == .searching {
                committed = raw
            }
        }
    }
}

// MARK: - Source-neutral movement observation + shared camera processor

/// Source-neutral movement observation for the notation builder. The builder
/// consumes direction, a scalar position, confidence, and provenance WITHOUT
/// knowing whether the position scalar is image-space X or continuous angular
/// displacement. For the camera, `position` is the unwrapped angular position
/// (in revolutions); the smoothed image point is a display concern and never
/// reaches the builder.
struct MovementObservation {
    let state: MacCaptureEngine.HandMotionState
    let position: Double?        // scalar, source-neutral (angular revolutions for camera)
    let confidence: Double
    let source: String           // provenance ("detected" = camera builder, etc.)
}

/// The shared, non-UI camera movement pipeline:
/// frame/timestamp → cadence → stable anchor → calibrated platter geometry →
/// angular tracker → builder observation. Used by BOTH live capture and offline
/// replay so the tracking/notation logic is never duplicated. Platform capture
/// APIs (AVCapture / AVAssetReader) remain thin adapters that only extract the
/// Vision joint samples and the platter centre.
struct CameraMovementProcessor {
    private var cadence = HandPoseCadenceScheduler(interval: 0)
    private var anchorTracker = HandAnchorTracker()
    private var rotationTracker = PlatterRotationTracker()
    /// Whether the mirrored-orientation contract is in effect.
    let isMirrored: Bool

    init(isMirrored: Bool = false) {
        self.isMirrored = isMirrored
    }

    /// One processed frame's output.
    struct Observation {
        /// Whether a usable hand anchor was resolved this frame (false → miss).
        let detected: Bool
        let state: MacCaptureEngine.HandMotionState
        /// Continuous angular position in revolutions (`angle / 2π`), for the
        /// notation builder. nil when no usable angular position exists.
        let position: Double?
        /// Evidence-based angular confidence (never the X tracker's).
        let confidence: Double
        let source: String
        /// Raw anchor point (for display smoothing only).
        let anchorPoint: CGPoint?
        let anchorConfidence: Float
        /// Anchor identity (for diagnostics): which joints formed the anchor and
        /// whether it switched this frame.
        let anchorJointNames: [String]
        let anchorMode: HandAnchorMode?
        let anchorSwitched: Bool
        /// True when the platter centre could not be resolved — the camera
        /// cannot contribute directional notation (fail-closed, never raw X).
        let calibrationInsufficient: Bool
    }

    /// Cadence gate — call BEFORE Vision so skipped frames never run the
    /// expensive hand-pose request. The processor owns the cadence phase so the
    /// same scheduling applies to live capture and offline replay.
    mutating func shouldProcess(frameAt now: Double, interval: Double) -> Bool {
        if cadence.interval != interval {
            cadence = HandPoseCadenceScheduler(interval: interval)
        }
        return cadence.shouldProcess(frameAt: now)
    }

    /// Process the extracted joints (Vision already ran; cadence already gated
    /// via `shouldProcess`). Returns the builder observation.
    mutating func process(
        frameAt now: Double,
        joints: [String: HandAnchorSample],
        platterCentre: CGPoint?,
        geometryConfidence: Float
    ) -> Observation {
        let calibrationInsufficient = (platterCentre == nil)

        guard let anchor = anchorTracker.update(joints: joints, at: now) else {
            _ = rotationTracker.miss(at: now)
            return Observation(
                detected: false, state: .searching, position: nil, confidence: 0,
                source: "detected", anchorPoint: nil, anchorConfidence: 0,
                anchorJointNames: [], anchorMode: nil, anchorSwitched: false,
                calibrationInsufficient: calibrationInsufficient)
        }

        guard let centre = platterCentre else {
            _ = rotationTracker.miss(at: now)
            return Observation(
                detected: true, state: .searching, position: nil, confidence: 0,
                source: "detected", anchorPoint: anchor.point,
                anchorConfidence: anchor.confidence,
                anchorJointNames: anchor.jointNames, anchorMode: anchor.mode,
                anchorSwitched: anchor.switched, calibrationInsufficient: true)
        }

        let rotation = rotationTracker.observe(point: anchor.point, centre: centre, at: now)
        if rotation.rejection != nil {
            return Observation(
                detected: true, state: .steady,
                position: rotation.continuousAngle / (2 * .pi), confidence: 0,
                source: "detected", anchorPoint: anchor.point,
                anchorConfidence: anchor.confidence,
                anchorJointNames: anchor.jointNames, anchorMode: anchor.mode,
                anchorSwitched: anchor.switched, calibrationInsufficient: false)
        }

        let state = handMotionState(for: rotation.direction)
        let freshness = rotationTracker.lastObservationTime.map { max(0, now - $0) } ?? 0
        let confidence = PlatterRotationMath.angularConfidence(
            anchorConfidence: Double(anchor.confidence),
            geometryConfidence: Double(geometryConfidence),
            angularSpeed: abs(rotation.angularVelocity),
            direction: rotation.direction,
            freshnessSeconds: freshness)

        return Observation(
            detected: true, state: state,
            position: rotation.continuousAngle / (2 * .pi), confidence: confidence,
            source: "detected", anchorPoint: anchor.point,
            anchorConfidence: anchor.confidence,
            anchorJointNames: anchor.jointNames, anchorMode: anchor.mode,
            anchorSwitched: anchor.switched, calibrationInsufficient: false)
    }

    private func handMotionState(for direction: PlatterRotationDirection) -> MacCaptureEngine.HandMotionState {
        guard let record = PlatterRotationMath.recordDirection(for: direction, isMirrored: isMirrored) else {
            return direction == .searching ? .searching : .steady
        }
        return record == .forward ? .movingRight : .movingLeft
    }

    mutating func reset() {
        cadence.reset()
        anchorTracker.reset()
        rotationTracker.reset()
    }
}
