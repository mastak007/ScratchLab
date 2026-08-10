// ScratchSamplePlaybackController.swift
// ScratchLab Desktop — Platter-Driven Scratch Sample Playback
//
// AVAudioEngine-based sample playback driven by CC6 platter position.
// Loads bundled WAVs into PCM buffers; maps accumulated platter steps to
// sample position; schedules short audio segments for forward/backward scratch.
//
// Owned by MacCaptureEngine. Output = system default audio device.
// No MIDI routing. No scoring. No Rane audio device routing.
//
// Thread model: load, ensureLoadedForDVSDrive, pausePlayback, resumePlayback,
// unload, and setCrossfader are safe to call from any thread, including the
// CoreMIDI callback thread — they enqueue work on a private serial audioQueue
// and return immediately. positionDidChange is different: it runs its
// complete trace + scheduling transaction synchronously on audioQueue (via
// runSynchronouslyOnAudioQueue), serialized with the async work above, so the
// caller blocks for a bounded scheduling operation instead of racing it.

import AVFoundation
import Foundation

/// Drives sample playback from a `ScratchPlatterTracker` position.
/// - Hot cue press: loads the corresponding bundled WAV (async, off CoreMIDI thread).
/// - Platter CC6 movement: updates playback position and schedules audio, as a
///   bounded synchronous transaction on `audioQueue` (caller blocks).
/// - No motion: audio stops after the current short segment plays out.
final class ScratchSamplePlaybackController {

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeedNode = AVAudioUnitVarispeed()

    // MARK: - Continuous DVS renderer (2026-08-09 static/burst fix)

    /// Continuous-render replacement for the DVS 60 Hz short-grain
    /// scheduling path. The control tick publishes signed velocity and the
    /// authoritative loop phase; audio is generated continuously at the
    /// hardware render rate by an AVAudioSourceNode, so no per-tick grain
    /// joins exist to click, gap, overlap, or amplitude-modulate — the
    /// architecture behind the residual static confirmed in the post-mixer
    /// capture. See DVSContinuousVinylRenderer.swift.
    let dvsContinuousRenderer = DVSContinuousVinylRenderer()

    /// Production default: the continuous renderer carries DVS audio.
    /// `false` routes DVS ticks through the legacy scheduled-grain branch
    /// (still fully compiled — it remains the MIDI path's machinery), kept
    /// as a hardware rollback lever and so grain-mechanism regression
    /// tests keep exercising the code they were written against.
    var dvsUsesContinuousRenderer = true

    // MARK: - Continuous MIDI platter drive (2026-08-09, right-deck-owned)
    //
    // Product decision (2026-08-09): the single loaded scratch sample is
    // owned exclusively by the Rane ONE MKII right platter / Deck 2 (MIDI
    // channel 1, CC6). This section never touches `positionDidChange`,
    // `positionDidChangeOnQueue`, `positionDidChangeContinuous`, or
    // `renderContinuousDVSTick` — the legacy grain path (still exercised
    // unmodified by the pinned grain-mechanism regression tests) and every
    // validated DVS behavior are completely untouched by this addition.

    /// Production default: right-deck direct MIDI drives
    /// `dvsContinuousRenderer` (the same renderer DVS uses) via the
    /// coalescing tick below. `false` disables that routing entirely —
    /// `MacCaptureEngine` then falls back to calling the untouched legacy
    /// `positionDidChange` grain path for right-deck CC6 — a hardware
    /// rollback lever independent of `dvsUsesContinuousRenderer`.
    var midiUsesContinuousRenderer = true

    /// Which control source currently owns `dvsContinuousRenderer`'s single
    /// publication surface. DVS always outranks MIDI. Confined to
    /// `audioQueue` — read and written only from code that already runs
    /// there, so no additional locking is needed.
    private enum PlatterRenderOwner {
        case none
        case dvs
        case midi
    }
    private var platterRenderOwner: PlatterRenderOwner = .none

    /// Authoritative record of whether DVS/timecode is the active control
    /// source, set exclusively by `applyDVSOwnership(active:)`. Unlike
    /// `platterRenderOwner` (which sample load/unload may legitimately
    /// reset to `.none` for bookkeeping), this flag is never touched by
    /// load/unload — DVS's ownership survives a reload performed while it
    /// is active, and `midiCoalescingTick` gates on this flag directly so a
    /// load/unload race can never let MIDI publish while DVS is active.
    private var dvsOwnershipActive = false

    /// Pure velocity/phase-delta estimator for the right-deck coalescing
    /// tick. See `MIDIPlatterContinuousDrive`.
    private var midiContinuousDrive = MIDIPlatterContinuousDrive()

    /// MIDI's own accumulated-steps phase anchor — deliberately independent
    /// of `dvsAccumulatedSteps` (DVS's validated anchor is never read or
    /// written by this path) so the two control sources can never corrupt
    /// each other's rotational phase history. Reuses the exact same
    /// `dvsLoopPhaseFrame`/`framesPerStep`/`stepsPerRevolution` calibration
    /// DVS uses, so the calibration and the 12 o'clock cue mapping are
    /// identical for both sources.
    private var midiContinuousAccumulatedSteps: Double = 0

    /// True while the most recent coalescing tick published real (non-idle)
    /// motion — lets the control side declare inactivity promptly, on the
    /// very next quiet tick, instead of relying on the renderer's own
    /// 0.25 s stale-control fallback.
    private var midiContinuousWasActive = false

    /// Non-nil while the currently loaded sample does not fit within one
    /// physical platter revolution (`dvsLoopFrames`) — the direct-MIDI
    /// continuous path cannot drive it and `midiCoalescingTick` returns
    /// early every tick. Cleared as soon as a compatible sample loads.
    /// Readable for diagnostics/tests; not a UI-facing field itself.
    private(set) var lastMIDIContinuousRejectionReason: String?

    private var midiCoalescingTimer: DispatchSourceTimer?

    /// Reuses the existing MIDI rate limiter already established for the
    /// legacy grain path (`minScheduleInterval`) as the coalescing cadence,
    /// rather than inventing a new one.
    private var midiCoalescingInterval: TimeInterval { minScheduleInterval }

    /// Set once by `MacCaptureEngine` after both the platter tracker and
    /// this controller exist. Reads `ScratchPlatterTracker
    /// .accumulatedSteps(for:)` for the right deck (channel 1) only — the
    /// tracker is documented safe to call from any thread, so calling it
    /// from `audioQueue`'s coalescing timer is safe without extra locking.
    /// Left-deck (channel 0) steps are never read here: the isolation rule
    /// is structural, not a runtime check.
    private var rightDeckAccumulatedStepsProvider: (() -> Int)?

    /// Wires the right-deck steps provider and starts the real-time
    /// coalescing timer (idempotent). Safe to call from any thread.
    func configureMIDIPlatterProvider(rightDeckAccumulatedSteps provider: @escaping () -> Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.rightDeckAccumulatedStepsProvider = provider
            if self.midiCoalescingTimer == nil {
                self.startMIDICoalescingTimer()
            }
        }
    }

    /// Starts the right-deck MIDI coalescing timer once, at the existing
    /// MIDI cadence, on `audioQueue` — the same `DispatchSource.makeTimerSource`
    /// pattern already established by `beginStopRamp`/`audioSignalDecayTimer`.
    /// The timer callback runs directly on `audioQueue` (no additional
    /// dispatch hop), so it is naturally serialized with every DVS tick,
    /// ownership change, load, and unload.
    private func startMIDICoalescingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        midiCoalescingTimer = timer
        timer.schedule(deadline: .now(), repeating: midiCoalescingInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.midiCoalescingTick()
        }
        timer.resume()
#if DEBUG
        testOnly_midiCoalescingTimerStartCount += 1
#endif
    }
#if DEBUG
    /// Test-only: counts real `startMIDICoalescingTimer` invocations —
    /// proves `configureMIDIPlatterProvider`'s idempotent-start guard
    /// deterministically, without depending on real-time tick counts.
    private(set) var testOnly_midiCoalescingTimerStartCount = 0
#endif

    /// Bounded cancellation, mirroring `cancelStopRamp()`: clears the event
    /// handler before cancelling so no further tick can fire once this
    /// returns, then releases the timer. Called only from `stopEngine()`
    /// (controller teardown / `deinit`) — never on ordinary platter idle —
    /// so the timer keeps running, and `configureMIDIPlatterProvider`
    /// remains free to restart it later, for the controller's entire
    /// lifetime while it is alive.
    private func cancelMIDICoalescingTimer() {
        midiCoalescingTimer?.setEventHandler {}
        midiCoalescingTimer?.cancel()
        midiCoalescingTimer = nil
    }

    /// Called by `MacCaptureEngine.setDVSPlaybackDriveActive` — the single
    /// authoritative signal for whether the timecode/DVS control source is
    /// currently allowed to drive playback. Active DVS always has priority:
    /// while active, MIDI continuous publication is suppressed
    /// unconditionally and any in-flight MIDI ownership is released with a
    /// click-free idle publish; when DVS relinquishes, MIDI's drive history
    /// is reset so a stale pre-handoff delta/time pair can never resume as
    /// a catch-up burst.
    func setDVSOwnership(active: Bool) {
        audioQueue.async { [weak self] in
            self?.applyDVSOwnership(active: active)
        }
    }

    private func applyDVSOwnership(active: Bool) {
        // Idempotent on the authoritative flag itself, not on
        // `platterRenderOwner` — a reload performed while DVS is active
        // re-forces `platterRenderOwner` back to `.dvs` (see
        // `applyLoadedBufferState`/`unload`), so gating on that field would
        // make a repeated `active: true` call after a reload incorrectly
        // re-run the handoff side effects below.
        guard dvsOwnershipActive != active else { return }
        dvsOwnershipActive = active

        if active {
            if platterRenderOwner == .midi {
                dvsContinuousRenderer.publishIdle()
            }
            platterRenderOwner = .dvs
            midiContinuousDrive.reset()
            midiContinuousWasActive = false
        } else {
            platterRenderOwner = .none
            dvsContinuousRenderer.publishIdle()
            // Rebase MIDI's own phase anchor to the position DVS left the
            // audible sample at, using the exact inverse of the mapping
            // MIDI itself publishes through (`midiLoopPhaseFrame`):
            // frame = (steps * midiFramesPerStep) mod loop, so
            // steps = frame / midiFramesPerStep reproduces that frame
            // exactly. Uses MIDI's own geometry (`midiFramesPerStep`), not
            // DVS's (`framesPerStep`) — cue-lock drift fix, 2026-08-10 —
            // because `midiCoalescingTick` immediately converts this same
            // anchor back to a frame position via `midiLoopPhaseFrame`;
            // rebasing with the wrong scale would produce a visible phase
            // jump on every DVS→MIDI handoff.
            // `currentSampleFrame` is DVS's own control-side authoritative
            // phase (maintained on `audioQueue` by
            // `positionDidChangeOnQueue`/`renderContinuousDVSTick`, never
            // read from the render thread), retained through DVS's own
            // idle ticks, so it is always "wherever DVS left it" — without
            // this rebase, `midiContinuousAccumulatedSteps` stays frozen at
            // its stale pre-handoff value and the first real post-handoff
            // MIDI tick would publish a wrong authoritative phase, which
            // the renderer's bounded correction would then visibly correct
            // toward. This only repoints MIDI's own control-side anchor —
            // the renderer's audible phase (never reset by an idle
            // publish) is untouched.
            if midiFramesPerStep > 0 {
                midiContinuousAccumulatedSteps = Double(currentSampleFrame) / midiFramesPerStep
            }
            // MIDI resumes from a clean delta/time baseline — no stale
            // pre-handoff delta/time pair carried across the handoff, so
            // the very next real tick cannot replay a suppressed backlog
            // as a catch-up burst. The next timer tick after this reset is
            // therefore a priming call (no publish); the one after that
            // continues from the rebased anchor above with only the new
            // real MIDI delta.
            midiContinuousDrive.reset()
            midiContinuousWasActive = false
        }
    }

    /// One coalesced right-deck MIDI control tick. Runs on `audioQueue`
    /// (the timer's own queue). Reads the right deck's accumulated CC6
    /// steps at this bounded cadence — never per raw MIDI event — derives a
    /// signed velocity from real elapsed time, and publishes to the exact
    /// same `dvsContinuousRenderer` DVS uses, only while MIDI currently
    /// owns it (DVS always wins; see `applyDVSOwnership`).
    private func midiCoalescingTick() {
        guard midiUsesContinuousRenderer,
              !dvsOwnershipActive,
              let provider = rightDeckAccumulatedStepsProvider,
              let forward = forwardBuffer
        else { return }

        // A sample longer than one physical platter revolution cannot enter
        // the direct-MIDI continuous path — the same one-revolution-loop
        // constraint DVS itself requires (see `dvsLoopFrames`'s doc
        // comment). Surfaced as a clear, readable diagnostic (rather than a
        // silent no-op) so a mismatched sample choice — e.g. a ~4.5 s
        // hot-cue pad clip instead of the validated ~1.05 s platter asset —
        // is never mistaken for a platter/MIDI hardware problem. Supporting
        // longer samples on this path is explicitly out of scope; that
        // belongs to the later hot-cue/sample-mapping design.
        guard dvsLoopFrames > 0, Double(forward.frameLength) <= dvsLoopFrames else {
            if lastMIDIContinuousRejectionReason == nil {
                let reason = "sample \(forward.frameLength) frames exceeds one platter " +
                    "revolution (\(Int(dvsLoopFrames)) frames) — direct-MIDI continuous drive rejected"
                lastMIDIContinuousRejectionReason = reason
                print("[ScratchSamplePlaybackController] \(reason)")
            }
            return
        }
        if lastMIDIContinuousRejectionReason != nil {
            lastMIDIContinuousRejectionReason = nil
        }

        let now = schedulingClock()
        let steps = provider()
        guard let result = midiContinuousDrive.tick(accumulatedSteps: steps, now: now) else {
            return // Priming: baseline captured, nothing to publish yet.
        }

        // The full signed delta always folds into the phase anchor, even on
        // a tick whose velocity was sanitized to 0 — real motion is never
        // lost, matching the DVS anchor's own "never lose real steps"
        // contract (see `dvsAccumulatedSteps`).
        if result.deltaSteps != 0 {
            midiContinuousAccumulatedSteps += result.deltaSteps
        }

        guard result.velocity != 0 else {
            // No sane motion this tick: publish idle promptly — the
            // control side owns this decision on its own bounded cadence,
            // rather than waiting on the renderer's 0.25 s staleness
            // fallback — but only once, on the active -> idle transition,
            // not on every already-quiet tick.
            if midiContinuousWasActive {
                midiContinuousWasActive = false
                platterRenderOwner = .midi
                dvsContinuousRenderer.publishIdle()
            }
            return
        }

        platterRenderOwner = .midi
        midiContinuousWasActive = true
        let phase = midiLoopPhaseFrame(forAccumulatedSteps: midiContinuousAccumulatedSteps)
        dvsContinuousRenderer.publish(
            velocity: result.velocity * midiFramesPerStep,
            authoritativePhase: phase,
            active: true
        )
        if isEngineRunningForPlayback(), !playerNode.isPlaying {
            playerNode.play()
        }
        currentSampleFrame = Int(phase)
    }

#if DEBUG
    /// Test-only: injects the right-deck steps provider without starting
    /// the real-time coalescing timer, so deterministic tests can drive
    /// `testOnly_midiCoalescingTick()` on their own schedule.
    func testOnly_setRightDeckAccumulatedStepsProvider(_ provider: @escaping () -> Int) {
        audioQueue.sync { self.rightDeckAccumulatedStepsProvider = provider }
    }

    /// Test-only: drives exactly one coalesced MIDI control tick
    /// synchronously on `audioQueue`, bypassing the real-time timer so
    /// tests can advance the drive deterministically.
    func testOnly_midiCoalescingTick() {
        audioQueue.sync { self.midiCoalescingTick() }
    }

    /// Test-only: exercises the exact teardown cancellation helper
    /// (`cancelMIDICoalescingTimer`) without requiring controller
    /// deallocation, so the bounded-cancellation contract can be verified
    /// deterministically.
    func testOnly_cancelMIDICoalescingTimer() {
        audioQueue.sync { self.cancelMIDICoalescingTimer() }
    }

    /// Test-only: true while MIDI currently owns `dvsContinuousRenderer`.
    var testOnly_midiOwnsPlatterRender: Bool {
        var owns = false
        audioQueue.sync { owns = (platterRenderOwner == .midi) }
        return owns
    }

    /// Test-only: true while DVS currently owns `dvsContinuousRenderer`.
    var testOnly_dvsOwnsPlatterRender: Bool {
        var owns = false
        audioQueue.sync { owns = (platterRenderOwner == .dvs) }
        return owns
    }

    /// Test-only: the authoritative DVS-active flag `midiCoalescingTick`
    /// gates on directly (see `dvsOwnershipActive`).
    var testOnly_dvsOwnershipActive: Bool {
        var active = false
        audioQueue.sync { active = dvsOwnershipActive }
        return active
    }

    /// Test-only: MIDI's own control-side phase anchor, in MIDI step units
    /// (see `midiContinuousAccumulatedSteps`).
    var testOnly_midiContinuousAccumulatedSteps: Double {
        var steps = 0.0
        audioQueue.sync { steps = midiContinuousAccumulatedSteps }
        return steps
    }

    /// Test-only: true while the coalescing timer is currently running.
    var testOnly_midiCoalescingTimerActive: Bool {
        var active = false
        audioQueue.sync { active = (midiCoalescingTimer != nil) }
        return active
    }
#endif

    // MARK: - Serial audio queue

    // All AVAudioEngine, AVAudioPlayerNode, AVAudioFile, and AVAudioPCMBuffer
    // work is confined here. Public methods async-dispatch to it and return
    // immediately, keeping the CoreMIDI callback thread unblocked.
    private let audioQueue = DispatchQueue(
        label: "com.scratchlab.samplePlayback",
        qos: .userInteractive
    )
    /// Marks `audioQueue` so `runSynchronouslyOnAudioQueue` can tell whether
    /// it is already executing there and avoid a self-deadlocking `sync`.
    private let audioQueueKey = DispatchSpecificKey<Void>()
    private let schedulingClock: () -> TimeInterval

    // MARK: - Loaded sample state (access confined to audioQueue)

    private(set) var loadedSampleID: String?
    private var forwardBuffer: AVAudioPCMBuffer?
    private(set) var totalFrames: Int = 0
    private var lastScheduledSteps: Double = 0
    private var lastScheduledDirection: ScratchPlatterDirection?
    private var lastScheduleTime: Double = 0
    private var diagnosticPreviewPlayedSampleID: String?
    private(set) var currentSampleFrame: Int = 0
    private var lastPlatterSteps: Double?
    private var framesPerStep: Double = 1
    /// Direct-MIDI-only counterpart to `framesPerStep`, derived from
    /// `raneOneMKIIDirectMIDIStepsPerRevolution` instead of
    /// `stepsPerRevolution`. See that constant's doc comment.
    private var midiFramesPerStep: Double = 1

    /// Last raw absolute step count passed to `positionDidChange(steps:
    /// Int, ...)` (MIDI CC6 path). Used only to compute this call's delta
    /// via overflow-safe `Int` subtraction — never converted to `Double`
    /// directly. See `midiAccumulatedSteps`.
    private var lastRawMIDISteps: Int?

    /// Running `Double` sum of real MIDI step deltas since load — mirrors
    /// `dvsAccumulatedSteps`/`TimecodeDriveStepConverter.continuousSteps`.
    /// `positionDidChange(steps: Int, ...)` takes an ever-growing absolute
    /// step count from the caller (it can reach `Int.max/2`-scale over a
    /// long session); converting that directly to `Double` loses enough
    /// precision at that magnitude that two absolute values 12 steps apart
    /// can round to the identical `Double`, collapsing the delta to zero
    /// and silently freezing playback. Accumulating only the (always tiny)
    /// per-call `Int` delta avoids the cliff entirely.
    private var midiAccumulatedSteps: Double = 0

    /// Listening-fix #4 (rotational mapping, uncommitted): one physical
    /// platter revolution's worth of frames — `framesPerStep *
    /// stepsPerRevolution`, i.e. exactly the same 1.8 s/rev constant
    /// `framesPerStep` already encodes, just expressed as a frame count
    /// instead of a per-step rate. DVS-only. Always `>= totalFrames` for
    /// the current "ahh" asset (1.05 s content inside a 1.8 s revolution),
    /// so `[0, totalFrames)` is real audio and `[totalFrames,
    /// dvsLoopFrames)` is the silence that pads the loop out to one full
    /// revolution — see `dvsLoopPhaseFrame`/`copyDVSLoopSegment`. The MIDI
    /// hot-cue-pad path does not use this: pad samples intentionally loop
    /// at their own length (`totalFrames`) regardless of platter RPM (see
    /// the comment in `loadOnQueue` above `framesPerStep`).
    private(set) var dvsLoopFrames: Double = 0

    /// Listening-fix #4 (uncommitted): cumulative REAL platter steps
    /// decoded since load (signed, DVS-only). The DVS sample position is
    /// always derived fresh from this value via `dvsLoopPhaseFrame` rather
    /// than incremented independently, so it can never accumulate drift:
    /// equal-and-opposite motion always nets back to the same value bit-
    /// for-bit, hence the same loop phase. Reversal-audibility compensation
    /// (`effectiveFrameDelta` below) affects only how much source audio a
    /// grain renders, never this accumulator.
    private var dvsAccumulatedSteps: Double = 0

    #if DEBUG
    /// Hardware-verification instrumentation only (SCRATCHLAB_DVS_TRACE=1):
    /// an in-progress candidate for one uninterrupted, single-direction
    /// physical revolution, so `[DVS-TRACE:9]` can report each *genuine*
    /// completed lap's real step length as it happens — the measurement
    /// the calibration question in `dvsLoopFrames`'s doc comment needs:
    /// candidate revolution periods and their consistency, from a live
    /// session, rather than inferring lap count after the fact.
    ///
    /// A naive "phase wrapped since last time" check is not reversal-safe:
    /// a scratch that straddles the loop boundary (forward across it, then
    /// back) satisfies the wrap condition twice in quick succession without
    /// a real revolution ever completing. `nil` means "no candidate in
    /// progress" — set on load/unload, on any direction change, on a
    /// detected dropout (`noDirection`), and on a detected scheduling gap
    /// (stop/resume), so a completed lap can only ever be reported for an
    /// uninterrupted run in one direction with no untrusted gap in it.
    private var dvsLapCandidate: DVSLapCandidate?

    private struct DVSLapCandidate {
        let direction: ScratchPlatterDirection
        let startAccumulatedSteps: Double
        let startPhase: Double
        let startUptime: TimeInterval
        var travelledDistance: Double = 0
        var tickCount: Int = 0
    }
    #endif

    private(set) var lastScheduledSourceFrame: Int?
    private(set) var lastScheduledSegmentFrames: Int?
    private(set) var lastScheduledRate: Float?
    private(set) var lastScheduleSkippedReason: String?
    private(set) var lastEffectiveFrameDelta: Int?
    private(set) var lastReversalCompensated: Bool = false
    private var forwardScheduleCount = 0
    private var backwardScheduleCount = 0
    private(set) var pendingDVSControlWindow: TimeInterval = 0
    private(set) var estimatedDVSQueuedDuration: TimeInterval = 0
    private var lastDVSQueueEstimateAt: TimeInterval?
    private(set) var lastDVSConsumedControlWindow: TimeInterval?
    private(set) var lastDVSScheduledOutputWindow: TimeInterval?

#if DEBUG
    /// CACurrentMediaTime of the most recent `positionDidChange` entry — for measuring
    /// elapsed between consecutive calls at this layer. Read by [DVS-TRACE:4].
    private var _lastPositionDidChangeTime: TimeInterval = 0

    /// Whether the player node is currently playing. Exposed for cross-module trace
    /// logging (MacCaptureEngine reads it for [DVS-TRACE:3]).
    var isPlaying: Bool { playerNode.isPlaying }

    /// One real scheduled grain exactly as queued onto `playerNode` — the
    /// PCM (post edge-fade, post time-stretch) plus the timing metadata
    /// needed to reconstruct actual output-time placement offline, without a
    /// running AVAudioEngine/device.
    struct ScheduledGrainSnapshot {
        let direction: ScratchPlatterDirection
        let interrupts: Bool
        let nodeRate: Float
        let scheduledOutputWindow: TimeInterval
        let sourceFrame: Int
        let sampleRate: Double
        let channelData: [[Float]]
        /// Whether this grain went through `copyTimeStretched` — the sub-0.25x
        /// software time-stretch path used when the physical rate falls below
        /// `AVAudioUnitVarispeed`'s floor. Lets offline diagnosis separate
        /// software-stretched grain boundaries from normal-varispeed ones.
        let usesSoftwareSlowGrain: Bool
        /// Raw source-frame count feeding `copyTimeStretched` before
        /// stretching (i.e. `segmentFrames`) — how few real samples were
        /// available to reconstruct the grain's full output window.
        let rawSourceFrameCount: Int
        /// `schedulingClock()` value at the moment this grain was handed to
        /// `scheduleBuffer` — NOT a real CoreAudio render-timeline
        /// timestamp (this class never reads one; `scheduleBuffer(at: nil,
        /// ...)` queues after whatever AVAudioPlayerNode already has
        /// buffered, and that real timeline is not observable from here).
        /// Paired with `scheduledOutputWindow`, this is the same
        /// control-side estimate `dvsOutputTiming()`/the gap-detection
        /// head-fade logic already uses: `scheduledAtUptime +
        /// scheduledOutputWindow` is this grain's *expected* output end,
        /// and comparing it against the next grain's `scheduledAtUptime`
        /// shows a control-side gap or overlap in the scheduling
        /// bookkeeping. It does not, and cannot, prove what the audio
        /// hardware actually rendered.
        let scheduledAtUptime: TimeInterval
    }

    /// Test/diagnostic-only hook: invoked synchronously on the audio queue
    /// immediately before `scheduleBuffer`, with the exact buffer and timing
    /// that was queued. `nil` by default; production and hardware code paths
    /// never set it, and setting it does not change what gets scheduled.
    /// Used by the offline scheduled-grain renderer to reconstruct real
    /// playback in a WAV for discontinuity/overlap/underrun diagnosis.
    var scheduledGrainObserver: ((ScheduledGrainSnapshot) -> Void)?

    /// A single validated, uninterrupted, single-direction DVS revolution
    /// candidate that completed (reported alongside `[DVS-TRACE:9]`, but
    /// unconditionally — not gated behind `SCRATCHLAB_DVS_TRACE`, which is
    /// read once at process launch and so can't be toggled from within a
    /// test). See `dvsLapCandidate`'s doc comment for the reversal-safety
    /// invariant this reports.
    struct DVSLapSnapshot {
        let direction: ScratchPlatterDirection
        let lapSteps: Double
        let startPhase: Double
        let endPhase: Double
        let tickCount: Int
        let elapsedSeconds: TimeInterval
    }

    /// Test/diagnostic-only hook, same contract as `scheduledGrainObserver`:
    /// invoked synchronously on the audio queue whenever a lap candidate is
    /// validated and reported as a completed revolution. `nil` by default;
    /// production and hardware code paths never set it.
    var dvsLapCompletedObserver: ((DVSLapSnapshot) -> Void)?

    /// Diagnostic record of a PCM join between two consecutively scheduled
    /// grains.  All fields are scalars — no Array or reference-type fields,
    /// so storage and copy are a bounded memcpy (~200 bytes).  Computed
    /// when `grainJoinObserver` is set (tests) or `DVSTrace.isEnabled` is
    /// true (hardware trace).  Production/hardware code paths never create
    /// these.
    struct GrainJoinDiagnostic {
        // --- Timing (control-side, not hardware render timestamps) ---
        let previousScheduledAtUptime: TimeInterval
        let currentScheduledAtUptime: TimeInterval
        let previousOutputWindow: TimeInterval
        let currentOutputWindow: TimeInterval
        let estimatedPreviousEnd: TimeInterval
        /// Control-side gap: positive = gap, negative = overlap.
        let estimatedControlGap: TimeInterval
        // --- Phase ---
        let previousSourceFrame: Int
        let currentSourceFrame: Int
        let direction: ScratchPlatterDirection
        // --- PCM join (first channel, extracted from buffer pointers) ---
        let previousLastSample: Float
        let currentFirstSample: Float
        let joinDiscontinuity: Float
        let previousInternalMaxStep: Float
        let currentInternalMaxStep: Float
        let crossesPhaseBoundary: Bool
        // --- Scheduling flags ---
        let previousInterrupts: Bool
        let currentInterrupts: Bool
        let previousUsesSlowGrain: Bool
        let currentUsesSlowGrain: Bool
        let previousRawFrameCount: Int
        let currentRawFrameCount: Int
    }

    /// Test/diagnostic-only hook: invoked synchronously on the audio queue
    /// whenever two consecutive grains produce a join diagnostic.  `nil` by
    /// default; production and hardware code paths never set it.
    var grainJoinObserver: ((GrainJoinDiagnostic) -> Void)?

    /// Lightweight scalar-only record of one grain's join-relevant state,
    /// extracted directly from buffer pointers — no Array allocation, safe
    /// on the audio scheduling queue.  Stored only to pair with the next
    /// grain for join computation.
    private struct GrainScalarSnapshot {
        let scheduledAtUptime: TimeInterval
        let scheduledOutputWindow: TimeInterval
        let sourceFrame: Int
        let direction: ScratchPlatterDirection
        let interrupts: Bool
        let usesSlowGrain: Bool
        let rawFrameCount: Int
        let lastSample: Float          // first channel, last frame
        let internalMaxStep: Float     // first channel max |Δ|
        let crossesPhaseBoundary: Bool
    }
    /// Previous grain's scalar snapshot for join computation.  `nil` after
    /// load, unload, or a scheduling gap (noDirection).
    private var previousGrainScalars: GrainScalarSnapshot?

    /// Preallocated bounded ring for `GrainJoinDiagnostic` entries, written
    /// on the audio queue when `DVSTrace.isEnabled` and read (flush/export)
    /// off the audio queue.  Capacity fixed at init; push is an indexed
    /// struct copy (memcpy) with no allocation, lock, or I/O.
    private var dvsGrainRing: [GrainJoinDiagnostic?] = []
    private let dvsGrainRingCapacity = 256
    private var dvsGrainRingWriteIndex = 0

    /// Preallocate ring storage.  Called once from `init` (main thread);
    /// after this, `dvsGrainRingPush` does no allocation.
    private func dvsGrainRingPreallocate() {
        dvsGrainRing = Array(repeating: nil, count: dvsGrainRingCapacity)
    }

    /// Indexed assignment into the preallocated ring — one struct copy, no
    /// allocation.  Called only from the audio scheduling queue.
    private func dvsGrainRingPush(_ join: GrainJoinDiagnostic) {
        dvsGrainRing[dvsGrainRingWriteIndex % dvsGrainRingCapacity] = join
        dvsGrainRingWriteIndex &+= 1   // wrapping add, overflow is harmless
    }

    /// Flushes all recorded entries in write order (oldest first), resets
    /// the ring, and returns the flushed entries.  Must NOT be called from
    /// the audio queue (allocates result array).
    func dvsGrainRingFlush() -> [GrainJoinDiagnostic] {
        let total = dvsGrainRingWriteIndex
        guard total > 0, !dvsGrainRing.isEmpty else { return [] }
        let count = min(total, dvsGrainRingCapacity)
        let start = total > dvsGrainRingCapacity
            ? total % dvsGrainRingCapacity : 0
        var result: [GrainJoinDiagnostic] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let idx = (start &+ i) % dvsGrainRingCapacity
            if let entry = dvsGrainRing[idx] {
                result.append(entry)
            }
        }
        dvsGrainRing.removeAll(keepingCapacity: true)
        dvsGrainRingWriteIndex = 0
        return result
    }

    /// Extracts scalar join-relevant data directly from buffer pointers —
    /// no Array, no heap allocation, safe on the audio scheduling queue.
    private static func extractGrainScalars(
        from buffer: AVAudioPCMBuffer,
        sourceFrame: Int,
        direction: ScratchPlatterDirection,
        interrupts: Bool,
        usesSlowGrain: Bool,
        rawFrameCount: Int,
        scheduledOutputWindow: TimeInterval,
        scheduledAtUptime: TimeInterval,
        isDVSLoop: Bool
    ) -> GrainScalarSnapshot? {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return nil }
        let fc = Int(buffer.frameLength)
        let lastIdx = fc - 1
        let ptr = channels[0]

        // Boundary samples.
        let first = ptr[0]
        let last = ptr[lastIdx]

        // Max internal |Δ|.
        var maxStep: Float = 0
        for i in 1..<fc {
            maxStep = max(maxStep, abs(ptr[i] - ptr[i - 1]))
        }

        // Phase boundary crossing (exact-zero vs non-zero within grain).
        var hasZero = false, hasNonZero = false
        for i in 0..<fc {
            if ptr[i] == 0 { hasZero = true }
            else { hasNonZero = true }
            if hasZero && hasNonZero { break }
        }

        return GrainScalarSnapshot(
            scheduledAtUptime: scheduledAtUptime,
            scheduledOutputWindow: scheduledOutputWindow,
            sourceFrame: sourceFrame,
            direction: direction,
            interrupts: interrupts,
            usesSlowGrain: usesSlowGrain,
            rawFrameCount: rawFrameCount,
            lastSample: last,
            internalMaxStep: maxStep,
            crossesPhaseBoundary: isDVSLoop && hasZero && hasNonZero
        )
    }

    /// Full channel-data copy for test/diagnostic snapshots.  Allocates
    /// `[[Float]]` — only called when `scheduledGrainObserver` is set
    /// (tests), never on the hardware trace path.
    private func channelData(of buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: frameCount))
        }
    }
#endif

    /// Set when the most recent `loadOnQueue` attempt failed after the
    /// synchronous URL-resolution check passed (file open error, unreadable
    /// PCM, etc.) — the failure class `ensureLoadedForDVSDrive`'s boolean
    /// return value cannot report, because that return only reflects
    /// whether a load was successfully *queued*, not whether the queued
    /// load actually completed. `nil` after a successful load. Cleared at
    /// the start of every load attempt so a stale error from a previous
    /// sample doesn't linger.
    private(set) var lastLoadError: String?

    // MARK: - Rate-limit / segment constants

    /// Minimum interval between scheduleBuffer calls (seconds).
    private let minScheduleInterval: Double = 1.0 / 60.0

    /// Segment duration scheduled per position update (seconds).
    private let segmentDuration: Double = 1.0 / 60.0

    /// Nominal vinyl RPM for normal-speed playback (33⅓ RPM).
    private static let nominalVinylRPM: Double = 100.0 / 3.0

    /// Controller steps per platter revolution (Rane ONE MKII CC6).
    /// DVS/timecode-only — see `raneOneMKIIDirectMIDIStepsPerRevolution`
    /// for the direct-MIDI value. Left unchanged by the 2026-08-10
    /// direct-MIDI geometry correction.
    private let stepsPerRevolution: Int = 3932

    /// Direct-MIDI-only steps-per-revolution for the Rane ONE MKII right
    /// platter (cue-lock drift fix, 2026-08-10). Measured from two
    /// anomaly-free powered-rotation hardware runs (zero CoreMIDI delivery
    /// gaps, signed/absolute ratio 1.0000, 20 revolutions each): 3602.95
    /// and 3598.65 steps/rev, confirmed as 3600. `stepsPerRevolution`
    /// above is tuned for DVS/timecode and does not describe this
    /// device's direct-MIDI CC6 resolution — the two consistently
    /// disagreed by ~8.4% in hardware measurement, which is what produced
    /// the reported clockwise cue drift on direct-MIDI right-platter
    /// scratching. Internal (not private): shared with
    /// `MacCaptureEngine`'s direct-MIDI lap diagnostic and with tests via
    /// `@testable import`, so the value 3600 exists as a literal in
    /// exactly one place.
    static let raneOneMKIIDirectMIDIStepsPerRevolution: Int = 3600

    /// Minimum CC6 step delta that produces a continuous-sounding grain.
    /// Below ~9 steps/slot at 33⅓ RPM, the varispeed floor (0.25) cannot
    /// stretch the grain to fill the 16.7 ms scheduling slot, producing a
    /// rapid on/off/on sputter ("farting"). Silently track the needle;
    /// suppress the grain.
    private let minAudibleDeltaSteps = 9

    /// Maximum frameDelta to borrow from the previous direction when
    /// compensating the first grain after a reversal. Caps the symmetry
    /// compensation so a very fast push doesn't produce a pathological
    /// jump on the matching return stroke. ~1500 frames ≈ 34 ms of audio.
    private let reversalSymmetryCapFrames = 1500

    /// Varispeed rate clamps — mirrors AVAudioUnitVarispeed's supported range.
    private let minVarispeedRate: Float = 0.25
    private let maxVarispeedRate: Float = 4.0

    /// A small output-time reserve maintained by DVS grains. The control
    /// worker and the audio device are independent clocks; scheduling exactly
    /// one elapsed control window on every timer callback leaves no protection
    /// against ordinary sub-millisecond timer jitter and produces underruns.
    ///
    /// The reserve is restored only when the estimate falls below this target,
    /// so it remains bounded instead of adding latency on every grain.
    private let dvsQueueCushion: TimeInterval = 0.004

    /// Matches the control pipeline's maximum trusted elapsed interval. It also
    /// bounds accumulated zero-step/early-tick time after a scheduling stall.
    private let maximumDVSControlWindow: TimeInterval = 0.25

    /// PCM frames ramped from/to zero at the leading and trailing edge of each
    /// scheduled scratch grain. The ramp smooths the hard PCM cut that would
    /// otherwise cause a click when the waveform value at the cut point is non-zero.
    /// Clamped to at most half the grain's frame count, so tiny grains are never
    /// fully zeroed. Not applied to the diagnostic load preview.
    let grainEdgeFadeFrames = 32

    // MARK: - Engine state

    private var engineStarted = false
    // engineLock guards engineStarted across deinit (any thread) and
    // ensureEngineRunning (audioQueue), preventing concurrent start/stop.
    private let engineLock = NSLock()

    // MARK: - Published state (main thread only)

    @Published var statusLabel: String = "idle"
    @Published var crossfaderGate: Float = 1.0
    @Published var lastCrossfaderRawValue: Int? = nil

    // MARK: - Click-free stop ramp (generation-protected)

    // MARK: - Click-free stop ramp (audioQueue-owned, generation-protected)

    /// Bumped on `audioQueue` only: every new `pausePlayback()` /
    /// `resumePlayback()` / `unload()` / `stopEngine()` invalidates any
    /// in-flight ramp. The ramp timer, every volume write, the final `stop()`
    /// and cancellation all run on `audioQueue`, so a quick resume on the same
    /// serialized queue can never be followed by a stale ramp step or stop.
    private var stopRampGeneration = 0
    private var stopRampTimer: DispatchSourceTimer?
    /// Raised-cosine gain curve (smooth derivative at both ends) over ~10 ms.
    private let stopRampSteps = 10
    private let stopRampStepInterval: TimeInterval = 0.001

    private func cancelStopRamp() {
        stopRampTimer?.setEventHandler {}
        stopRampTimer?.cancel()
        stopRampTimer = nil
    }

    /// Starts a bounded ~10 ms output-gain ramp ending in `playerNode.stop()`.
    /// Must be called on `audioQueue`; the timer is owned by `audioQueue`.
    /// Every step re-verifies `stopRampGeneration` on the same serialized
    /// queue before writing `playerNode.volume`, so a `resumePlayback()` /
    /// `unload()` / `stopEngine()` that already bumped the generation
    /// synchronously invalidates every subsequent step and the final stop.
    private func beginStopRamp() {
        stopRampGeneration += 1
        let generation = stopRampGeneration
        cancelStopRamp()

        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        stopRampTimer = timer
        timer.schedule(deadline: .now(), repeating: stopRampStepInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Serialized on audioQueue: the generation can only differ here if
            // resume/unload/stop ran on this same queue before this event.
            guard self.stopRampGeneration == generation else {
                timer.cancel()
                return
            }
            step += 1
            if step >= self.stopRampSteps {
                timer.cancel()
                self.playerNode.stop()
                self.playerNode.volume = 1.0
                self.dvsDefinitivelyStopped = true
                self.dvsRestartMotionTicks = 0
#if DEBUG
                self.finishOutputCaptureIfArmed(only: .automatic)
#endif
                return
            }
            // Raised-cosine: gain = cos(t·π/2)²  →  1 at step 0, 0 at step n.
            let t = Float(step) / Float(self.stopRampSteps)
            let cosine = cos(t * .pi / 2)
            self.playerNode.volume = cosine * cosine
        }
        timer.resume()
    }

    /// Test/diagnostic read of the current player-node output gain. Volume is
    /// atomic on `AVAudioPlayerNode`; used by the stop-ramp race test to prove
    /// a quick resume leaves the volume exactly 1.0.
    var currentPlayerVolume: Float { playerNode.volume }

    /// DVS-only auto-stop transition tracking (production lifecycle): true
    /// while the DVS path has been scheduling real grains, so the click-free
    /// stop ramp fires only on the motion -> noDirection transition, never on
    /// every 60 Hz idle tick.
    private var wasDVSMotionActive = false
    /// Near-stop settling hysteresis: true once the DVS auto-stop ramp has
    /// COMPLETED (player node stopped) — or the platter was already idle at a
    /// nil tick — until sustained deliberate motion resumes. While true, small
    /// valid motion ticks are silenced (phase still accumulates) until
    /// `dvsRestartMotionTickThreshold` consecutive ticks prove deliberate
    /// motion; motion at/above `minAudibleDeltaSteps` resumes immediately.
    /// Prevents settling jitter from re-arming the player for one isolated
    /// short grain per wobble and re-stopping it on the next nil tick (the
    /// repeated sparse burst/static heard near stop).
    private var dvsDefinitivelyStopped = false
    /// Consecutive valid DVS motion ticks observed while definitively stopped,
    /// without an intervening nil-direction tick.
    private var dvsRestartMotionTicks = 0
    /// Consecutive motion ticks required before an audible restart after a
    /// definitive stop (2 x 1/60 s ≈ 33 ms of sustained motion).
    private let dvsRestartMotionTickThreshold = 2
    /// Test/diagnostic counters for the production noDirection auto-stop path.
    private(set) var dvsAutoStopRampStartCount = 0
    private(set) var dvsCaptureFinalizeCount = 0

    /// Called on `audioQueue` from the real DVS scheduling path whenever a
    /// grain is about to be scheduled while a click-free stop ramp is in
    /// flight: invalidates the ramp (generation bump + timer cancel on this
    /// same serialized queue) and restores unity volume, so the stale ramp
    /// can never stop newly scheduled playback. Platter phase and accumulated
    /// steps are untouched.
    private func cancelPendingDVSAutoStopIfRamping() {
        guard stopRampTimer != nil else { return }
        stopRampGeneration += 1
        cancelStopRamp()
        playerNode.volume = 1.0
    }

#if DEBUG
    // MARK: - Post-mixer output capture (bounded, DEBUG-only, env-gated)

    /// One-shot capture of the engine's post-mixer output so live-only playback
    /// artifacts (queue starvation gaps, resample/SRC noise, node timing) can
    /// be measured on real hardware without touching the render callback.
    /// Env-gated (`SCRATCHLAB_CAPTURE_OUTPUT=1`) so it is off by default.
    /// Concurrency model: while the tap is installed ONLY the render callback
    /// touches the ring and the write index (no locks, no allocation, no
    /// logging, no file I/O on the render thread; there is no recurring
    /// exporter reading them). Capture finishes on the controller/audio queue:
    /// the mixer tap is removed first so no callback can still be executing,
    /// and only then is the immutable chronological range dispatched to the
    /// export queue for WAV writing. For the hardware test, capture finishes
    /// when the generation-protected stop ramp completes (pausePlayback) or on
    /// engine stop. Capacity is sized from the actual mixer sample rate x 30s.
    private static let outputCaptureEnabled =
        ProcessInfo.processInfo.environment["SCRATCHLAB_CAPTURE_OUTPUT"] == "1"
    private var outputCaptureRingFrames = 0   // mixerSampleRate * 30
    private var outputCaptureRing: UnsafeMutablePointer<Float>?
    private var outputCaptureWriteFrames = 0  // render-callback owned while armed
    private var outputCaptureArmed = false

    /// Ownership of the currently armed output capture (nil when not armed).
    /// `.automatic`: env-gated capture the motion→idle stop ramp may finalize.
    /// `.manual`: explicit diagnostics capture only "Stop & Export" finalizes.
    private var outputCaptureOwnership: OutputCaptureOwnership?

    enum OutputCaptureOwnership {
        case automatic
        case manual
    }
    private var outputCaptureRate: Double = 44_100
    private let outputCaptureExportQueue = DispatchQueue(label: "com.scratchlab.controller.captureExport", qos: .utility)

#if DEBUG
    /// Test/diagnostic read of how many mixer frames the tap captured before
    /// finalization (0 while unarmed). Not safe while the tap is installed;
    /// used only after finalization in tests/drivers.
    var outputCaptureWrittenFramesProbe: Int { outputCaptureWriteFrames }
    /// Test/diagnostic read of whether the post-mixer tap is currently armed.
    var outputCaptureArmedProbe: Bool { outputCaptureArmed }
    /// Test/diagnostic read of the armed capture's ownership (nil when not armed).
    var outputCaptureOwnershipProbe: OutputCaptureOwnership? { outputCaptureOwnership }
    /// Test/diagnostic read of total grains scheduled since load (DEBUG).
    var scheduledGrainCountProbe: Int { forwardScheduleCount + backwardScheduleCount }
    /// Test/diagnostic count of tap callback invocations (DEBUG).
    private(set) var outputCaptureTapInvocations = 0
#endif

    /// Installs the post-mixer capture tap. `envGated: true` keeps the
    /// automatic capture behind `SCRATCHLAB_CAPTURE_OUTPUT=1`; the manual
    /// diagnostics control passes `false` (explicit user action). Returns the
    /// install error, or nil when armed (or already armed).
    @discardableResult
    private func installOutputCaptureTap(envGated: Bool) -> Error? {
        guard envGated ? Self.outputCaptureEnabled : true, !outputCaptureArmed else { return nil }
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let mixerRate = mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 44_100
        outputCaptureRate = mixerRate
        // Capacity from the ACTUAL mixer sample rate: rate * 30 s.
        outputCaptureRingFrames = Int(mixerRate * 30)
        guard outputCaptureRingFrames > 0,
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: mixerRate, channels: 2) else { return nil }
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: outputCaptureRingFrames)
        ring.initialize(repeating: 0, count: outputCaptureRingFrames)
        outputCaptureRing = ring
        outputCaptureWriteFrames = 0
        do {
            try engine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: tapFormat
            ) { [weak self] buffer, _ in
                guard let self else { return }
#if DEBUG
                self.outputCaptureTapInvocations += 1
#endif
                guard let ring = self.outputCaptureRing,
                      let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                let capacity = self.outputCaptureRingFrames
                let writeStart = self.outputCaptureWriteFrames % capacity
                let ch0 = channels[0]
                let ch1 = buffer.format.channelCount > 1 ? channels[1] : nil
                var idx = writeStart
                if let ch1 {
                    for i in 0..<frames {
                        ring[idx] = (ch0[i] + ch1[i]) * 0.5
                        idx += 1
                        if idx == capacity { idx = 0 }
                    }
                } else {
                    for i in 0..<frames {
                        ring[idx] = ch0[i]
                        idx += 1
                        if idx == capacity { idx = 0 }
                    }
                }
                self.outputCaptureWriteFrames += frames  // single aligned store; single writer while armed
            }
            outputCaptureArmed = true
            outputCaptureOwnership = envGated ? .automatic : .manual
            return nil
        } catch {
            print("[ScratchSamplePlaybackController] output capture tap install failed: \(error)")
            ring.deallocate()
            outputCaptureRing = nil
            return error
        }
    }

    /// Finishes capture. The mixer tap is removed FIRST (after removal no
    /// callback can still be executing and nothing else writes the ring or the
    /// index), then the immutable chronological range is built and dispatched
    /// to the export queue. Exactly one completion fires (when provided) unless
    /// `only` mismatches the armed capture's ownership, in which case the
    /// capture is left armed untouched (e.g. the motion→idle ramp must not
    /// finalize a manual capture). Safe on `audioQueue` or during engine
    /// teardown.
    private func finishOutputCaptureIfArmed(
        completion: ((OutputCaptureFinalizeOutcome) -> Void)? = nil,
        only: OutputCaptureOwnership? = nil
    ) {
        guard outputCaptureArmed, let ring = outputCaptureRing else {
            completion?(.notArmed)
            return
        }
        if let only, outputCaptureOwnership != only {
            // Not this path's capture: leave it armed (manual survives the
            // motion→idle ramp; the automatic capture survives Stop & Export
            // is NOT this case — explicit Stop & Export finalizes any).
            return
        }
        outputCaptureArmed = false
        outputCaptureOwnership = nil
        engine.mainMixerNode.removeTap(onBus: 0)
        dvsCaptureFinalizeCount += 1
        // From here on no writer can touch the ring or the write index.
        let written = outputCaptureWriteFrames
        let capacity = outputCaptureRingFrames
        guard written > 0, capacity > 0 else {
            ring.deallocate()
            outputCaptureRing = nil
            completion?(.empty)
            return
        }
        // Chronological circular-ring order: the last min(written, capacity)
        // frames, starting at the final write position.
        let samples = Self.orderedCaptureSamples(ring: ring, capacity: capacity, written: written)
        ring.deallocate()
        outputCaptureRing = nil
        let rate = outputCaptureRate
        outputCaptureExportQueue.async {
            guard let directory = Self.defaultCaptureDirectory else {
                print("[DVS-CAPTURE] export failed error=noApplicationSupportDirectory path=<unknown>")
                completion?(.error(CaptureExportError.noApplicationSupportDirectory))
                return
            }
            do {
                let url = try Self.writeMonoFloatWAV(samples, sampleRate: rate, to: directory)
                print("[DVS-CAPTURE] wrote frames=\(samples.count) rate=\(rate) path=\(url.path)")
                completion?(.exported(path: url.path))
            } catch {
                print("[DVS-CAPTURE] export failed error=\(error) path=\(directory.appendingPathComponent("scratchlab-output-capture.wav").path)")
                completion?(.error(error))
            }
        }
    }

    /// Outcome of a manual capture finalization.
    enum OutputCaptureFinalizeOutcome {
        case exported(path: String)
        case empty
        case notArmed
        case error(Error)
    }

    /// Errors raised by the diagnostic capture export.
    enum CaptureExportError: Error {
        case emptyCapture
        case noApplicationSupportDirectory
    }

    /// Sandbox-writable capture destination:
    /// `~/Library/Application Support/ScratchLab/Diagnostics/`.
    private static var defaultCaptureDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Reorders a captured circular ring (capacity, total written frames, final
    /// write position) into chronological order. Before the ring wraps
    /// (`written < capacity`) the oldest frame is at index 0; after wrap it is
    /// at `written % capacity`. Returns the last `min(written, capacity)`
    /// frames in chronological order.
    static func orderedCaptureSamples(
        ring: UnsafePointer<Float>,
        capacity: Int,
        written: Int
    ) -> [Float] {
        let count = min(written, capacity)
        guard count > 0, capacity > 0 else { return [] }
        let start = written >= capacity ? written % capacity : 0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = ring[(start + i) % capacity]
        }
        return out
    }

    /// Writes captured mono Float32 samples atomically to
    /// `<directory>/scratchlab-output-capture.wav`, creating the directory
    /// first (runs off the render callback, on the export queue). Returns the
    /// written URL. Throws on empty capture or any file/directory error.
    @discardableResult
    static func writeMonoFloatWAV(
        _ samples: [Float],
        sampleRate: Double,
        to directory: URL,
        fileName: String = "scratchlab-output-capture.wav"
    ) throws -> URL {
        let frames = samples.count
        guard frames > 0 else { throw CaptureExportError.emptyCapture }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        var pcm = Data()
        pcm.reserveCapacity(frames * 4 + 44)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { pcm.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { pcm.append(contentsOf: $0) } }
        u32(0x46464952); u32(UInt32(36 + frames * 4)); u32(0x45564157)
        u32(0x20746D66); u32(16); u16(3); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32)
        u32(0x61746164); u32(UInt32(frames * 4))
        samples.withUnsafeBytes { pcm.append(contentsOf: $0) }
        try pcm.write(to: url, options: .atomic)
        return url
    }

    /// Manual start result for the DVS diagnostics panel (DEBUG-only).
    enum OutputCaptureDiagnosticsResult {
        case armed
        case alreadyArmed
        case engineNotRunning
        case tapInstallFailed(Error)
    }

    /// Explicitly arms the post-mixer output capture from the manual
    /// diagnostics control. The complete engine-running check, armed check,
    /// tap installation, ring mutation and result creation run on `audioQueue`
    /// (serialized with all other capture transitions); the result is returned
    /// through the completion handler and exactly one completion fires.
    /// Reports clearly when the playback engine is not running — it never
    /// silently no-ops. Reuses the same bounded ring and real-time-safe tap as
    /// the automatic path, without the env gate; ownership is `.manual`.
    func armOutputCaptureForDiagnostics(
        completion: @escaping (OutputCaptureDiagnosticsResult) -> Void
    ) {
        audioQueue.async { [weak self] in
            guard let self else {
                completion(.engineNotRunning)
                return
            }
            guard self.engineStarted else {
                completion(.engineNotRunning)
                return
            }
            if self.outputCaptureArmed {
                completion(.alreadyArmed)
                return
            }
            if let error = self.installOutputCaptureTap(envGated: false) {
                completion(.tapInstallFailed(error))
                return
            }
            completion(self.outputCaptureArmed ? .armed
                       : .tapInstallFailed(CaptureExportError.noApplicationSupportDirectory))
        }
    }

    /// Explicitly removes the tap, finalizes the captured frames and exports
    /// immediately (manual diagnostics control). Exactly one completion fires:
    /// `.exported(path)`, `.empty`, `.notArmed`, or `.error`. Independent of
    /// `direction:nil`, platter stopping, `pausePlayback`, the stop ramp, and
    /// engine teardown. Runs on `audioQueue` so it is serialized with the
    /// automatic finalization paths.
    func finishOutputCaptureForDiagnostics(
        completion: @escaping (OutputCaptureFinalizeOutcome) -> Void
    ) {
        audioQueue.async { [weak self] in
            self?.finishOutputCaptureIfArmed(completion: completion)
        }
    }
#endif

#if DEBUG
    /// DEBUG-only manual control for the post-mixer output capture, driven
    /// from the DVS diagnostics panel. Holds a weak reference to the live
    /// controller (registered at init) so the panel's Start / Stop & Export
    /// buttons work without changing the SwiftUI production flow — the panel
    /// re-reads this singleton on its bounded refresh timer.
    final class OutputCaptureDiagnosticsControl: ObservableObject {
        static let shared = OutputCaptureDiagnosticsControl()
        @Published private(set) var status: String = "Capture idle"
        private weak var controller: ScratchSamplePlaybackController?

        func register(_ controller: ScratchSamplePlaybackController) {
            self.controller = controller
        }

        func start() {
            guard let controller else {
                setStatus("Capture start failed: no controller")
                return
            }
            setStatus("Arming…")
            controller.armOutputCaptureForDiagnostics { [weak self] result in
                guard let self else { return }
                switch result {
                case .armed:
                    self.setStatus("Capture armed")
                case .alreadyArmed:
                    self.setStatus("Capture armed (already)")
                case .engineNotRunning:
                    self.setStatus("Capture start failed: engine not running")
                case .tapInstallFailed(let error):
                    self.setStatus("Capture start failed: \(error)")
                }
            }
        }

        func stopAndExport() {
            guard let controller else {
                setStatus("Capture stop failed: no controller")
                return
            }
            controller.finishOutputCaptureForDiagnostics { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .exported(let path):
                    self.setStatus("Exported: \(path)")
                case .empty:
                    self.setStatus("Export failed: capture is empty")
                case .notArmed:
                    self.setStatus("Export failed: capture not armed")
                case .error(let error):
                    self.setStatus("Export failed: \(error)")
                }
            }
        }

        private func setStatus(_ text: String) {
            DispatchQueue.main.async { [weak self] in
                self?.status = text
            }
        }
    }
#endif

    // MARK: - Lifecycle

    init(schedulingClock: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.schedulingClock = schedulingClock
        audioQueue.setSpecific(key: audioQueueKey, value: ())
        engine.attach(playerNode)
        engine.attach(varispeedNode)
        engine.connect(playerNode, to: varispeedNode, format: nil)
        engine.connect(varispeedNode, to: engine.mainMixerNode, format: nil)
        engine.attach(dvsContinuousRenderer.node)
        engine.connect(dvsContinuousRenderer.node, to: engine.mainMixerNode, format: nil)
#if DEBUG
        dvsGrainRingPreallocate()
        OutputCaptureDiagnosticsControl.shared.register(self)
#endif
    }

    deinit {
        stopEngine()
    }

    private func debugPublishOnMainAsync(field: String, _ body: @escaping () -> Void) {
        let requestTime = CACurrentMediaTime()
        let requestThread = Thread.isMainThread ? "main" : "background"
        print("[SwiftUIStateGuard] publish request · field=ScratchSamplePlaybackController.\(field) thread=\(requestThread) time=\(String(format: "%.6f", requestTime))")

        DispatchQueue.main.async(execute: body)
    }

    // MARK: - Engine start/stop (audioQueue or deinit only)

    private func ensureEngineRunning() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !engineStarted else { return }
        do {
            try engine.start()
            engineStarted = true
            playerNode.play()
#if DEBUG
            installOutputCaptureTap(envGated: true)
#endif
            print("[ScratchSamplePlaybackController] engine started, output = system default")
        } catch {
            print("[ScratchSamplePlaybackController] engine start failed: \(error)")
        }
    }

    /// Whether the engine is running, read under `engineLock` — the guard
    /// both scheduling paths use before `playerNode.play()`.
    private func isEngineRunningForPlayback() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return engineStarted
    }

    private func stopEngine() {
        engineLock.lock()
        defer { engineLock.unlock() }
        dvsContinuousRenderer.publishIdle()
        stopRampGeneration += 1
        cancelStopRamp()
        cancelMIDICoalescingTimer()
#if DEBUG
        finishOutputCaptureIfArmed()
#endif
        guard engineStarted else { return }
        playerNode.stop()
        playerNode.volume = 1.0
        engine.stop()
        engineStarted = false
    }

    // MARK: - Sample loading

    /// Load a bundled sample into the playback buffer.
    ///
    /// Returns false synchronously only if the sample ID is unknown or the WAV
    /// is absent from the bundle. Actual file I/O, buffer preparation, and
    /// engine startup run on the audio queue; the caller returns immediately.
    ///
    /// - Parameter playDiagnosticPreview: When true (the default, and the
    ///   behavior every existing caller — hot-cue pads, crossfader trigger —
    ///   keeps unchanged), a short audible snippet plays once to prove the
    ///   engine/sample chain is audible. Pass `false` for a load that must
    ///   produce no audio by itself (e.g. the right-deck platter test button:
    ///   platter movement, not the load itself, should be what's heard).
    @discardableResult
    func load(sampleID: String, playDiagnosticPreview: Bool = true) -> Bool {
        print("[ScratchSamplePlaybackController] load requested · sampleID=\(sampleID)")
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            debugPublishOnMainAsync(field: "statusLabel.missing") { [weak self] in
                self?.statusLabel = "missing: \(sampleID)"
            }
            return false
        }
        audioQueue.async { [weak self] in
            self?.loadOnQueue(sampleID: sampleID, url: url, playDiagnosticPreview: playDiagnosticPreview)
        }
        return true
    }

    /// Ensures `sampleID` is loaded before DVS-driven position updates can
    /// reach `positionDidChange`. Unlike `load(sampleID:)`, this is
    /// idempotent: if `sampleID` is already the loaded sample, it does
    /// nothing — safe to call on every DVS evaluation tick without reload
    /// churn or resetting `currentSampleFrame` mid-scratch. The idempotency
    /// check runs on the audio queue (where `loadedSampleID` is mutated),
    /// so it is race-free regardless of the caller's thread.
    ///
    /// Returns false synchronously only if the sample ID is unknown or the
    /// WAV is absent from the bundle — same failure contract as
    /// `load(sampleID:)`. Does not affect manual `load(sampleID:)` callers
    /// (hot-cue pads, crossfader trigger, debug button), which always
    /// reload/reset as before.
    @discardableResult
    func ensureLoadedForDVSDrive(sampleID: String) -> Bool {
        guard let url = wavURL(for: sampleID) else {
            print("[ScratchSamplePlaybackController] WAV not found for sample ID: \(sampleID)")
            debugPublishOnMainAsync(field: "statusLabel.missing") { [weak self] in
                self?.statusLabel = "missing: \(sampleID)"
            }
            return false
        }
        audioQueue.async { [weak self] in
            guard let self, self.loadedSampleID != sampleID else { return }
            self.loadOnQueue(sampleID: sampleID, url: url, playDiagnosticPreview: true)
        }
        return true
    }

    private func loadOnQueue(sampleID: String, url: URL, playDiagnosticPreview: Bool) {
        print("[ScratchSamplePlaybackController] sample load queued: \(sampleID)")
        lastLoadError = nil
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            print("[ScratchSamplePlaybackController] failed to open \(sampleID): \(error)")
            lastLoadError = "open failed: \(error.localizedDescription)"
            debugPublishOnMainAsync(field: "statusLabel.error") { [weak self] in
                self?.statusLabel = "error: \(sampleID)"
            }
            return
        }

        guard let buffer = readIntoBuffer(file) else {
            print("[ScratchSamplePlaybackController] failed to read PCM for \(sampleID)")
            lastLoadError = "unreadable PCM"
            return
        }

        applyLoadedBufferState(buffer, sampleID: sampleID)

        ensureEngineRunning()

        if !playDiagnosticPreview {
            print("[ScratchSamplePlaybackController] diagnostic preview suppressed by caller · sampleID=\(sampleID)")
        } else if diagnosticPreviewPlayedSampleID == sampleID {
            print("[ScratchSamplePlaybackController] diagnostic preview skipped · sampleID=\(sampleID)")
        } else {
            diagnosticPreviewPlayedSampleID = sampleID

            // HARDWARE DIAGNOSTIC: prove AVAudioEngine + playerNode + loaded sample are audible.
            let previewFrames = min(
                Int(buffer.format.sampleRate * 0.35),
                Int(buffer.frameLength)
            )

            if let preview = copySegment(
                from: buffer,
                startFrame: 0,
                frameCount: previewFrames
            ) {
                playerNode.stop()
                engine.mainMixerNode.outputVolume = 1.0
                playerNode.scheduleBuffer(
                    preview,
                    at: nil,
                    options: [],
                    completionHandler: {
                        print("[ScratchSamplePlaybackController] diagnostic preview completed")
                    }
                )
                playerNode.volume = 1.0
                playerNode.play()
                print("[ScratchSamplePlaybackController] diagnostic preview scheduled · \(previewFrames) frames")
            } else {
                print("[ScratchSamplePlaybackController] diagnostic preview failed")
            }
        }

        print("[ScratchSamplePlaybackController] loaded \(sampleID)")
        print("[ScratchSamplePlaybackController] ready for platter · sampleID=\(sampleID) totalFrames=\(totalFrames) framesPerStep=\(String(format: "%.2f", framesPerStep))")
        debugPublishOnMainAsync(field: "statusLabel.loaded") { [weak self] in
            self?.statusLabel = "loaded: \(sampleID) · system default"
        }
    }

    /// Installs a decoded PCM buffer as the loaded sample and resets all
    /// per-sample playback state. Extracted from `loadOnQueue` (unchanged
    /// semantics) so the DEBUG synthetic-sample seam below shares the exact
    /// production reset path instead of duplicating it. Must run on
    /// `audioQueue`.
    private func applyLoadedBufferState(_ buffer: AVAudioPCMBuffer, sampleID: String) {
        forwardBuffer = buffer
        totalFrames = Int(buffer.frameLength)
        loadedSampleID = sampleID
        lastScheduledSteps = 0
        lastScheduledDirection = nil
        lastScheduleTime = 0
        currentSampleFrame = 0
        lastPlatterSteps = nil
        lastRawMIDISteps = nil
        midiAccumulatedSteps = 0
        wasDVSMotionActive = false
        dvsDefinitivelyStopped = false
        dvsRestartMotionTicks = 0
        // 33⅓ RPM → 1.8 s/rev → normal-speed playback allocates
        // (sampleRate × 1.8) frames per revolution, distributed across
        // controller steps. This way the varispeed graph hits rate=1.0
        // when the platter turns at nominal vinyl speed, regardless of
        // sample length — a 1 s snare and a 10 s bass both play back at
        // the same pitch for the same platter speed.
        let vinylSecondsPerRevolution = 60.0 / Self.nominalVinylRPM
        let rate = Double(buffer.format.sampleRate)
        framesPerStep = max(1, (rate * vinylSecondsPerRevolution) / Double(stepsPerRevolution))
        // Direct-MIDI-only per-step frame rate — same rate/RPM basis, just
        // Rane's own measured direct-MIDI CC6 resolution instead of the
        // DVS/timecode-tuned constant. `dvsLoopFrames` below is
        // deliberately NOT duplicated for MIDI: it is exactly
        // `rate * vinylSecondsPerRevolution` regardless of which
        // steps-per-revolution constant is used to express it (the two
        // cancel out), i.e. one physical revolution's real audio-frame
        // duration — the same loop, shared correctly by both paths.
        midiFramesPerStep = max(1, (rate * vinylSecondsPerRevolution) / Double(Self.raneOneMKIIDirectMIDIStepsPerRevolution))
        // Exactly one revolution's frame count at this sample's rate — see
        // the `dvsLoopFrames` doc comment.
        dvsLoopFrames = framesPerStep * Double(stepsPerRevolution)
        dvsAccumulatedSteps = 0
        // Right-deck MIDI continuous drive: independent phase anchor and
        // drive history reset alongside DVS's, on every load (a freshly
        // loaded sample starts both control sources at phase 0). Ownership
        // is a separate concern from the phase reset above: if DVS is the
        // authoritative active control source (`dvsOwnershipActive`), a
        // load/reload performed while it is active must not let the timer
        // observe `.none` and briefly claim `.midi` — see `midiCoalescingTick`,
        // which in any case guards on `dvsOwnershipActive` directly, not
        // this field.
        midiContinuousAccumulatedSteps = 0
        midiContinuousDrive.reset()
        midiContinuousWasActive = false
        platterRenderOwner = dvsOwnershipActive ? .dvs : .none
        // Stale from a previous sample; the next coalescing tick
        // recomputes it fresh against the sample just loaded.
        lastMIDIContinuousRejectionReason = nil
        #if DEBUG
        dvsLapCandidate = nil
        previousGrainScalars = nil
        #endif
        lastScheduledSourceFrame = nil
        lastScheduledSegmentFrames = nil
        lastScheduledRate = nil
        forwardScheduleCount = 0
        backwardScheduleCount = 0
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = nil
        lastReversalCompensated = false
        resetDVSGrainTiming()
        varispeedNode.rate = 1.0
        // Continuous DVS renderer: install the immutable PCM copy whenever
        // the clip fits inside the one-revolution loop (always true for the
        // production DVS asset). Longer samples never engage the renderer —
        // `renderContinuousDVSTick` requires the same fit — so they only
        // need the renderer silenced.
        if Double(totalFrames) <= dvsLoopFrames {
            dvsContinuousRenderer.installSample(
                from: buffer,
                loopFrames: dvsLoopFrames,
                contentFadeFrames: dvsLoopContentFadeFrames
            )
        } else {
            dvsContinuousRenderer.publishIdle()
        }
    }

#if DEBUG
    /// Test-only seam: installs a caller-built PCM buffer as the loaded
    /// sample through the exact production reset path
    /// (`applyLoadedBufferState`), skipping only bundle I/O, engine start,
    /// and the audible diagnostic preview. Lets integration tests exercise
    /// the DVS tick routing deterministically without bundled fixtures
    /// (the documented command-line fixture-resolution gap).
    func testOnly_installSyntheticSample(_ buffer: AVAudioPCMBuffer, sampleID: String) {
        audioQueue.sync {
            self.applyLoadedBufferState(buffer, sampleID: sampleID)
        }
    }
#endif

    // MARK: - Position-driven playback

    /// Called when platter position changes. Runs the complete trace +
    /// scheduling transaction synchronously on `audioQueue`, serialized with
    /// load/unload/pause/resume/crossfader work, so the caller (CoreMIDI
    /// callback thread or the DVS worker) blocks until this tick's
    /// scheduling transaction is fully applied — no stale DVS scheduling
    /// backlog, and no interleaving with the other queue-confined mutations.
    /// `runSynchronouslyOnAudioQueue` avoids a self-deadlock if this is ever
    /// reached while already running on `audioQueue`.
    func positionDidChange(steps: Int, direction: ScratchPlatterDirection?, segmentWindow: TimeInterval? = nil) {
        runSynchronouslyOnAudioQueue {
            // Overflow-safe `Int` delta first (the caller's absolute step
            // count can be huge over a long session — see
            // `midiAccumulatedSteps`), only then folded into the `Double`
            // accumulator `positionDidChangeOnQueue` expects.
            let deltaSteps: Int
            if let lastRaw = self.lastRawMIDISteps {
                let result = steps.subtractingReportingOverflow(lastRaw)
                deltaSteps = result.overflow ? (steps >= lastRaw ? Int.max : Int.min) : result.partialValue
            } else {
                deltaSteps = 0
            }
            self.lastRawMIDISteps = steps
            self.midiAccumulatedSteps += Double(deltaSteps)
            self.positionDidChangeOnQueue(
                steps: self.midiAccumulatedSteps,
                direction: direction,
                segmentWindow: segmentWindow
            )
        }
    }

    /// Listening-fix #2 (Option 2, uncommitted): continuous fractional-steps
    /// entry point used by the DVS drive path. `steps` is the running
    /// fractional cumulative step total from `TimecodeDriveStepConverter
    /// .continuousSteps`, so every moving tick emits a grain (no whole-step
    /// quantization skips / batch lag at near-stop speeds).
    func positionDidChangeContinuous(steps: Double, direction: ScratchPlatterDirection?, segmentWindow: TimeInterval? = nil) {
        runSynchronouslyOnAudioQueue {
            #if DEBUG
            let _ts = DVSTrace.current
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            let _dt = (_tm - self._lastPositionDidChangeTime) * 1000
            let _swStr = segmentWindow.map { sw in String(format: "%.3f", sw) }
            let _dirStr = direction.map { d in "\(d)" } ?? "nil"
            let _swDisplay = _swStr ?? "nil"
            DVSTrace.log("[DVS-TRACE:4] playbackController positionDidChange seq=\(_ts) monotonic=\(_tm) dt=\(_dt)ms steps=\(steps) dir=\(_dirStr) segmentWindow=\(_swDisplay) thread=\(_thr)")
            self._lastPositionDidChangeTime = _tm
            #endif
            self.positionDidChangeOnQueue(steps: steps, direction: direction, segmentWindow: segmentWindow)
        }
    }

    /// Runs `work` on `audioQueue`, executing it directly when already
    /// running there (instead of a self-deadlocking `audioQueue.sync`) and
    /// otherwise dispatching via `sync` so the caller blocks until `work`
    /// completes. Direct execution is safe because `audioQueue` is serial —
    /// nothing else can be interleaved either way.
    private func runSynchronouslyOnAudioQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: audioQueueKey) != nil {
            work()
        } else {
            audioQueue.sync(execute: work)
        }
    }

    private func positionDidChangeOnQueue(steps: Double, direction: ScratchPlatterDirection?, segmentWindow: TimeInterval? = nil) {
        let now = schedulingClock()
#if DEBUG
        let tScheduleEntry = now
#endif

        let dvsWindow: TimeInterval?
        if let segmentWindow, segmentWindow.isFinite {
            let sanitized = min(max(segmentWindow, 0), maximumDVSControlWindow)
            // Listening-fix #2b (hardware-validated, restored): cap the
            // accumulated control window at THIS tick's own window
            // (`sanitized`), not `maximumDVSControlWindow` (0.25s). A
            // 0.25s ceiling lets several skipped ticks (reversal crossing
            // / stop) accumulate up to 250ms of "old movement" credit,
            // which the next real grain then renders as one long stretched
            // catch-up window — this is exactly the "platter can
            // occasionally feel delayed" symptom seen on hardware. Capping
            // at one tick means a scheduling stall can cost at most that
            // tick's own window of latency, not up to a quarter second.
            // This does NOT affect rotational-phase accuracy: the phase
            // anchor (`dvsAccumulatedSteps`) is driven entirely by the
            // decoder's real cumulative `deltaSteps`, never by this
            // control-window bookkeeping.
            pendingDVSControlWindow = min(
                sanitized,
                pendingDVSControlWindow + sanitized
            )
            dvsWindow = sanitized
        } else {
            dvsWindow = nil
        }

        // MIDI can arrive much faster than the grain cadence and retains its
        // existing ~60 Hz limiter. DVS already comes from a coalescing 60 Hz
        // serial worker; applying the same exact boundary a second time makes
        // harmless timer jitter discard alternating grains. Crucially, the
        // rejected tick's platter steps still accumulate, while its elapsed
        // window does not, inflating the next rate and leaving an audio hole.
        guard dvsWindow != nil || now - lastScheduleTime >= minScheduleInterval else {
            #if DEBUG
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            let _elapsed = now - lastScheduleTime
            let _minInt = minScheduleInterval
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(CACurrentMediaTime()) reason=rateLimit steps=\(steps) elapsed=\(_elapsed)s min=\(_minInt)s thread=\(_thr)")
            #endif
            return
        }

        guard direction != nil else {
            resetDVSGrainTiming()
            lastScheduleSkippedReason = "noDirection"
            #if DEBUG
            // A dropout/untrusted tick invalidates any in-progress lap
            // candidate — see `dvsLapCandidate`'s doc comment.
            dvsLapCandidate = nil
            previousGrainScalars = nil
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=noDirection steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noDirection steps=\(steps) thread=\(_thr)")
            #endif
            // DVS-only click-free stop: fire the generation-protected ramp only
            // on the motion -> noDirection TRANSITION (DVS path only — MIDI has
            // `dvsWindow == nil` and keeps its existing reset behaviour). Idle
            // nil ticks never restart it. The completed ramp's final stop also
            // finalizes the post-mixer output capture (if armed).
            if dvsWindow != nil {
                // Continuous renderer: a genuine no-direction tick settles
                // the render output to silence click-free (velocity target
                // zero, inactive). The retained render phase and the
                // authoritative step anchor are deliberately untouched.
                if dvsUsesContinuousRenderer {
                    dvsContinuousRenderer.publishIdle()
                }
                // Any idle tick breaks a near-stop restart candidate: settling
                // jitter must not accumulate across nil ticks into a restart.
                dvsRestartMotionTicks = 0
                if wasDVSMotionActive {
                    wasDVSMotionActive = false
                    if playerNode.isPlaying {
                        dvsAutoStopRampStartCount += 1
                        beginStopRamp()
                    } else {
                        // Already silent: stay definitively stopped (the ramp
                        // completion also sets this, for the ramp path above).
                        dvsDefinitivelyStopped = true
                    }
                } else {
                    dvsDefinitivelyStopped = true
                }
            }
            return
        }

        guard let forward = forwardBuffer, totalFrames > 0 else {
            resetDVSGrainTiming()
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noBuffer steps=\(steps) hasBuffer=\(forwardBuffer != nil) totalFrames=\(totalFrames) thread=\(_thr)")
            #endif
            return
        }

        guard let previousSteps = lastPlatterSteps else {
            lastPlatterSteps = steps
            resetDVSGrainTiming()
            lastScheduleSkippedReason = "priming"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=priming steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=priming steps=\(steps) thread=\(_thr)")
            #endif
            return
        }

        let deltaSteps = steps - previousSteps
        let deltaStepMagnitude = abs(deltaSteps)

        // Continuous-renderer DVS path (2026-08-09 static/burst fix): DVS
        // ticks with the production loop geometry publish velocity + the
        // authoritative phase anchor to the continuous renderer instead of
        // scheduling a grain. Returns false (falling through to the legacy
        // grain machinery below) for MIDI ticks, for the legacy rollback
        // flag, and for samples longer than one revolution.
        if dvsUsesContinuousRenderer,
           let window = dvsWindow,
           renderContinuousDVSTick(
               steps: steps,
               deltaSteps: deltaSteps,
               tickWindow: window,
               now: now
           ) {
            return
        }

        guard deltaStepMagnitude > 0 else {
            lastScheduleSkippedReason = "noMotion"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=noMotion steps=\(steps)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=noMotion steps=\(steps) thread=\(_thr)")
            #endif
            return
        }

        // Confirmed real DVS motion (`deltaSteps != 0`): mark motion active
        // for the noDirection transition trigger, and synchronously cancel any
        // pending auto-stop ramp, so a stale stop can never truncate newly
        // scheduled playback — even if a later render-eligibility guard (tiny
        // grain, reversal, segment generation, near-stop, scheduling) returns
        // early before any grain is rendered. Platter phase and accumulated
        // steps are untouched. MIDI keeps its existing path (`dvsWindow == nil`).
        if dvsWindow != nil {
            wasDVSMotionActive = true
            cancelPendingDVSAutoStopIfRamping()
        }

        // Scheduling direction comes from deltaSteps sign — the unambiguous physical
        // signal. The tracker direction (passed as a parameter) uses a 16-event window
        // that lags ~20ms at 800Hz; relying on it caused mismatch skips that silenced
        // the first ~16 grains after every reversal and prevented the needle from
        // returning to its cue position. The `direction` parameter is used only as a
        // nil-guard above and is not consulted for actual scheduling direction.
        let schedulingDirection: ScratchPlatterDirection = deltaSteps > 0 ? .forward : .backward

        // The sample loops at its own length: frame 0 is the "12 o'clock" loop
        // origin, and `totalFrames` is the loop end. Motion is never blocked at
        // either edge — `wrappedSampleFrame` carries it around instead, so the
        // needle simply continues into the wrapped region. `currentSampleFrame`
        // is always kept in [0, totalFrames) by wrapping (see below), so it can
        // never itself sit exactly at a boundary the way the old clamp did.

        let sourceTotalFrames = Int(forward.frameLength)
        // Only meaningful when the loaded content is shorter than one
        // physical revolution (the real DVS "ahh" asset: ~1.05 s inside a
        // 1.8 s loop). Samples at least as long as a revolution (e.g. the
        // long hot-cue pad clip, also reachable through this same
        // segmentWindow-driven path in tests) have no silence to pad and
        // fall back to the existing whole-sample wrap unchanged. Computed
        // here (rather than only at the segment-copy site below) because
        // the reversal-compensation decision just below also needs it.
        let isDVSLoop = dvsWindow != nil &&
            dvsLoopFrames > 0 &&
            Double(sourceTotalFrames) <= dvsLoopFrames

        // Listening-fix #5 (position-tracking leak, uncommitted): the
        // permanent phase anchor must advance for EVERY tick with real
        // motion, independent of whether a grain ends up rendered —
        // captured and applied here, before any of the render-eligibility
        // guards below can return early. Previously this update lived
        // inside the segment-generation branch further down, which the
        // "tinyGrain" guard (motion too small to round to >= 2 frames —
        // happens right at reversal turnarounds and near-full-stop
        // moments) returns past without ever reaching: `lastPlatterSteps`
        // still advanced (so the next tick's delta was computed
        // correctly), but that tick's real `deltaSteps` was silently
        // dropped from `dvsAccumulatedSteps` forever. A hardware trace
        // confirmed `dvsAccumulatedSteps` is otherwise perfectly
        // continuous (no reset), so this — a genuine, if small per
        // occurrence, unrecoverable loss compounding over a long session
        // — was a real contributor to reported long-session cue drift,
        // separate from any steps-per-revolution calibration question
        // (see `dvsLoopFrames`'s doc comment: a hardware trace's isolated,
        // reversal-free sustained-forward run measured three consecutive
        // laps at 3934/3950/3911 steps, averaging 3931.7 against the
        // assumed 3932 — no evidence of a scale error worth chasing).
        let dvsPhysicalStepsBeforeThisTick: Double?
        let dvsStartPhaseThisTick: Double?
        if isDVSLoop {
            dvsPhysicalStepsBeforeThisTick = dvsAccumulatedSteps
            dvsStartPhaseThisTick = dvsLoopPhaseFrame(forAccumulatedSteps: dvsAccumulatedSteps)
            dvsAccumulatedSteps += deltaSteps
            currentSampleFrame = Int(dvsLoopPhaseFrame(forAccumulatedSteps: dvsAccumulatedSteps))
        } else {
            dvsPhysicalStepsBeforeThisTick = nil
            dvsStartPhaseThisTick = nil
        }

        // Near-stop settling hysteresis (burst/static defect, 2026-08-09):
        // after the auto-stop ramp completes, the player node is stopped and
        // silence begins. Platter settling jitter then arrives as isolated
        // small valid motion ticks; without hysteresis each such tick would
        // re-arm the player for one software-stretched short grain (the
        // burst) and the next nil tick would immediately re-stop it (the
        // exact-zero gap) — the repeated sparse restarts heard near stop.
        // While `dvsDefinitivelyStopped`, small motion (below the deliberate
        // threshold) is silenced until `dvsRestartMotionTickThreshold`
        // CONSECUTIVE motion ticks prove deliberate sustained motion — the
        // audible restart is temporarily suppressed, but phase keeps
        // accumulating (the anchor above already advanced on every genuine
        // motion tick), so cue / 12-o'clock mapping is untouched. Any
        // intervening nil tick resets the count (noDirection branch). Motion
        // at/above `minAudibleDeltaSteps` is unambiguously deliberate and
        // resumes immediately with no suppression delay.
        if dvsWindow != nil, dvsDefinitivelyStopped {
            if deltaStepMagnitude >= Double(minAudibleDeltaSteps) {
                dvsDefinitivelyStopped = false
                dvsRestartMotionTicks = 0
            } else {
                dvsRestartMotionTicks += 1
                if dvsRestartMotionTicks >= dvsRestartMotionTickThreshold {
                    dvsDefinitivelyStopped = false
                    dvsRestartMotionTicks = 0
                } else {
                    lastScheduleSkippedReason = "settleSuppress"
                    lastPlatterSteps = steps
                    lastScheduleTime = now
                    return
                }
            }
        }

        // Legacy rollback geometry split (cue-lock drift fix, 2026-08-10):
        // this function is shared by DVS's legacy grain path and direct
        // MIDI's legacy rollback path (`positionDidChange`, active when
        // `midiUsesContinuousRenderer == false`), discriminated the same
        // way the rest of this function already discriminates DVS from
        // MIDI ticks — `dvsWindow != nil` for DVS. Every geometry-dependent
        // calculation below this point must use the direct-MIDI scale for
        // MIDI ticks and the untouched DVS scale for DVS ticks.
        let effectiveFramesPerStep = dvsWindow == nil ? midiFramesPerStep : framesPerStep
        let frameDeltaDouble = min(Double(sourceTotalFrames), (deltaStepMagnitude * effectiveFramesPerStep).rounded())
        let frameDelta = max(1, Int(frameDeltaDouble))
        let consumedControlWindow = dvsWindow == nil
            ? segmentDuration
            : max(pendingDVSControlWindow, 0.001)
        let requestedFrames = Int(
            forward.format.sampleRate * consumedControlWindow
        )

        // Skip pathologically tiny grains (a single PCM sample), which would
        // produce an audible click. This guard catches literal single-sample
        // grains (frameDelta=1) that can only occur with atypically short
        // samples. The nearStop gate below handles musical near-stop motion.
        let minimumGrainFrames = 2
        guard frameDelta >= minimumGrainFrames else {
            lastScheduleSkippedReason = "tinyGrain"
            lastPlatterSteps = steps
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=tinyGrain steps=\(steps) frameDelta=\(frameDelta) minimum=\(minimumGrainFrames)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=tinyGrain steps=\(steps) frameDelta=\(frameDelta) minimum=\(minimumGrainFrames) thread=\(_thr)")
            #endif
            return
        }

        // Near-stop gate for the MIDI path: when the platter moves too slowly,
        // the varispeed floor (0.25) cannot stretch the grain to fill the
        // scheduling slot. DVS calls provide an explicit `segmentWindow`; those
        // grains use deterministic software stretching below the varispeed floor
        // later in this method, preserving slow captured motion without gaps.
        let minAudibleFrameDelta = max(1, Int(Double(minAudibleDeltaSteps) * effectiveFramesPerStep))
        let permitsSoftwareSlowGrain = dvsWindow != nil
        guard frameDelta >= minAudibleFrameDelta || permitsSoftwareSlowGrain else {
            switch schedulingDirection {
            case .forward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame + frameDelta)
            case .backward:
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame - frameDelta)
            }
            lastScheduleSkippedReason = "nearStop"
            lastPlatterSteps = steps
            lastScheduleTime = now
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=nearStop deltaSteps=\(deltaSteps) threshold=\(minAudibleFrameDelta) frameDelta=\(frameDelta)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=nearStop deltaSteps=\(deltaSteps) threshold=\(minAudibleFrameDelta) frameDelta=\(frameDelta) thread=\(_thr)")
            #endif
            return
        }

        // Reversal symmetry: the first grain after a direction change is
        // starved by the 60 Hz rate limiter — the new direction's motion
        // only accumulates during the ~16.7 ms gap. This creates an
        // asymmetry where the last forward grain covers ~727 frames but
        // the first backward grain covers only ~101 frames, causing the
        // start point to drift forward on every baby-scratch cycle.
        //
        // Compensate by borrowing the last direction's effective frameDelta,
        // capped so a very fast push doesn't produce a pathological jump on
        // the matching return stroke.
        //
        // DVS-loop exception: every DVS grain is already software
        // time-stretched to its scheduled output window regardless of raw
        // segment size (`usesSoftwareSlowGrain`/`softwareRateCorrectsGrain`
        // below), so the reason this compensation exists for MIDI — a
        // grain too short for the varispeed node to stretch to the slot —
        // does not apply. Borrowing anyway would make this grain read
        // further into the source than the anchor is about to land
        // (`dvsAccumulatedSteps` only ever advances by the real
        // `deltaSteps`, never by this compensation — see its doc comment),
        // so the *next* DVS grain would restart from inside the content
        // this one just played: an audible repeat/stutter, not a fix.
        // Always use the real, uncompensated `frameDelta` for DVS so
        // consecutive grains read exactly contiguous source content.
        let isDirectionChange = schedulingDirection != lastScheduledDirection
        let reversalCompensated: Bool
        let effectiveFrameDelta: Int
        if isDVSLoop {
            effectiveFrameDelta = frameDelta
            reversalCompensated = false
        } else if isDirectionChange,
           let lastEff = lastEffectiveFrameDelta {
            let borrowed = min(lastEff, reversalSymmetryCapFrames)
            if borrowed > frameDelta {
                effectiveFrameDelta = borrowed
                reversalCompensated = true
            } else {
                effectiveFrameDelta = frameDelta
                reversalCompensated = false
            }
        } else {
            effectiveFrameDelta = frameDelta
            reversalCompensated = false
        }

        #if DEBUG
        let _tsEntry = DVSTrace.current
        let _tEntry = tScheduleEntry
        let _thr = Thread.current.isMainThread ? "main" : "bg"
        DVSTrace.log("[DVS-TRACE:5] playbackController scheduleEntry seq=\(_tsEntry) monotonic=\(_tEntry) steps=\(steps) deltaSteps=\(deltaSteps) schedulingDir=\(directionDescription(schedulingDirection)) frameDelta=\(frameDelta) effectiveFrameDelta=\(effectiveFrameDelta) requestedFrames=\(requestedFrames) currentFrame=\(currentSampleFrame) reversalCompensated=\(reversalCompensated) playerNodePlaying=\(playerNode.isPlaying) thread=\(_thr)")
#endif

        // DVS maintains only a small bounded queue reserve. On reversal,
        // preserve that tail and enqueue the opposite-direction grain after it:
        // interrupting would discard valid PCM and turn every direction change
        // into an audible truncation. The resulting direction latency is
        // bounded by the reserve (normally about 4 ms). MIDI retains its
        // existing immediate interrupt behavior.
        let interruptsQueuedAudio = dvsWindow == nil && isDirectionChange
        let outputTiming = dvsWindow.map { _ in
            dvsOutputTiming(
                controlWindow: consumedControlWindow,
                now: now,
                interruptsQueuedAudio: interruptsQueuedAudio
            )
        }
        let scheduledOutputWindow = outputTiming?.outputWindow ?? consumedControlWindow
        let scheduledOutputFrames = Int(
            forward.format.sampleRate * scheduledOutputWindow
        )

        // Varispeed rate = platter-driven frame displacement / output window size.
        // A grain of effectiveFrameDelta frames played at this rate consumes exactly
        // its scheduled output window. DVS reports the physical rate against
        // the matching accumulated control window; a one-time/bounded cushion
        // may make the actual node rate slightly lower while the queue reserve
        // is replenished.
        let physicalRawRate = Double(effectiveFrameDelta) / Double(requestedFrames)
        let scheduledRawRate = Double(effectiveFrameDelta) / Double(scheduledOutputFrames)
        let usesSoftwareSlowGrain = permitsSoftwareSlowGrain &&
            scheduledRawRate < Double(minVarispeedRate)
        // Listening-fix (one variable, uncommitted): every DVS grain is
        // rate-corrected IN SOFTWARE (resampled to its scheduled output
        // window) and played through the varispeed node at unity, so the
        // node-global rate is never mutated per grain. Previously the rate
        // changed every grain and warped the tails of already-queued
        // buffers — the live-only underwater/chirp artifacts the offline
        // per-buffer reconstruction does not reproduce (A/B 2026-08-05).
        // MIDI retains its existing per-grain node-rate behavior.
        let softwareRateCorrectsGrain = dvsWindow != nil
        let nodeRate = usesSoftwareSlowGrain || softwareRateCorrectsGrain
            ? Float(1)
            : Float(max(Double(minVarispeedRate), min(Double(maxVarispeedRate), scheduledRawRate)))
        let reportedRate = permitsSoftwareSlowGrain
            ? Float(max(0, min(Double(maxVarispeedRate), physicalRawRate)))
            : nodeRate
        varispeedNode.rate = softwareRateCorrectsGrain ? 1.0 : nodeRate

        let sourceFrame: Int
        let segmentFrames: Int
        var segment: AVAudioPCMBuffer?

        if isDVSLoop, let startPhase = dvsStartPhaseThisTick, let physicalStepsBefore = dvsPhysicalStepsBeforeThisTick {
            // Listening-fix #4 (rotational mapping, uncommitted): the
            // rendered source frame comes from the anchored loop phase
            // *before* this tick's motion (captured above, before the
            // permanent anchor already advanced — see the
            // `dvsPhysicalStepsBeforeThisTick` doc comment). Rendering
            // still uses `effectiveFrameDelta`, which may be inflated by
            // MIDI-style reversal compensation elsewhere, but that never
            // reaches `dvsAccumulatedSteps` — the anchor already advanced
            // by the real `deltaSteps` only, unconditionally, above.
            sourceFrame = Int(startPhase)
            segmentFrames = effectiveFrameDelta
            segment = copyDVSLoopSegment(
                from: forward,
                startPhase: startPhase,
                frameCount: segmentFrames,
                direction: schedulingDirection
            )
            #if DEBUG
            // Hardware-verification instrumentation (SCRATCHLAB_DVS_TRACE=1
            // only — `DVSTrace.log`'s autoclosure means this string is
            // never built when tracing is off): the full chain from
            // physical decoder steps through to what actually gets
            // rendered, so a discrepancy between "where the needle should
            // be" and "what's playing" is visible directly in the log
            // rather than inferred from audio.
            DVSTrace.log("[DVS-TRACE:8] rotationalLoop seq=\(DVSTrace.current) dir=\(directionDescription(schedulingDirection)) physicalStepsBefore=\(physicalStepsBefore) deltaSteps=\(deltaSteps) physicalStepsAfter=\(dvsAccumulatedSteps) virtualPhaseBefore=\(startPhase) virtualPhaseAfter=\(Double(currentSampleFrame)) permanentAnchor=\(currentSampleFrame) renderedGrainStart=\(sourceFrame) renderedGrainFrames=\(segmentFrames) realFrameDelta=\(frameDelta) reversalCompensated=\(reversalCompensated) dvsLoopFrames=\(dvsLoopFrames)")

            // Candidate-revolution-period measurement (uncommitted): a lap
            // completes only for an uninterrupted, single-direction
            // candidate that both crosses the loop boundary AND was
            // already in progress before this tick. Logging each lap's
            // real, monotonically-accumulated travel distance directly
            // (rather than requiring offline reconstruction from
            // `[DVS-TRACE:8]`) is what answering "is 3932 actually right"
            // needs from a live session: several consecutive, isolated
            // (reversal-free) laps whose lengths agree closely support the
            // constant; laps that disagree — or that come out consistently
            // on one side of 3932 — would be real evidence of a scale
            // error worth correcting.
            //
            // Reversal safety: a naive "did the phase wrap since last
            // time" check fires on EITHER side of a scratch that merely
            // straddles the loop boundary (forward across it, then back —
            // no revolution ever completed), because each individual
            // crossing satisfies the wrap condition on its own. A
            // candidate is therefore invalidated and restarted — not
            // extended — on any direction change, any detected scheduling
            // gap (stop/resume; dropouts are handled separately, at the
            // `noDirection` guard above), and can only be reported once it
            // has accumulated at least one full tick of same-direction
            // travel from BEFORE the wrapping tick (`candidateJustStarted`
            // below) — a reversal that happens to also cross the boundary
            // on the very same tick cannot be misreported as a lap.
            let gapDetected: Bool
            if let lastEstimate = lastDVSQueueEstimateAt, let lastWindow = lastDVSScheduledOutputWindow {
                gapDetected = now > lastEstimate + lastWindow + 0.004
            } else {
                gapDetected = false
            }
            let candidateJustStarted: Bool
            if dvsLapCandidate == nil || dvsLapCandidate?.direction != schedulingDirection || gapDetected {
                dvsLapCandidate = DVSLapCandidate(
                    direction: schedulingDirection,
                    startAccumulatedSteps: physicalStepsBefore,
                    startPhase: startPhase,
                    startUptime: now
                )
                candidateJustStarted = true
            } else {
                candidateJustStarted = false
            }
            dvsLapCandidate?.travelledDistance += deltaStepMagnitude
            dvsLapCandidate?.tickCount += 1

            let wrapped: Bool
            switch schedulingDirection {
            case .forward:  wrapped = startPhase > Double(currentSampleFrame)
            case .backward: wrapped = startPhase < Double(currentSampleFrame)
            }
            if wrapped, !candidateJustStarted, let candidate = dvsLapCandidate {
                let lapSteps = candidate.travelledDistance
                let elapsedSeconds = now - candidate.startUptime
                DVSTrace.log("[DVS-TRACE:9] revolutionLap seq=\(DVSTrace.current) dir=\(directionDescription(schedulingDirection)) lapSteps=\(lapSteps) assumedStepsPerRevolution=3932 deltaFromAssumed=\(lapSteps - 3932) startPhase=\(candidate.startPhase) endPhase=\(Double(currentSampleFrame)) ticks=\(candidate.tickCount) elapsedSeconds=\(elapsedSeconds)")
                dvsLapCompletedObserver?(
                    DVSLapSnapshot(
                        direction: schedulingDirection,
                        lapSteps: lapSteps,
                        startPhase: candidate.startPhase,
                        endPhase: Double(currentSampleFrame),
                        tickCount: candidate.tickCount,
                        elapsedSeconds: elapsedSeconds
                    )
                )
                // The completed lap seamlessly starts the next candidate,
                // same direction, if motion continues past the boundary.
                dvsLapCandidate = DVSLapCandidate(
                    direction: schedulingDirection,
                    startAccumulatedSteps: dvsAccumulatedSteps,
                    startPhase: Double(currentSampleFrame),
                    startUptime: now
                )
            }
            #endif
        } else {
            switch schedulingDirection {
            case .forward:
                sourceFrame = currentSampleFrame
                segmentFrames = effectiveFrameDelta
                segment = copyWrappedForwardSegment(
                    from: forward,
                    startFrame: sourceFrame,
                    frameCount: segmentFrames
                )
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame + effectiveFrameDelta)
            case .backward:
                sourceFrame = currentSampleFrame
                segmentFrames = effectiveFrameDelta
                segment = copyWrappedReversedSegmentEnding(
                    at: sourceFrame,
                    frameCount: segmentFrames,
                    from: forward
                )
                currentSampleFrame = wrappedSampleFrame(currentSampleFrame - effectiveFrameDelta)
            }
        }
        if (usesSoftwareSlowGrain || dvsWindow != nil), let sourceSegment = segment {
            segment = copyTimeStretched(
                sourceSegment,
                outputFrameCount: scheduledOutputFrames
            )
        }

        #if DEBUG
        DVSTrace.log("[ScratchSamplePlaybackController] platter state · steps=\(steps) deltaSteps=\(deltaSteps) direction=\(directionDescription(schedulingDirection)) currentFrame=\(currentSampleFrame) effectiveFrameDelta=\(effectiveFrameDelta) totalFrames=\(sourceTotalFrames)")
        DVSTrace.log("[ScratchSamplePlaybackController] schedule input · steps=\(steps) direction=\(directionDescription(schedulingDirection)) sourceFrame=\(sourceFrame) segmentFrames=\(segmentFrames) rate=\(String(format: "%.3f", reportedRate)) nodeRate=\(String(format: "%.3f", nodeRate)) softwareSlow=\(usesSoftwareSlowGrain) totalFrames=\(sourceTotalFrames)")
        #endif

        let isValidSegment: Bool
        if isDVSLoop {
            // `sourceFrame` is a position in the DVS virtual loop
            // `[0, dvsLoopFrames)`, which extends past `sourceTotalFrames`
            // into the silence region — bound against the loop, not the
            // raw buffer length, or every silent-phase grain would be
            // rejected as "invalid" instead of scheduled as silence.
            let loopBound = Int(dvsLoopFrames)
            isValidSegment = sourceFrame >= 0 &&
                sourceFrame < loopBound &&
                segmentFrames > 0 &&
                segmentFrames <= loopBound
        } else {
            switch schedulingDirection {
            case .forward:
                isValidSegment = sourceFrame >= 0 &&
                    sourceFrame < sourceTotalFrames &&
                    segmentFrames > 0 &&
                    segmentFrames <= sourceTotalFrames
            case .backward:
                isValidSegment = sourceFrame >= 0 &&
                    sourceFrame < sourceTotalFrames &&
                    segmentFrames > 0 &&
                    segmentFrames <= sourceTotalFrames
            }
        }

        guard isValidSegment else {
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(sourceFrame) frames=\(segmentFrames) totalFrames=\(sourceTotalFrames)")
            #endif
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=invalidSegment sourceFrame=\(sourceFrame) frames=\(segmentFrames) totalFrames=\(sourceTotalFrames) thread=\(_thr)")
            #endif
            lastScheduleSkippedReason = "invalidSegment"
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        guard let segment else {
            lastScheduleSkippedReason = "copyFailed"
            #if DEBUG
            let _tm = CACurrentMediaTime()
            let _thr = Thread.current.isMainThread ? "main" : "bg"
            DVSTrace.log("[DVS-TRACE:7] playbackController scheduleSkip seq=\(DVSTrace.current) monotonic=\(_tm) reason=copyFailed sourceFrame=\(sourceFrame) frames=\(segmentFrames) thread=\(_thr)")
            #endif
            lastPlatterSteps = steps
            lastScheduleTime = now
            return
        }

        // Contiguous queued source segments meet at adjacent PCM frames and
        // must not be faded to zero: doing so amplitude-modulates playback at
        // the scheduler rate. Only the legacy MIDI reversal path interrupts
        // the node and therefore retains its edge fade.
        if interruptsQueuedAudio {
            applyEdgeFade(to: segment)
        }

        // Listening-fix #3 (uncommitted): de-click fade on resume after a
        // genuine DVS schedule gap. The previous DVS grain's audio ended at
        // (lastDVSQueueEstimateAt + lastDVSScheduledOutputWindow); if this
        // grain starts after that (plus a small epsilon), the output was
        // silent in between (noMotion / tinyGrain / unusable-signal gap) —
        // fade this grain's head in so playback ramps up from silence
        // instead of hard-cutting. Steady contiguous DVS never triggers this
        // (now is at/before expectedEnd), so no amplitude modulation.
        if dvsWindow != nil,
           let lastEstimate = lastDVSQueueEstimateAt,
           let lastWindow = lastDVSScheduledOutputWindow {
            let expectedEnd = lastEstimate + lastWindow
            if now > expectedEnd + 0.004 {
                applyHeadFade(to: segment, frames: grainEdgeFadeFrames)
            }
        }

        let opts: AVAudioPlayerNodeBufferOptions = interruptsQueuedAudio ? .interrupts : []
#if DEBUG
        let _scheduleThread = Thread.current.isMainThread ? "main" : "bg"
        let _optsStr = opts == .interrupts ? "interrupts" : "none"
        DVSTrace.log("[DVS-TRACE:6] playbackController scheduleBuffer seq=\(DVSTrace.current) monotonic=\(CACurrentMediaTime()) dir=\(directionDescription(schedulingDirection)) rate=\(reportedRate) nodeRate=\(nodeRate) softwareSlow=\(usesSoftwareSlowGrain) segmentFrames=\(segmentFrames) segmentWindow=\(segmentWindow ?? segmentDuration) opts=\(_optsStr) playerNodePlaying=\(playerNode.isPlaying) sourceFrame=\(sourceFrame) currentFrame=\(currentSampleFrame) thread=\(_scheduleThread)")
#endif
#if DEBUG
        // ── scalar extraction (buffer pointers, no allocation) ──────────
        let traceEnabled = DVSTrace.isEnabled
        let wantsJoin = grainJoinObserver != nil || traceEnabled
        let wantsFullSnapshot = scheduledGrainObserver != nil

        // Extract join-relevant scalars directly from the segment buffer
        // pointers — no Array, no heap allocation on the audio queue.
        // This runs whenever any observer or trace needs it; production
        // builds and non-trace DEBUG builds skip it entirely (all flags
        // are compile-time false or runtime nil).
        let currentScalars: GrainScalarSnapshot?
        if wantsJoin || wantsFullSnapshot {
            currentScalars = Self.extractGrainScalars(
                from: segment,
                sourceFrame: sourceFrame,
                direction: schedulingDirection,
                interrupts: opts == .interrupts,
                usesSlowGrain: usesSoftwareSlowGrain,
                rawFrameCount: segmentFrames,
                scheduledOutputWindow: scheduledOutputWindow,
                scheduledAtUptime: now,
                isDVSLoop: isDVSLoop
            )
        } else {
            currentScalars = nil
        }

        // Full channel-data snapshot — allocates [[Float]]; only for
        // test-configured observers, never on the hardware trace path.
        if let observer = scheduledGrainObserver, currentScalars != nil {
            observer(
                ScheduledGrainSnapshot(
                    direction: schedulingDirection,
                    interrupts: opts == .interrupts,
                    nodeRate: nodeRate,
                    scheduledOutputWindow: scheduledOutputWindow,
                    sourceFrame: sourceFrame,
                    sampleRate: forward.format.sampleRate,
                    channelData: channelData(of: segment),
                    usesSoftwareSlowGrain: usesSoftwareSlowGrain,
                    rawSourceFrameCount: segmentFrames,
                    scheduledAtUptime: now
                )
            )
        }

        // Join diagnostic from two consecutive scalar snapshots.
        if wantsJoin, let prev = previousGrainScalars, let curr = currentScalars {
            let estimatedPreviousEnd = prev.scheduledAtUptime + prev.scheduledOutputWindow
            let estimatedControlGap = curr.scheduledAtUptime - estimatedPreviousEnd
            let currFirst: Float = segment.floatChannelData?[0][0] ?? 0
            let join = GrainJoinDiagnostic(
                previousScheduledAtUptime: prev.scheduledAtUptime,
                currentScheduledAtUptime: curr.scheduledAtUptime,
                previousOutputWindow: prev.scheduledOutputWindow,
                currentOutputWindow: curr.scheduledOutputWindow,
                estimatedPreviousEnd: estimatedPreviousEnd,
                estimatedControlGap: estimatedControlGap,
                previousSourceFrame: prev.sourceFrame,
                currentSourceFrame: curr.sourceFrame,
                direction: curr.direction,
                previousLastSample: prev.lastSample,
                currentFirstSample: currFirst,
                joinDiscontinuity: abs(currFirst - prev.lastSample),
                previousInternalMaxStep: prev.internalMaxStep,
                currentInternalMaxStep: curr.internalMaxStep,
                crossesPhaseBoundary: prev.crossesPhaseBoundary || curr.crossesPhaseBoundary,
                previousInterrupts: prev.interrupts,
                currentInterrupts: curr.interrupts,
                previousUsesSlowGrain: prev.usesSlowGrain,
                currentUsesSlowGrain: curr.usesSlowGrain,
                previousRawFrameCount: prev.rawFrameCount,
                currentRawFrameCount: curr.rawFrameCount
            )
            grainJoinObserver?(join)
            if traceEnabled { dvsGrainRingPush(join) }
        }

        previousGrainScalars = currentScalars
#endif
        playerNode.scheduleBuffer(
            segment,
            at: nil,
            options: opts,
            completionHandler: nil
        )

        // Guarded on a running engine (always true in production after
        // load — `loadOnQueue` starts it) so engine-free deterministic
        // tests can drive this path; AVAudioPlayerNode.play() raises when
        // its engine is not running.
        if isEngineRunningForPlayback(), !playerNode.isPlaying {
            playerNode.play()
        }

        lastScheduledSteps = steps
        lastScheduledDirection = schedulingDirection
        if schedulingDirection == .forward {
            forwardScheduleCount += 1
        } else {
            backwardScheduleCount += 1
        }
        lastScheduleTime = now
        lastPlatterSteps = steps
        lastScheduledSourceFrame = sourceFrame
        lastScheduledSegmentFrames = segmentFrames
        lastScheduledRate = reportedRate
        lastScheduleSkippedReason = nil
        lastEffectiveFrameDelta = effectiveFrameDelta
        lastReversalCompensated = reversalCompensated
        if let outputTiming {
            estimatedDVSQueuedDuration = outputTiming.estimatedQueuedDuration
            lastDVSQueueEstimateAt = now
            lastDVSConsumedControlWindow = consumedControlWindow
            lastDVSScheduledOutputWindow = scheduledOutputWindow
            pendingDVSControlWindow = 0
        }
    }

    /// Continuous-renderer handling for one DVS control tick. Returns true
    /// when the tick was fully handled (the caller returns); false when the
    /// tick must fall through to the legacy grain machinery (sample longer
    /// than one revolution — never the production DVS asset).
    ///
    /// Behavioral parity is deliberate: the authoritative phase anchor
    /// (`dvsAccumulatedSteps` → `dvsLoopPhaseFrame`), the near-stop settle
    /// hysteresis, the motion→noDirection stop-ramp lifecycle flags, and
    /// every scalar diagnostic (`forwardScheduleCount`, `lastScheduledRate`,
    /// consumed-window bookkeeping, lap detection) behave exactly as the
    /// grain path did. Only the audio generation changes: instead of
    /// copying/stretching a PCM grain and queueing it on `playerNode`, the
    /// tick publishes signed velocity plus the post-tick anchor phase to
    /// `dvsContinuousRenderer`, which generates audio continuously at the
    /// render rate. `playerNode.play()` is still asserted during motion so
    /// the `playerIsPlaying` diagnostic and the stop-ramp lifecycle keep
    /// their established meaning (the node itself carries no DVS grains).
    private func renderContinuousDVSTick(
        steps: Double,
        deltaSteps: Double,
        tickWindow: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        guard let forward = forwardBuffer else { return false }
        let sourceTotalFrames = Int(forward.frameLength)
        guard dvsLoopFrames > 0, Double(sourceTotalFrames) <= dvsLoopFrames else {
            return false
        }

        let deltaStepMagnitude = abs(deltaSteps)
        guard deltaStepMagnitude > 0 else {
            // Direction present but no steps (e.g. rate reported as zero):
            // the platter is not moving, so the authoritative decision is
            // idle — the renderer ramps click-free to silence with its
            // retained phase untouched, matching the legacy behaviour
            // where a noMotion tick scheduled nothing and the queued audio
            // simply drained out. Anchor, pending-window accumulation, and
            // skip bookkeeping match the legacy noMotion path.
            dvsContinuousRenderer.publishIdle()
            lastScheduleSkippedReason = "noMotion"
            #if DEBUG
            DVSTrace.log("[ScratchSamplePlaybackController] continuous render idle · reason=noMotion steps=\(steps)")
            #endif
            return true
        }

        // Confirmed real DVS motion: identical lifecycle marking to the
        // grain path — the noDirection transition trigger and the stale
        // stop-ramp cancellation must behave exactly as validated.
        wasDVSMotionActive = true
        cancelPendingDVSAutoStopIfRamping()

        let schedulingDirection: ScratchPlatterDirection = deltaSteps > 0 ? .forward : .backward

        // Authoritative phase anchor: advances for EVERY tick with real
        // motion (listening-fix #5), exactly as before.
        #if DEBUG
        let physicalStepsBefore = dvsAccumulatedSteps
        #endif
        let startPhase = dvsLoopPhaseFrame(forAccumulatedSteps: dvsAccumulatedSteps)
        dvsAccumulatedSteps += deltaSteps
        let endPhase = dvsLoopPhaseFrame(forAccumulatedSteps: dvsAccumulatedSteps)
        currentSampleFrame = Int(endPhase)

        // Near-stop settling hysteresis: unchanged, hardware-validated
        // (2026-08-09). Suppressed wobble ticks stay silent (velocity is
        // not published, so the renderer keeps settling) while the phase
        // anchor above has already advanced — cue mapping untouched.
        if dvsDefinitivelyStopped {
            if deltaStepMagnitude >= Double(minAudibleDeltaSteps) {
                dvsDefinitivelyStopped = false
                dvsRestartMotionTicks = 0
            } else {
                dvsRestartMotionTicks += 1
                if dvsRestartMotionTicks >= dvsRestartMotionTickThreshold {
                    dvsDefinitivelyStopped = false
                    dvsRestartMotionTicks = 0
                } else {
                    lastScheduleSkippedReason = "settleSuppress"
                    lastPlatterSteps = steps
                    lastScheduleTime = now
                    return true
                }
            }
        }

        // Same consumed-window semantics as the grain path: the pending
        // accumulator is already capped at this tick's own sanitized window
        // (listening-fix #2b), so a scheduling stall can cost at most one
        // tick of catch-up in the velocity estimate.
        let consumedControlWindow = max(pendingDVSControlWindow, 0.001)
        let velocity = deltaSteps * framesPerStep / consumedControlWindow

        #if DEBUG
        // Lap-detection gap check needs the PREVIOUS tick's estimate — read
        // before this tick overwrites the fields below.
        let previousEstimateAt = lastDVSQueueEstimateAt
        let previousOutputWindow = lastDVSScheduledOutputWindow
        #endif

        dvsContinuousRenderer.publish(
            velocity: velocity,
            authoritativePhase: endPhase,
            active: true
        )
        // The player node carries no DVS audio on this path, but its
        // play/stop state remains the "DVS audibly active" signal for the
        // diagnostics panel and the validated stop-ramp lifecycle. Guarded
        // on a running engine (always true in production after load) so
        // engine-free deterministic tests can drive this path.
        if isEngineRunningForPlayback(), !playerNode.isPlaying {
            playerNode.play()
        }

        // Scalar diagnostics parity (the panel and focused tests read
        // these): rate is the physical platter rate against the consumed
        // window, exactly as the grain path reported it.
        let frameDelta = max(1, Int((deltaStepMagnitude * framesPerStep).rounded()))
        let physicalRate = abs(velocity) / forward.format.sampleRate
        lastScheduledSourceFrame = Int(startPhase)
        lastScheduledSegmentFrames = frameDelta
        lastScheduledRate = Float(max(0, min(Double(maxVarispeedRate), physicalRate)))
        lastEffectiveFrameDelta = frameDelta
        lastReversalCompensated = false
        lastScheduleSkippedReason = nil
        lastScheduledSteps = steps
        lastScheduledDirection = schedulingDirection
        if schedulingDirection == .forward {
            forwardScheduleCount += 1
        } else {
            backwardScheduleCount += 1
        }
        lastPlatterSteps = steps
        lastScheduleTime = now
        estimatedDVSQueuedDuration = 0
        lastDVSQueueEstimateAt = now
        lastDVSConsumedControlWindow = consumedControlWindow
        lastDVSScheduledOutputWindow = consumedControlWindow
        pendingDVSControlWindow = 0

        #if DEBUG
        DVSTrace.log("[DVS-TRACE:6C] continuousRender publish seq=\(DVSTrace.current) monotonic=\(CACurrentMediaTime()) dir=\(directionDescription(schedulingDirection)) velocity=\(velocity) physicalRate=\(physicalRate) window=\(consumedControlWindow) tickWindow=\(tickWindow) anchorPhase=\(endPhase) currentFrame=\(currentSampleFrame) steps=\(steps) deltaSteps=\(deltaSteps)")

        // Candidate-revolution lap measurement: identical semantics to the
        // grain path (see the [DVS-TRACE:9] block there) — candidates are
        // invalidated on direction change and on a detected scheduling gap,
        // and can only report once in progress before the wrapping tick.
        let gapDetected: Bool
        if let previousEstimateAt, let previousOutputWindow {
            gapDetected = now > previousEstimateAt + previousOutputWindow + 0.004
        } else {
            gapDetected = false
        }
        let candidateJustStarted: Bool
        if dvsLapCandidate == nil || dvsLapCandidate?.direction != schedulingDirection || gapDetected {
            dvsLapCandidate = DVSLapCandidate(
                direction: schedulingDirection,
                startAccumulatedSteps: physicalStepsBefore,
                startPhase: startPhase,
                startUptime: now
            )
            candidateJustStarted = true
        } else {
            candidateJustStarted = false
        }
        dvsLapCandidate?.travelledDistance += deltaStepMagnitude
        dvsLapCandidate?.tickCount += 1

        let wrapped: Bool
        switch schedulingDirection {
        case .forward:  wrapped = startPhase > Double(currentSampleFrame)
        case .backward: wrapped = startPhase < Double(currentSampleFrame)
        }
        if wrapped, !candidateJustStarted, let candidate = dvsLapCandidate {
            let lapSteps = candidate.travelledDistance
            let elapsedSeconds = now - candidate.startUptime
            DVSTrace.log("[DVS-TRACE:9] revolutionLap seq=\(DVSTrace.current) dir=\(directionDescription(schedulingDirection)) lapSteps=\(lapSteps) assumedStepsPerRevolution=3932 deltaFromAssumed=\(lapSteps - 3932) startPhase=\(candidate.startPhase) endPhase=\(Double(currentSampleFrame)) ticks=\(candidate.tickCount) elapsedSeconds=\(elapsedSeconds)")
            dvsLapCompletedObserver?(
                DVSLapSnapshot(
                    direction: schedulingDirection,
                    lapSteps: lapSteps,
                    startPhase: candidate.startPhase,
                    endPhase: Double(currentSampleFrame),
                    tickCount: candidate.tickCount,
                    elapsedSeconds: elapsedSeconds
                )
            )
            dvsLapCandidate = DVSLapCandidate(
                direction: schedulingDirection,
                startAccumulatedSteps: dvsAccumulatedSteps,
                startPhase: Double(currentSampleFrame),
                startUptime: now
            )
        }
        #endif
        return true
    }

    private func dvsOutputTiming(
        controlWindow: TimeInterval,
        now: TimeInterval,
        interruptsQueuedAudio: Bool
    ) -> (outputWindow: TimeInterval, estimatedQueuedDuration: TimeInterval) {
        let elapsedSinceEstimate = lastDVSQueueEstimateAt.map {
            max(0, now - $0)
        } ?? .infinity
        let remainingQueue = interruptsQueuedAudio
            ? 0
            : max(0, estimatedDVSQueuedDuration - elapsedSinceEstimate)
        let cushionTopUp = max(0, dvsQueueCushion - remainingQueue)
        let outputWindow = controlWindow + cushionTopUp
        return (
            outputWindow,
            min(
                controlWindow + dvsQueueCushion,
                remainingQueue + outputWindow
            )
        )
    }

    private func resetDVSGrainTiming() {
        pendingDVSControlWindow = 0
        estimatedDVSQueuedDuration = 0
        lastDVSQueueEstimateAt = nil
        lastDVSConsumedControlWindow = nil
        lastDVSScheduledOutputWindow = nil
    }

    /// Stop playback (e.g. when platter is idle). Click-free: a short bounded
    /// output-gain ramp (raised cosine, ~10 ms) precedes the actual
    /// `playerNode.stop()`, so whatever grain is mid-playback is faded rather
    /// than hard-truncated. Generation-protected so a quick resume cannot be
    /// executed by a stale stop (see `beginStopRamp`).
    func pausePlayback() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.dvsContinuousRenderer.publishIdle()
            self.lastScheduledDirection = nil
            let id = self.loadedSampleID
            self.debugPublishOnMainAsync(field: "statusLabel.paused") { [weak self] in
                guard let self, let id else { return }
                self.statusLabel = "loaded: \(id) · paused"
            }
            if self.playerNode.isPlaying {
                self.beginStopRamp()
            } else {
                self.cancelStopRamp()
            }
        }
    }

    /// Resume after pause.
    func resumePlayback() {
        audioQueue.async { [weak self] in
            guard let self, self.loadedSampleID != nil else { return }
            // Invalidate any in-flight stop ramp: a quick resume must not be
            // followed by the stale ramp's `stop()`, and volume is restored.
            self.stopRampGeneration += 1
            self.cancelStopRamp()
            self.playerNode.volume = 1.0
            self.playerNode.play()
        }
    }

    /// Unload the current sample and stop audio.
    func unload() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.dvsContinuousRenderer.publishIdle()
            self.stopRampGeneration += 1
            self.cancelStopRamp()
            self.playerNode.stop()
            self.playerNode.volume = 1.0
            self.forwardBuffer = nil
            self.loadedSampleID = nil
            self.totalFrames = 0
            self.lastScheduledSteps = 0
            self.lastScheduledDirection = nil
            self.diagnosticPreviewPlayedSampleID = nil
            self.currentSampleFrame = 0
            self.lastPlatterSteps = nil
            self.lastRawMIDISteps = nil
            self.midiAccumulatedSteps = 0
            self.dvsLoopFrames = 0
            self.dvsAccumulatedSteps = 0
            self.wasDVSMotionActive = false
            self.dvsDefinitivelyStopped = false
            self.dvsRestartMotionTicks = 0
            self.midiContinuousAccumulatedSteps = 0
            self.midiContinuousDrive.reset()
            self.midiContinuousWasActive = false
            // Preserve DVS ownership across unload if it is authoritatively
            // active — see the matching comment in `applyLoadedBufferState`.
            self.platterRenderOwner = self.dvsOwnershipActive ? .dvs : .none
            self.lastMIDIContinuousRejectionReason = nil
            #if DEBUG
            self.dvsLapCandidate = nil
            self.previousGrainScalars = nil
            #endif
            self.lastScheduledSourceFrame = nil
            self.lastScheduledSegmentFrames = nil
            self.lastScheduledRate = nil
            self.forwardScheduleCount = 0
            self.backwardScheduleCount = 0
            self.lastScheduleSkippedReason = nil
            self.lastEffectiveFrameDelta = nil
            self.lastReversalCompensated = false
            self.resetDVSGrainTiming()
            print("[ScratchSamplePlaybackController] unloaded")
            self.debugPublishOnMainAsync(field: "unload") { [weak self] in
                self?.statusLabel = "idle"
                self?.crossfaderGate = 1.0
                self?.lastCrossfaderRawValue = nil
            }
        }
    }

    // MARK: - Crossfader gate

    /// Apply crossfader CC8 value as audio gate.
    ///
    /// Rane ONE MKII: ch=15 CC8, range 0–127.
    ///   - 0   → fully closed (cut, volume 0.0)
    ///   - 127 → fully open (volume 1.0)
    ///
    /// Dispatches to the audio queue and returns immediately.
    func setCrossfader(value: Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let normalized = Float(value) / 127.0
            let raw = value
            self.playerNode.volume = 1.0
            self.debugPublishOnMainAsync(field: "crossfaderGate") { [weak self] in
                self?.crossfaderGate = normalized
                self?.lastCrossfaderRawValue = raw
            }
        }
    }

    // MARK: - Learned mixer gain (crossfader × right upfader)
    //
    // Applies learned, calibrated crossfader/right-upfader values as
    // scratch-sample audio gain — scratchGain = rightUpfaderGain ×
    // crossfaderRightDeckGain — published to `dvsContinuousRenderer`'s
    // real-time-safe atomic mailbox, the single render callback both the
    // direct-MIDI and DVS continuous-renderer paths already share (both
    // `midiUsesContinuousRenderer` and `dvsUsesContinuousRenderer` default
    // true), so the learned gain applies identically regardless of motion
    // source. Deliberately separate from `crossfaderGate`/`setCrossfader`
    // above (an earlier, unused CC8-hardcoded prototype with no learned-
    // mapping awareness and a different, linear curve) and from
    // `playerNode.volume` (owned exclusively by the click-free stop ramp)
    // — this never reads or writes either.

    /// Right (scratch-deck) upfader gain, 0...1, continuous. Defaults to
    /// unity: an unmapped control, or one that hasn't received a value
    /// this session, must never mute audio. Confined to `audioQueue`.
    private var rightUpfaderGain: Double = 1.0

    /// Crossfader's right-deck scratch gain after the cut curve, 0...1.
    /// Same unity default and the same reason. Confined to `audioQueue`.
    private var crossfaderRightDeckGain: Double = 1.0

    /// Bounded cut-in region near the crossfader's left (closed) edge, as
    /// a fraction of full throw. Below this fraction, right-deck gain
    /// ramps linearly from 0 at the physical left edge to 1 at the
    /// boundary; at and beyond it (center, right), gain is 1. Mirrors the
    /// project's existing `crossfaderCutWidth` convention for Rane-style
    /// crossfader geometry (`ScratchAnalysisCalibration`,
    /// `TravelLaneDebugView`'s default of 0.05) — kept as its own
    /// constant here since notation analysis and live audio gain are
    /// otherwise independent subsystems.
    static let crossfaderCutInWidth: Double = 0.05

    /// Maps a normalized crossfader position (0 = physical left edge, 1 =
    /// physical right edge) to the right deck's scratch-audio gain: a cut
    /// curve, not a linear pan. Pure function — no state — so it is
    /// trivially unit-testable in isolation from the controller/renderer.
    static func crossfaderRightDeckGain(forNormalizedPosition normalized: Double) -> Double {
        guard normalized.isFinite else { return 0 }
        let clamped = min(max(normalized, 0), 1)
        guard clamped > 0 else { return 0 }
        guard clamped < crossfaderCutInWidth else { return 1 }
        return clamped / crossfaderCutInWidth
    }

    /// Sets the learned right-upfader's normalized gain (0 = down/silence,
    /// 1 = unity, continuous in between — already calibrated/inverted by
    /// the caller via `MIDILearnedControl.normalizedValue(from:)`).
    /// Dispatches to `audioQueue` and returns immediately; the click-free
    /// ramp that avoids audible steps lives in the render callback, not
    /// here — this only updates the target.
    func setRightUpfaderGain(_ normalizedGain: Double) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.rightUpfaderGain = normalizedGain.isFinite ? min(max(normalizedGain, 0), 1) : 0
            self.publishUserMixerGain()
        }
    }

    /// Sets the learned crossfader's normalized physical position (0 =
    /// left edge, 1 = right edge, already calibrated/inverted by the
    /// caller) and applies the right-deck cut curve. Dispatches to
    /// `audioQueue` and returns immediately.
    func setCrossfaderPosition(_ normalizedPosition: Double) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let sanitized = normalizedPosition.isFinite ? min(max(normalizedPosition, 0), 1) : 0
            self.crossfaderRightDeckGain = Self.crossfaderRightDeckGain(forNormalizedPosition: sanitized)
            self.publishUserMixerGain()
        }
    }

    /// Resets the right-upfader gain contribution to unity: called
    /// whenever its mapping is no longer trustworthy for the current
    /// session — cleared, replaced/relearned, recalibrated, or
    /// re-inverted — so a stale value (e.g. a fader last seen at 0)
    /// cannot keep muting audio until a fresh CC event arrives under the
    /// new interpretation. Dispatches to `audioQueue` and returns
    /// immediately, same as the setter above.
    func resetRightUpfaderGainToUnity() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.rightUpfaderGain = 1.0
            self.publishUserMixerGain()
        }
    }

    /// Resets the crossfader's right-deck gain contribution to unity. Same
    /// rationale as `resetRightUpfaderGainToUnity`.
    func resetCrossfaderGainToUnity() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.crossfaderRightDeckGain = 1.0
            self.publishUserMixerGain()
        }
    }

    /// Resets both mixer inputs to unity in one queued step (no
    /// intermediate publish) — used when neither is trustworthy for the
    /// current session: a MIDI source change, a mapping load (including
    /// an empty/missing/failed load), or clearing every mapping for a
    /// device.
    func resetUserMixerGainToUnity() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.rightUpfaderGain = 1.0
            self.crossfaderRightDeckGain = 1.0
            self.publishUserMixerGain()
        }
    }

    /// Combines the two independent mixer inputs and publishes the result
    /// to the continuous renderer's atomic mailbox. Must run on
    /// `audioQueue` (the mailbox's documented single-writer contract).
    private func publishUserMixerGain() {
        dvsContinuousRenderer.publishUserMixerGain(rightUpfaderGain * crossfaderRightDeckGain)
    }

    // MARK: - Queue drain (test seam and ordered shutdown)

    /// Block the caller until all pending audio-queue work completes.
    ///
    /// Use in tests before reading state that is mutated on the audio queue.
    /// Do not call from within the audio queue itself.
    func waitForAudioQueue() {
        audioQueue.sync {}
    }

    // MARK: - Diagnostics

    /// Point-in-time snapshot of playback state, for distinguishing "no
    /// audio because nothing was ever scheduled" from "scheduling
    /// happened but the output path is silent" — the two failure classes
    /// that look identical from the UI toggle / bridge status alone.
    struct DVSPlaybackDiagnostics: Equatable {
        let loadedSampleID: String?
        let lastLoadError: String?
        let engineRunning: Bool
        let playerIsPlaying: Bool
        let currentSampleFrame: Int
        let lastScheduleSkippedReason: String?
        let lastScheduledRate: Float?
        let lastScheduledSourceFrame: Int?
        let lastScheduledDirection: ScratchPlatterDirection?
        let forwardScheduleCount: Int
        let backwardScheduleCount: Int
    }

    /// Reads all fields together on `audioQueue` so the snapshot is
    /// internally consistent (no torn reads across a concurrent
    /// `positionDidChangeOnQueue` mutation). Safe to call from any
    /// thread, including the main thread on a UI polling timer — the
    /// audioQueue work here is a handful of variable reads, not I/O.
    func diagnosticsSnapshot() -> DVSPlaybackDiagnostics {
        audioQueue.sync {
            DVSPlaybackDiagnostics(
                loadedSampleID: loadedSampleID,
                lastLoadError: lastLoadError,
                engineRunning: engineStarted,
                playerIsPlaying: playerNode.isPlaying,
                currentSampleFrame: currentSampleFrame,
                lastScheduleSkippedReason: lastScheduleSkippedReason,
                lastScheduledRate: lastScheduledRate,
                lastScheduledSourceFrame: lastScheduledSourceFrame,
                lastScheduledDirection: lastScheduledDirection,
                forwardScheduleCount: forwardScheduleCount,
                backwardScheduleCount: backwardScheduleCount
            )
        }
    }

    // MARK: - Position → frame mapping

    /// Map accumulated direct-MIDI CC6 steps to a sample frame index.
    /// Cycles within 0..<totalFrames. One full revolution (~3600 steps,
    /// Rane ONE MKII direct-MIDI geometry — cue-lock drift fix,
    /// 2026-08-10) wraps the full sample; forward/backward advances at
    /// the midiFramesPerStep pace (driven by vinyl RPM, not sample
    /// length).
    func sampleFrame(for steps: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        let scaled = (Double(steps) * Double(totalFrames)) / Double(Self.raneOneMKIIDirectMIDIStepsPerRevolution)
        var wrapped = scaled.truncatingRemainder(dividingBy: Double(totalFrames))
        if wrapped < 0 { wrapped += Double(totalFrames) }
        return min(max(Int(wrapped), 0), totalFrames - 1)
    }

    /// Wraps a frame index into the loop region `[0, totalFrames)` — the
    /// full loaded sample. Frame 0 is the "12 o'clock" loop origin: crossing
    /// past `totalFrames` wraps to the start, crossing before 0 wraps to the
    /// end, in both cases continuing motion rather than stopping at the edge.
    private func wrappedSampleFrame(_ frame: Int) -> Int {
        guard totalFrames > 0 else { return 0 }
        let wrapped = frame % totalFrames
        return wrapped < 0 ? wrapped + totalFrames : wrapped
    }

    /// Direct-MIDI-only counterpart to `dvsLoopPhaseFrame` (cue-lock drift
    /// fix, 2026-08-10): identical formula, using `midiFramesPerStep`
    /// (Rane ONE MKII direct-MIDI CC6 geometry) instead of `framesPerStep`
    /// (DVS/timecode geometry). Shares `dvsLoopFrames` with the DVS path
    /// deliberately — that value is the real one-revolution audio-frame
    /// duration at this sample's rate, not a steps-per-revolution-derived
    /// quantity, so both paths correctly wrap against the same loop.
    private func midiLoopPhaseFrame(forAccumulatedSteps steps: Double) -> Double {
        guard dvsLoopFrames > 0 else { return 0 }
        var wrapped = (steps * midiFramesPerStep).truncatingRemainder(dividingBy: dvsLoopFrames)
        if wrapped < 0 { wrapped += dvsLoopFrames }
        return wrapped
    }

    // MARK: - DVS rotational loop (listening-fix #4, uncommitted)

    /// Number of raw source frames the "ahh" content is ramped to/from
    /// silence over, at both the head (frame 0) and tail (`totalFrames`)
    /// of the loaded clip. Declicks the content boundary as a function of
    /// loop *position* rather than direction of travel, so it works
    /// identically whether the loop is entering the content, leaving it,
    /// or reversing exactly at the edge — one gain curve handles all three
    /// without a separate directional fade pass. Small relative to the
    /// ~46k-frame clip, so it costs no audible amount of the "ahh" itself.
    private let dvsLoopContentFadeFrames = 64

    /// Maps cumulative real platter steps to a position within the DVS
    /// virtual one-revolution loop `[0, dvsLoopFrames)`. Pure function of
    /// the accumulated step count — not incrementally chained — so
    /// retracing any run of steps exactly retraces the same phase and
    /// round-trip motion cannot drift (mod float rounding, which does not
    /// itself accumulate since every call recomputes from scratch).
    private func dvsLoopPhaseFrame(forAccumulatedSteps steps: Double) -> Double {
        guard dvsLoopFrames > 0 else { return 0 }
        var wrapped = (steps * framesPerStep).truncatingRemainder(dividingBy: dvsLoopFrames)
        if wrapped < 0 { wrapped += dvsLoopFrames }
        return wrapped
    }

    /// Copies `frameCount` frames of the DVS rotational loop starting at
    /// `startPhase` (a position in `[0, dvsLoopFrames)`). Positions inside
    /// `[0, totalFrames)` read real "ahh" PCM, ramped to silence within
    /// `dvsLoopContentFadeFrames` of either edge; positions in
    /// `[totalFrames, dvsLoopFrames)` — the remainder of the physical
    /// revolution the short clip does not fill — are true silence. Because
    /// `dvsLoopFrames` is exactly one revolution and is always `>=
    /// totalFrames` for the loaded DVS asset, a single revolution always
    /// plays the content at most once, however large `frameCount` grows.
    private func copyDVSLoopSegment(
        from source: AVAudioPCMBuffer,
        startPhase: Double,
        frameCount: Int,
        direction: ScratchPlatterDirection
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              dvsLoopFrames > 0,
              totalFrames > 0,
              source.format.commonFormat == .pcmFormatFloat32,
              !source.format.isInterleaved,
              let sourceChannels = source.floatChannelData,
              let out = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let outChannels = out.floatChannelData else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(frameCount)
        let channelCount = Int(source.format.channelCount)
        let total = Double(totalFrames)
        let fadeWidth = Double(dvsLoopContentFadeFrames)
        let step: Double = direction == .forward ? 1 : -1

        for i in 0..<frameCount {
            var phase = (startPhase + step * Double(i)).truncatingRemainder(dividingBy: dvsLoopFrames)
            if phase < 0 { phase += dvsLoopFrames }
            if phase < total {
                let index = min(Int(phase), totalFrames - 1)
                let gain = Float(min(min(phase, total - phase), fadeWidth) / fadeWidth)
                for c in 0..<channelCount {
                    outChannels[c][i] = sourceChannels[c][index] * gain
                }
            } else {
                for c in 0..<channelCount {
                    outChannels[c][i] = 0
                }
            }
        }
        return out
    }

    /// Apply a symmetric linear fade-in/fade-out ramp to the leading and trailing
    /// `grainEdgeFadeFrames` samples of `buffer`, mutating it in place.
    /// The fade length is clamped to at most half the buffer's frame count so
    /// that tiny grains produced near sample boundaries are never fully zeroed.
    /// Listening-fix #3 (uncommitted): short de-click ramp (smoothstep
    /// 0 -> 1) over the first `frames` frames of the buffer, applied to the
    /// head of the first DVS grain scheduled after a genuine scheduling gap
    /// (noMotion / tinyGrain / unusable-signal), so playback resumes with a
    /// fade-in instead of hard-cutting from silence. Deliberately applied to
    /// the head ONLY and ONLY after a gap: contiguous DVS grains are never
    /// faded (see the warning below), so no scheduler-rate amplitude
    /// modulation is introduced.
    func applyHeadFade(to buffer: AVAudioPCMBuffer, frames: Int) {
        guard frames > 1,
              let channels = buffer.floatChannelData else { return }
        let count = min(frames, Int(buffer.frameLength))
        guard count > 1 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let data = channels[channel]
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                data[i] *= t * t * (3 - 2 * t)
            }
        }
    }

    func applyEdgeFade(to buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let f = min(grainEdgeFadeFrames, count / 2)
        guard f > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let data = channels[ch]
            for i in 0..<f {
                let ramp = Float(i) / Float(f)
                data[i]             *= ramp   // fade in: frame 0 → 0.0, frame f-1 → (f-1)/f
                data[count - 1 - i] *= ramp   // fade out: last frame → 0.0
            }
        }
    }

    // MARK: - Pure gap-aware edge fades (offline render path)

    /// Pure linear fade-out of the trailing `fadeFrames` samples of a grain
    /// channel, used by the offline render path exactly where a scheduling
    /// gap hard-cuts a DVS grain to silence (see Task 13/14 spec: DVS grains
    /// are intentionally never faded in the live queue so contiguous grains
    /// don't amplitude-modulate at the scheduler rate, which leaves every
    /// gap edge as a hard cut to silence). The ramp is identical to
    /// `applyEdgeFade`'s tail ramp (last sample → 0.0) and clamps to at most
    /// half the array's count, so a tiny grain is never fully zeroed. Pure
    /// value — no AVAudioEngine, safe on any thread.
    static func fadeOutTail(_ samples: inout [Float], fadeFrames: Int) {
        let count = samples.count
        let f = min(max(0, fadeFrames), count / 2)
        guard f > 0 else { return }
        for i in 0..<f {
            let ramp = Float(i) / Float(f)
            samples[count - 1 - i] *= ramp
        }
    }

    /// Pure linear fade-in of the leading `fadeFrames` samples of a grain
    /// channel (first sample → 0.0), the head-side counterpart of
    /// `fadeOutTail`. Same clamp semantics.
    static func fadeInHead(_ samples: inout [Float], fadeFrames: Int) {
        let count = samples.count
        let f = min(max(0, fadeFrames), count / 2)
        guard f > 0 else { return }
        for i in 0..<f {
            let ramp = Float(i) / Float(f)
            samples[i] *= ramp
        }
    }

    private func directionDescription(_ direction: ScratchPlatterDirection) -> String {
        switch direction {
        case .forward: return "forward"
        case .backward: return "backward"
        }
    }

    // MARK: - WAV resolution

    private static let sampleFileNames: [String: String] = [
        "ahhh":          "ahhh.wav",
        "dvs_ahhh":      "VirtualPlatter/ahhh.wav",
        "fresh":         "fresh.wav",
        "ah_yeah":       "ah_yeah.wav",
        "check_it_out":  "check_it_out.wav",
    ]

    private func wavURL(for sampleID: String) -> URL? {
        guard let fileName = Self.sampleFileNames[sampleID],
              let root = Bundle.main.resourceURL else { return nil }
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var knownSampleIDs: Set<String> {
        Set(sampleFileNames.keys)
    }

    // MARK: - Buffer helpers

    private func readIntoBuffer(_ file: AVAudioFile) -> AVAudioPCMBuffer? {
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            print("[ScratchSamplePlaybackController] unsupported PCM format after normalization: \(format)")
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            print("[ScratchSamplePlaybackController] read error: \(error)")
            return nil
        }
        guard buffer.frameLength > 0,
              buffer.floatChannelData != nil else {
            print("[ScratchSamplePlaybackController] normalized buffer unavailable: \(format)")
            return nil
        }
        return buffer
    }

    private func reverseBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = source.format
        let frameCount = Int(source.frameLength)
        guard frameCount > 0,
              let reversed = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        reversed.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = reversed.floatChannelData else {
            print("[ScratchSamplePlaybackController] reverse skipped · reason=unsupportedFormat format=\(format)")
            return nil
        }
        let channelCount = Int(format.channelCount)

        for ch in 0..<channelCount {
            let src = srcChannels[ch]
            let dst = dstChannels[ch]
            for i in 0..<frameCount {
                dst[i] = src[frameCount - 1 - i]
            }
        }
        return reversed
    }

    /// Expands a sub-varispeed-floor DVS grain to its complete control-tick
    /// window. Interpolation keeps the exact source-frame displacement (and
    /// therefore needle position) while producing continuous audio for the
    /// whole window; the player node then runs this prepared grain at 1×.
    ///
    /// With at least 4 raw source frames, adjacent output samples are
    /// reconstructed with Catmull-Rom cubic interpolation instead of a
    /// straight line between the two surrounding raw samples. Plain linear
    /// interpolation collapses a grain's true waveform curvature into a flat
    /// ramp between control points — measured (offline, against the saved
    /// `slow_reversals`/`fast_reversals` hardware captures) to roughly halve
    /// the grain's oscillation/high-frequency content relative to a normal
    /// (non-stretched) grain of the same source. Slow scratch motion spends a
    /// large fraction of its grains on this path (as high as ~38% observed in
    /// `slow_reversals`), so that quality gap dominates the audible character
    /// of slow playback specifically, rather than showing up as a single
    /// isolated boundary click — matching the reported "static-like" texture.
    /// Cubic interpolation uses the same two raw samples the grain would
    /// already interpolate between, plus one real sample of context on each
    /// side (clamped to the segment's own edges), so it recovers more of the
    /// true waveform shape without reading beyond the segment already copied
    /// for this grain and without changing needle position/frame accounting
    /// at all. Grains with only 2-3 raw source frames fall back to the
    /// original linear method — there is no additional real information to
    /// use, and Catmull-Rom degenerates to it in that regime anyway.
    private func copyTimeStretched(
        _ source: AVAudioPCMBuffer,
        outputFrameCount: Int
    ) -> AVAudioPCMBuffer? {
        let inputFrameCount = Int(source.frameLength)
        let format = source.format
        guard inputFrameCount >= 2,
              outputFrameCount >= 1,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let inputChannels = source.floatChannelData,
              let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(outputFrameCount)
              ),
              let outputChannels = output.floatChannelData else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(outputFrameCount)

        let inputSpan = Double(inputFrameCount - 1)
        let outputSpan = Double(max(1, outputFrameCount - 1))
        let useCubicInterpolation = inputFrameCount >= 4
        for channel in 0..<Int(format.channelCount) {
            let input = inputChannels[channel]
            let destination = outputChannels[channel]
            for outputIndex in 0..<outputFrameCount {
                let inputPosition = Double(outputIndex) * inputSpan / outputSpan
                let lowerIndex = Int(inputPosition)
                let upperIndex = min(lowerIndex + 1, inputFrameCount - 1)
                let fraction = Float(inputPosition - Double(lowerIndex))
                if useCubicInterpolation {
                    let beforeIndex = max(0, lowerIndex - 1)
                    let afterIndex = min(inputFrameCount - 1, upperIndex + 1)
                    destination[outputIndex] = Self.catmullRomInterpolate(
                        p0: input[beforeIndex],
                        p1: input[lowerIndex],
                        p2: input[upperIndex],
                        p3: input[afterIndex],
                        t: fraction
                    )
                } else {
                    destination[outputIndex] =
                        input[lowerIndex] +
                        ((input[upperIndex] - input[lowerIndex]) * fraction)
                }
            }
        }
        return output
    }

    /// Standard Catmull-Rom cubic spline: passes exactly through `p1` at
    /// `t == 0` and `p2` at `t == 1`, using `p0`/`p3` only to shape the
    /// tangent between them — unlike linear interpolation, the curve's slope
    /// is continuous with its neighbors instead of kinking at every raw
    /// sample.
    private static func catmullRomInterpolate(p0: Float, p1: Float, p2: Float, p3: Float, t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private func copySegment(
        from source: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard startFrame >= 0,
              startFrame < sourceFrames,
              frameCount > 0 else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=invalidSegment sourceFrame=\(startFrame) frames=\(frameCount) totalFrames=\(sourceFrames)")
            return nil
        }

        let actualCount = min(frameCount, sourceFrames - startFrame)
        guard actualCount > 0,
              startFrame + actualCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(actualCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(actualCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            print("[ScratchSamplePlaybackController] schedule skipped · reason=unsupportedFormat sourceFrame=\(startFrame) frames=\(actualCount) totalFrames=\(sourceFrames)")
            return nil
        }
        let channelCount = Int(format.channelCount)

        for ch in 0..<channelCount {
            let src = srcChannels[ch].advanced(by: startFrame)
            let dst = dstChannels[ch]
            dst.update(from: src, count: actualCount)
        }
        return segment
    }

    /// Copies a complete forward grain from the loop. If the requested
    /// displacement reaches the WAV end, the remainder continues at frame
    /// zero instead of returning a shortened buffer.
    private func copyWrappedForwardSegment(
        from source: AVAudioPCMBuffer,
        startFrame: Int,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard startFrame >= 0,
              startFrame < sourceFrames,
              frameCount > 0,
              frameCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            return nil
        }

        for channel in 0..<Int(format.channelCount) {
            let sourceChannel = srcChannels[channel]
            let destination = dstChannels[channel]
            for offset in 0..<frameCount {
                destination[offset] = sourceChannel[(startFrame + offset) % sourceFrames]
            }
        }
        return segment
    }

    /// Copies a complete backward grain from the loop. If the requested
    /// displacement reaches frame zero, the remainder continues backward
    /// from the WAV's final frame instead of returning a shortened buffer.
    private func copyWrappedReversedSegmentEnding(
        at endFrame: Int,
        frameCount: Int,
        from source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        let format = source.format
        let sourceFrames = Int(source.frameLength)
        guard endFrame >= 0,
              endFrame < sourceFrames,
              frameCount > 0,
              frameCount <= sourceFrames,
              let segment = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }
        segment.frameLength = AVAudioFrameCount(frameCount)

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              let srcChannels = source.floatChannelData,
              let dstChannels = segment.floatChannelData else {
            return nil
        }

        for channel in 0..<Int(format.channelCount) {
            let sourceChannel = srcChannels[channel]
            let destination = dstChannels[channel]
            for offset in 0..<frameCount {
                let index = (endFrame - offset) % sourceFrames
                destination[offset] = sourceChannel[
                    index < 0 ? index + sourceFrames : index
                ]
            }
        }
        return segment
    }
}
