// DVSContinuousVinylRenderer.swift
// ScratchLab Desktop — Continuous DVS sample renderer
//
// Replaces the DVS-only 60 Hz short-grain scheduling path with a single
// continuous render callback (AVAudioSourceNode). The control side keeps
// updating at its existing ~60 Hz cadence, but audio is generated at the
// hardware render rate from a renderer-owned continuous fractional source
// phase, so no per-tick grain joins exist to click, gap, overlap, or
// amplitude-modulate.
//
// Model
// - The loaded sample is immutable PCM in memory (copied once at install).
// - The renderer owns a continuous fractional phase in the existing DVS
//   virtual one-revolution loop domain `[0, loopFrames)`: `[0,
//   contentFrames)` is real audio (declicked at both content edges by the
//   same position-based fade the grain path used), `[contentFrames,
//   loopFrames)` is true silence. Phase wraps through the loop in both
//   directions, preserving exactly one "ahh" per physical revolution and
//   the established 12-o'clock cue (phase 0 = frame 0 = cue).
// - Each output frame advances phase by the smoothed signed DVS velocity
//   (source frames/second). Positive renders forward, negative backward.
//   Velocity is smoothed with a short one-pole so reversals and stops are
//   continuous and click-free. Valid signed velocities are preserved all
//   the way down to the pipeline's existing accepted-motion behaviour —
//   there is no renderer-side speed gate.
// - The click-free settle to silence is controlled ONLY by the pipeline's
//   existing authoritative decisions: an explicit idle publish (genuine
//   no-direction / no-motion tick, pause, unload) or a stale control
//   snapshot ramps the output gain to zero. Phase is NEVER reset by
//   stopping, so a slow restart resumes immediately from the retained
//   phase.
// - The control side also publishes the authoritative platter phase (the
//   controller's `dvsAccumulatedSteps` anchor mapped into the loop). The
//   renderer slews toward it with a correction bounded to a small fraction
//   of the current velocity per frame, so integration drift cannot
//   accumulate but the correction can never produce an audible
//   discontinuity or move the established cue (at zero velocity the
//   correction freezes entirely).
// - If control updates stop arriving (drive deactivated, worker stalled)
//   the renderer treats the snapshot as stale after 0.25 s — the same
//   maximum trusted control window the DVS pipeline already uses — and
//   settles to silence instead of free-running forever.
//
// Real-time safety
// The render callback performs no heap allocation, acquires no lock,
// dispatches no block, does no file access, no logging, no string
// formatting, touches no SwiftUI/observable state, and creates no ARC
// objects: the AVAudioSourceNode closure captures the render-state pointer
// and the mailbox reference once, at creation. Per callback it performs a
// fixed number of lock-free atomic loads and a bounded per-frame loop —
// no retry loops, no waiting.
//
// Cross-thread publication (control → render) uses `Synchronization.Atomic`
// exclusively:
// - Each scalar control field is one `Atomic<UInt64>` (Doubles as bit
//   patterns), so no field can tear and no plain cross-thread stores
//   exist. The writer stores fields with relaxed ordering and then bumps a
//   single epoch atomic with releasing order; the reader loads the epoch
//   with acquiring order first, which guarantees it observes field values
//   at least as new as that epoch. A reader that observes fields from a
//   publish already in progress simply gets newer values — every field is
//   independently sanitized and bounded, and the render math smooths all
//   of them, so cross-field mixing across adjacent ~16 ms ticks is
//   harmless by construction. This is one-directional change detection,
//   not a seqlock: there is no retry.
// - The sample table is published as a single atomic pointer
//   (release store / acquire load) to a fully initialized, immutable,
//   heap-allocated table. Neither table allocations nor the PCM they point
//   to are ever freed while the renderer is alive, so a stale pointer read
//   is always into live, immutable memory (sample loads are rare, bounded
//   user actions).
// The render-owned integration state (phase, velocity, gain, correction)
// lives in memory only the render callback ever touches after init.

import AVFoundation
import Foundation
import Synchronization

// MARK: - Immutable sample table

/// One immutable, fully initialized description of the installed sample.
/// Allocated once per install, published by a single atomic pointer store,
/// and never mutated or freed afterwards (retained until renderer deinit).
struct DVSVinylSampleTable {
    /// Monotonic install identity — lets the render side detect a swap
    /// without comparing pointer values.
    let identity: UInt64
    let channel0: UnsafePointer<Float>
    /// nil for mono sources (render duplicates channel 0).
    let channel1: UnsafePointer<Float>?
    let contentFrames: Int
    let loopFrames: Double
    let contentFadeFrames: Double
    let sourceSampleRate: Double
}

// MARK: - Control snapshot

/// Plain sanitized control values as read from the atomic mailbox (or
/// constructed directly by deterministic tests).
struct DVSVinylControlSnapshot {
    var epoch: UInt64
    var velocity: Double
    var authoritativePhase: Double
    var active: Bool
}

// MARK: - Pure render core (single-owner state + deterministic math)

/// Render-owned integration state and the complete per-frame math for the
/// continuous DVS renderer. This is a plain value with no synchronization
/// of its own: in production exactly one owner (the render callback)
/// touches it after init; in tests it is driven synchronously. All
/// cross-thread concerns live in `DVSContinuousVinylRenderer`'s atomic
/// mailbox, never here.
struct DVSContinuousVinylRenderCore {

    // MARK: Tuning constants

    /// One-pole time constant for signed velocity smoothing. Short enough
    /// that scratch reversals stay tight (~4 ms), long enough to be
    /// click-free and zipper-free.
    static let velocitySmoothingSeconds: Double = 0.004
    /// One-pole time constant for the click-free gain ramp driven by the
    /// pipeline's authoritative active/idle/stale decision.
    static let gainSmoothingSeconds: Double = 0.003
    /// One-pole time constant for the click-free ramp applied to the
    /// learned-mixer (crossfader × right-upfader) user gain. Deliberately
    /// its own field/coefficient, separate from `gainSmoothingSeconds`
    /// above: that ramp is the pipeline's own active/idle/stale decision
    /// and must never be conflated with or overwritten by user mixer
    /// input — the two are combined only at final output, never merged
    /// into one state variable.
    static let userMixerGainSmoothingSeconds: Double = 0.005
    /// Exponential time constant for converging on the authoritative
    /// platter phase published by the control side.
    static let phaseCorrectionSeconds: Double = 0.150
    /// Hard per-frame cap on phase correction, as a fraction of the
    /// current per-frame velocity advance (≤ 2% instantaneous pitch
    /// deviation; correction freezes entirely at zero velocity, so it can
    /// never move the cue audibly while stopped).
    static let maxPhaseCorrectionRatio: Double = 0.02
    /// Control snapshots older than this are untrusted — mirrors the DVS
    /// pipeline's `maximumDVSControlWindow` — and settle to silence.
    static let staleControlSeconds: Double = 0.25
    /// Sanitization clamp for published velocities, as a multiple of the
    /// source sample rate (1.0x nominal speed advances one source frame
    /// per source-rate second). Purely a numeric guard against corrupt
    /// input — far above any real platter speed — never a behavior gate.
    static let maxVelocityRatio: Double = 8.0

    // MARK: Sample state (copied from the published table on swap)

    private(set) var sampleIdentity: UInt64 = 0
    private(set) var sampleChannel0: UnsafePointer<Float>?
    private(set) var sampleChannel1: UnsafePointer<Float>?
    private(set) var sampleContentFrames: Int = 0
    private(set) var sampleLoopFrames: Double = 0
    private(set) var sampleContentFadeFrames: Double = 1
    private(set) var sampleSourceRate: Double = 44_100

    // MARK: Last-ingested control values

    private(set) var controlVelocity: Double = 0
    private(set) var controlAuthoritativePhase: Double = 0
    private(set) var controlActive: Bool = false
    private var lastSeenControlEpoch: UInt64 = 0
    private var framesSinceControlUpdate: Int

    // MARK: Render-owned integration state

    private(set) var phase: Double = 0
    private(set) var velocity: Double = 0
    private(set) var gain: Double = 0
    private(set) var pendingPhaseCorrection: Double = 0
    /// Last-ingested target for the learned-mixer user gain (crossfader ×
    /// right upfader, already combined and clamped by the control side).
    /// Starts at 1.0 (unity) so audio is never muted before any mixer
    /// control has been learned or moved — matches the product rule that
    /// an absent mapping must never mute audio.
    private(set) var targetUserMixerGain: Double = 1.0
    /// Click-free-ramped user mixer gain actually applied at output. Also
    /// starts at unity, independent of and combined only multiplicatively
    /// with the pipeline's own active/idle `gain` above — never merged
    /// into it, never overwritten by it.
    private(set) var userMixerGain: Double = 1.0

    // MARK: Derived per-instance constants

    let outputSampleRate: Double
    private let velocityCoefficient: Double
    private let gainCoefficient: Double
    private let userMixerGainCoefficient: Double
    private let correctionCoefficient: Double
    private let staleControlFrames: Int

    init(outputSampleRate: Double) {
        let rate = outputSampleRate > 0 ? outputSampleRate : 44_100
        self.outputSampleRate = rate
        velocityCoefficient = 1 - exp(-1 / (Self.velocitySmoothingSeconds * rate))
        gainCoefficient = 1 - exp(-1 / (Self.gainSmoothingSeconds * rate))
        userMixerGainCoefficient = 1 - exp(-1 / (Self.userMixerGainSmoothingSeconds * rate))
        correctionCoefficient = 1 - exp(-1 / (Self.phaseCorrectionSeconds * rate))
        staleControlFrames = Int(Self.staleControlSeconds * rate)
        // Start stale so nothing sounds before the first control publish.
        framesSinceControlUpdate = Int.max / 2
    }

    // MARK: Ingest (render thread in production; tests directly)

    /// Applies a published sample table. Resets integration state on an
    /// identity change — this is a load, not a velocity-zero event.
    mutating func ingest(table: DVSVinylSampleTable) {
        guard table.identity != sampleIdentity else { return }
        sampleIdentity = table.identity
        sampleChannel0 = table.channel0
        sampleChannel1 = table.channel1
        sampleContentFrames = table.contentFrames
        sampleLoopFrames = table.loopFrames.isFinite ? table.loopFrames : 0
        sampleContentFadeFrames = max(1, table.contentFadeFrames)
        sampleSourceRate = table.sourceSampleRate > 0 ? table.sourceSampleRate : 44_100
        phase = 0
        velocity = 0
        gain = 0
        pendingPhaseCorrection = 0
        controlVelocity = 0
        controlActive = false
        framesSinceControlUpdate = Int.max / 2
    }

    /// Applies a control snapshot. On an epoch change the freshness clock
    /// restarts and the bounded correction toward the authoritative anchor
    /// is recomputed — never applied as a jump.
    mutating func ingest(snapshot: DVSVinylControlSnapshot) {
        guard snapshot.epoch != lastSeenControlEpoch else { return }
        lastSeenControlEpoch = snapshot.epoch
        framesSinceControlUpdate = 0
        controlVelocity = Self.sanitizedVelocity(
            snapshot.velocity,
            sourceSampleRate: sampleSourceRate
        )
        controlActive = snapshot.active
        if snapshot.authoritativePhase.isFinite {
            controlAuthoritativePhase = snapshot.authoritativePhase
            if sampleLoopFrames > 0 {
                pendingPhaseCorrection = Self.wrappedSignedDelta(
                    controlAuthoritativePhase - phase,
                    loop: sampleLoopFrames
                )
            }
        }
    }

    /// Applies the latest published learned-mixer user gain (crossfader ×
    /// right upfader, already combined by the control side). Unlike
    /// `ingest(snapshot:)`, this is not epoch-gated — the mixer gain is
    /// independent of the velocity/phase/active triple, so every render
    /// call simply reads whatever was last published; the ramp toward it
    /// happens per-frame in `render`, so a stale-by-one-callback read is
    /// inaudible by construction. Sanitized defensively here too (fails to
    /// 0/silent, not 1/full-volume, on malformed input), mirroring the
    /// existing `gain` field's own re-entry guard below.
    mutating func ingestUserMixerGain(_ value: Double) {
        targetUserMixerGain = value.isFinite ? min(max(value, 0), 1) : 0
    }

    /// Clamps a velocity to finite, bounded values. Exposed for the
    /// publication-sanitization tests.
    static func sanitizedVelocity(_ velocity: Double, sourceSampleRate: Double) -> Double {
        guard velocity.isFinite else { return 0 }
        let rate = sourceSampleRate > 0 ? sourceSampleRate : 44_100
        let limit = Self.maxVelocityRatio * rate
        return min(max(velocity, -limit), limit)
    }

    // MARK: Render

    /// Renders `frameCount` frames into the supplied channel buffers.
    /// `right` may be nil for mono output. Returns true when the entire
    /// buffer is silence (AVAudioSourceNode's `isSilence` hint).
    @discardableResult
    mutating func render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) -> Bool {
        guard let channel0 = sampleChannel0,
              sampleContentFrames > 1,
              sampleLoopFrames >= 4,
              Double(sampleContentFrames) <= sampleLoopFrames else {
            for i in 0..<frameCount {
                left[i] = 0
                right?[i] = 0
            }
            return true
        }
        let channel1 = sampleChannel1 ?? channel0

        // Defensive re-entry into a sane numeric state; the math below
        // cannot produce non-finite values from finite state, but a wedged
        // callback must be impossible regardless of history.
        if !phase.isFinite { phase = 0 }
        if !velocity.isFinite { velocity = 0 }
        if !gain.isFinite || gain < 0 { gain = 0 }
        if !userMixerGain.isFinite || userMixerGain < 0 { userMixerGain = 0 }
        if !targetUserMixerGain.isFinite { targetUserMixerGain = 0 }
        if !pendingPhaseCorrection.isFinite { pendingPhaseCorrection = 0 }

        let loop = sampleLoopFrames
        let loopIndexCount = max(1, Int(loop))
        let contentFrames = sampleContentFrames
        let fadeWidth = sampleContentFadeFrames
        let secondsPerFrame = 1 / outputSampleRate
        var silent = true

        for i in 0..<frameCount {
            if framesSinceControlUpdate < Int.max / 2 {
                framesSinceControlUpdate += 1
            }
            let fresh = framesSinceControlUpdate <= staleControlFrames
            let engaged = controlActive && fresh
            let effectiveTarget = engaged ? controlVelocity : 0
            velocity += (effectiveTarget - velocity) * velocityCoefficient

            if pendingPhaseCorrection != 0 {
                let cap = abs(velocity) * Self.maxPhaseCorrectionRatio * secondsPerFrame
                var step = pendingPhaseCorrection * correctionCoefficient
                if step > cap { step = cap } else if step < -cap { step = -cap }
                phase += step
                pendingPhaseCorrection -= step
            }

            phase += velocity * secondsPerFrame
            if phase >= loop || phase < 0 {
                phase = phase.truncatingRemainder(dividingBy: loop)
                if phase < 0 { phase += loop }
            }

            // Click-free settle/restore controlled ONLY by the pipeline's
            // authoritative active/idle decision and the staleness bound —
            // valid slow motion always renders at full level.
            let targetGain: Double = engaged ? 1 : 0
            gain += (targetGain - gain) * gainCoefficient

            // User mixer gain (learned crossfader × right upfader) ramps
            // every frame regardless of active/idle state — never gated by
            // `gain`'s early-continue below — so it is never left stale
            // mid-ramp when motion resumes. Phase/velocity above have
            // already advanced this frame either way: closing this fader
            // (or the pipeline going idle) never stops position tracking.
            userMixerGain += (targetUserMixerGain - userMixerGain) * userMixerGainCoefficient

            if gain < 0.000_001 {
                left[i] = 0
                right?[i] = 0
                continue
            }

            let base = phase.rounded(.down)
            let fraction = Float(phase - base)
            let index1 = Int(base)
            let index0 = index1 - 1 < 0 ? loopIndexCount - 1 : index1 - 1
            let index2 = index1 + 1 >= loopIndexCount ? 0 : index1 + 1
            let index3 = index2 + 1 >= loopIndexCount ? 0 : index2 + 1
            // Combined multiplicatively at the final output only — the two
            // gain sources stay fully independent state (see the field
            // doc comments above); neither is ever overwritten by the
            // other.
            let outputGain = Float(gain * userMixerGain)

            let leftValue = Self.catmullRom(
                Self.loopSample(channel0, index0, contentFrames, fadeWidth),
                Self.loopSample(channel0, index1, contentFrames, fadeWidth),
                Self.loopSample(channel0, index2, contentFrames, fadeWidth),
                Self.loopSample(channel0, index3, contentFrames, fadeWidth),
                fraction
            ) * outputGain
            left[i] = leftValue
            if leftValue != 0 { silent = false }
            if let right {
                let rightValue = Self.catmullRom(
                    Self.loopSample(channel1, index0, contentFrames, fadeWidth),
                    Self.loopSample(channel1, index1, contentFrames, fadeWidth),
                    Self.loopSample(channel1, index2, contentFrames, fadeWidth),
                    Self.loopSample(channel1, index3, contentFrames, fadeWidth),
                    fraction
                ) * outputGain
                right[i] = rightValue
                if rightValue != 0 { silent = false }
            }
        }
        return silent
    }

    // MARK: Pure helpers

    /// One loop-domain sample: real content declicked by the position-based
    /// edge fade inside `[0, contentFrames)`, exact silence elsewhere.
    /// Mirrors the grain path's `copyDVSLoopSegment` gain formula.
    @inline(__always)
    static func loopSample(
        _ channel: UnsafePointer<Float>,
        _ index: Int,
        _ contentFrames: Int,
        _ fadeWidth: Double
    ) -> Float {
        guard index >= 0, index < contentFrames else { return 0 }
        let position = Double(index)
        let edgeDistance = min(position, Double(contentFrames) - position)
        let fade = Float(min(edgeDistance, fadeWidth) / fadeWidth)
        return channel[index] * fade
    }

    /// Standard Catmull-Rom cubic — identical form to the grain path's
    /// interpolator, evaluated here per output frame over the loop domain.
    @inline(__always)
    static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    /// Maps a phase difference into `(-loop/2, +loop/2]` so correction
    /// always takes the short way around the loop.
    @inline(__always)
    static func wrappedSignedDelta(_ delta: Double, loop: Double) -> Double {
        guard loop > 0, delta.isFinite else { return 0 }
        var wrapped = delta.truncatingRemainder(dividingBy: loop)
        if wrapped > loop / 2 { wrapped -= loop }
        if wrapped < -loop / 2 { wrapped += loop }
        return wrapped
    }
}

// MARK: - Render mailbox (everything the render thread can reach)

/// Holds the atomic control/sample mailbox, the render-core allocation,
/// and every published allocation (PCM channels and sample tables). The
/// AVAudioSourceNode render closure captures exactly one strong reference
/// to this object, so all memory the render thread can reach lives at
/// least as long as the render closure itself — renderer/engine teardown
/// ordering can never dangle a pointer under the callback.
private final class DVSVinylRenderMailbox {

    // Atomic mailbox — the ONLY cross-thread state. Writers (the
    // controller's serial audio queue) store fields with relaxed ordering
    // and bump `controlEpoch` with releasing ordering; the render side
    // loads `controlEpoch` with acquiring ordering first. See the file
    // header for the ordering argument.
    let controlEpoch = Atomic<UInt64>(0)
    let velocityBits = Atomic<UInt64>(Double.zero.bitPattern)
    let phaseBits = Atomic<UInt64>(Double.zero.bitPattern)
    let activeWord = Atomic<UInt64>(0)
    let sampleTablePointer = Atomic<UnsafeMutableRawPointer?>(nil)
    /// Learned-mixer user gain (crossfader × right upfader), already
    /// combined and clamped by the control side. Independent of
    /// `controlEpoch` — read directly every render call rather than
    /// epoch-gated, since it has no correction/staleness semantics of its
    /// own to coordinate with velocity/phase/active. Starts at unity so
    /// audio is never muted before any mixer control is learned or moved.
    let userMixerGainBits = Atomic<UInt64>(Double(1.0).bitPattern)

    /// Render-owned core; after init, touched only by the render path
    /// (`DVSContinuousVinylRenderer.performRender`).
    let core: UnsafeMutablePointer<DVSContinuousVinylRenderCore>

    /// Published allocations, retained until this mailbox deinits (i.e.
    /// until the render closure itself is gone). Appended only from the
    /// controller's serial audio queue; never read by the render thread,
    /// which reaches sample memory exclusively through
    /// `sampleTablePointer`.
    var retainedPCMAllocations: [UnsafeMutablePointer<Float>] = []
    var retainedTableAllocations: [UnsafeMutablePointer<DVSVinylSampleTable>] = []

    init(outputSampleRate: Double) {
        core = .allocate(capacity: 1)
        core.initialize(to: DVSContinuousVinylRenderCore(outputSampleRate: outputSampleRate))
    }

    deinit {
        for allocation in retainedPCMAllocations {
            allocation.deallocate()
        }
        for allocation in retainedTableAllocations {
            allocation.deinitialize(count: 1)
            allocation.deallocate()
        }
        core.deinitialize(count: 1)
        core.deallocate()
    }
}

// MARK: - Production wrapper (AVAudioSourceNode + publication API)

/// Owns the AVAudioSourceNode and the publication API. Publish methods are
/// called from the playback controller's serial audio queue (single
/// writer); the render callback reads the mailbox with lock-free atomics
/// only — no locks, queues, semaphores, or retry loops anywhere on the
/// render path.
final class DVSContinuousVinylRenderer {

    /// Fixed render-domain rate: the DVS drive asset is 44.1 kHz and phase
    /// math is rate-independent (velocity is source frames per real
    /// second), so the engine's mixer performs any device-rate conversion.
    static let renderSampleRate: Double = 44_100

    private let mailbox: DVSVinylRenderMailbox

    /// Attached/connected once by the playback controller at init.
    let node: AVAudioSourceNode

    /// Monotonic identity for installed sample tables (control side only).
    private var nextSampleIdentity: UInt64 = 0

    /// Source rate of the most recently installed sample, for
    /// publication-side velocity sanitization (control side only).
    private var installedSourceSampleRate: Double = 44_100

#if DEBUG
    /// Test/diagnostic probes (control-side only; never read in the
    /// render callback).
    private(set) var publishCount = 0
    private(set) var idlePublishCount = 0
    private(set) var installedSampleCount = 0
    private(set) var lastPublishedVelocity: Double?
    private(set) var lastPublishedAuthoritativePhase: Double?
    private(set) var lastPublishedActive: Bool?
    private(set) var lastPublishedUserMixerGain: Double?
#endif

    init() {
        let mailbox = DVSVinylRenderMailbox(outputSampleRate: Self.renderSampleRate)
        self.mailbox = mailbox
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.renderSampleRate,
            channels: 2
        ) else {
            fatalError("DVSContinuousVinylRenderer: standard 44.1 kHz stereo format unavailable")
        }
        // Captures ONLY the mailbox reference (once, at creation): no self,
        // no per-callback ARC traffic, and the capture keeps every
        // render-reachable allocation alive for the closure's lifetime.
        node = AVAudioSourceNode(format: format) { [mailbox] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0,
                  let leftRaw = buffers[0].mData else { return noErr }
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right: UnsafeMutablePointer<Float>?
            if buffers.count > 1, let rightRaw = buffers[1].mData {
                right = rightRaw.assumingMemoryBound(to: Float.self)
            } else {
                right = nil
            }
            DVSContinuousVinylRenderer.performRender(
                mailbox: mailbox,
                left: left,
                right: right,
                frameCount: Int(frameCount)
            )
            return noErr
        }
    }

    /// The complete render path: a fixed number of lock-free atomic loads,
    /// then the deterministic core math. Static so the render closure
    /// captures no instance state beyond the mailbox reference.
    @discardableResult
    private static func performRender(
        mailbox: DVSVinylRenderMailbox,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) -> Bool {
        // Sample table: single acquiring pointer load pairing with the
        // releasing store in installSample — the table and its PCM are
        // fully initialized, immutable, and never freed while the closure
        // (and therefore this mailbox) lives.
        if let raw = mailbox.sampleTablePointer.load(ordering: .acquiring) {
            let table = raw.assumingMemoryBound(to: DVSVinylSampleTable.self)
            mailbox.core.pointee.ingest(table: table.pointee)
        }
        // Control snapshot: acquiring epoch load first, then relaxed field
        // loads — each field is individually atomic (no tearing) and the
        // acquire/release pairing on the epoch guarantees the fields are
        // at least as new as the observed epoch. One-shot, no retry.
        let epoch = mailbox.controlEpoch.load(ordering: .acquiring)
        let snapshot = DVSVinylControlSnapshot(
            epoch: epoch,
            velocity: Double(bitPattern: mailbox.velocityBits.load(ordering: .relaxed)),
            authoritativePhase: Double(bitPattern: mailbox.phaseBits.load(ordering: .relaxed)),
            active: mailbox.activeWord.load(ordering: .relaxed) != 0
        )
        mailbox.core.pointee.ingest(snapshot: snapshot)
        // Learned-mixer user gain: one relaxed atomic load, independent of
        // the epoch above (see the mailbox field's doc comment).
        mailbox.core.pointee.ingestUserMixerGain(
            Double(bitPattern: mailbox.userMixerGainBits.load(ordering: .relaxed))
        )
        return mailbox.core.pointee.render(left: left, right: right, frameCount: frameCount)
    }

    // MARK: - Control-side API (controller audio queue only)

    /// Copies the loaded sample into immutable renderer-owned storage and
    /// publishes it via a single atomic pointer store. Returns false
    /// (leaving the previous sample installed) when the buffer or loop
    /// geometry is unusable for the DVS loop.
    @discardableResult
    func installSample(
        from buffer: AVAudioPCMBuffer,
        loopFrames: Double,
        contentFadeFrames: Int
    ) -> Bool {
        let contentFrames = Int(buffer.frameLength)
        guard contentFrames > 1,
              loopFrames.isFinite,
              Double(contentFrames) <= loopFrames,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let sourceChannels = buffer.floatChannelData else {
            return false
        }
        let channelCount = Int(buffer.format.channelCount)

        let storage0 = UnsafeMutablePointer<Float>.allocate(capacity: contentFrames)
        storage0.update(from: sourceChannels[0], count: contentFrames)
        mailbox.retainedPCMAllocations.append(storage0)

        var storage1: UnsafeMutablePointer<Float>?
        if channelCount > 1 {
            let allocation = UnsafeMutablePointer<Float>.allocate(capacity: contentFrames)
            allocation.update(from: sourceChannels[1], count: contentFrames)
            mailbox.retainedPCMAllocations.append(allocation)
            storage1 = allocation
        }

        nextSampleIdentity &+= 1
        installedSourceSampleRate = buffer.format.sampleRate
        let table = UnsafeMutablePointer<DVSVinylSampleTable>.allocate(capacity: 1)
        table.initialize(to: DVSVinylSampleTable(
            identity: nextSampleIdentity,
            channel0: UnsafePointer(storage0),
            channel1: storage1.map { UnsafePointer($0) },
            contentFrames: contentFrames,
            loopFrames: loopFrames,
            contentFadeFrames: Double(max(1, contentFadeFrames)),
            sourceSampleRate: buffer.format.sampleRate
        ))
        mailbox.retainedTableAllocations.append(table)
        // Releasing store publishes the fully initialized table.
        mailbox.sampleTablePointer.store(
            UnsafeMutableRawPointer(table),
            ordering: .releasing
        )
#if DEBUG
        installedSampleCount += 1
#endif
        return true
    }

    /// Publishes the latest signed velocity (source frames/second) and
    /// authoritative loop phase from the control tick. Values are
    /// sanitized here (and defensively again at ingest) so the render
    /// callback never sees non-finite input.
    func publish(velocity: Double, authoritativePhase: Double, active: Bool) {
        let safeVelocity = DVSContinuousVinylRenderCore.sanitizedVelocity(
            velocity,
            sourceSampleRate: installedSourceSampleRate
        )
        mailbox.velocityBits.store(safeVelocity.bitPattern, ordering: .relaxed)
        if authoritativePhase.isFinite {
            mailbox.phaseBits.store(authoritativePhase.bitPattern, ordering: .relaxed)
        }
        mailbox.activeWord.store(active ? 1 : 0, ordering: .relaxed)
        mailbox.controlEpoch.wrappingAdd(1, ordering: .releasing)
#if DEBUG
        publishCount += 1
        lastPublishedVelocity = safeVelocity
        lastPublishedAuthoritativePhase = authoritativePhase
        lastPublishedActive = active
#endif
    }

    /// Publishes the idle/settle state (velocity target zero, inactive).
    /// The published authoritative phase — and the renderer's retained
    /// phase — are untouched: stopping never resets phase.
    func publishIdle() {
        mailbox.velocityBits.store(Double.zero.bitPattern, ordering: .relaxed)
        mailbox.activeWord.store(0, ordering: .relaxed)
        mailbox.controlEpoch.wrappingAdd(1, ordering: .releasing)
#if DEBUG
        idlePublishCount += 1
        lastPublishedVelocity = 0
        lastPublishedActive = false
#endif
    }

    /// Publishes the combined learned-mixer user gain (crossfader ×
    /// right-upfader, already multiplied by the caller). Sanitized here
    /// (and defensively again at ingest) so the render callback never sees
    /// non-finite input; malformed input fails to silence, not full
    /// volume. No epoch bump — see the mailbox field's doc comment for why
    /// this is independent of the velocity/phase/active snapshot.
    func publishUserMixerGain(_ gain: Double) {
        let safeGain = gain.isFinite ? min(max(gain, 0), 1) : 0
        mailbox.userMixerGainBits.store(safeGain.bitPattern, ordering: .relaxed)
#if DEBUG
        lastPublishedUserMixerGain = safeGain
#endif
    }

#if DEBUG
    // MARK: - Test hooks (never used by production/hardware code paths)

    /// Drives the exact production render path (atomic mailbox reads +
    /// core math) without an AVAudioEngine. Used by deterministic
    /// integration tests and the bounded concurrent publish/render stress
    /// test. NOTE: exercising this concurrently with `publish` checks for
    /// crashes/non-finite output under real concurrency, but no unit test
    /// or sanitizer run is claimed to PROVE real-time safety.
    @discardableResult
    func testOnly_render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) -> Bool {
        Self.performRender(
            mailbox: mailbox,
            left: left,
            right: right,
            frameCount: frameCount
        )
    }

    /// Test-only reads of render-core state. Only meaningful while no
    /// engine is running (tests never start one on this renderer).
    var testOnly_corePhase: Double { mailbox.core.pointee.phase }
    var testOnly_coreVelocity: Double { mailbox.core.pointee.velocity }
    var testOnly_coreGain: Double { mailbox.core.pointee.gain }
    var testOnly_coreUserMixerGain: Double { mailbox.core.pointee.userMixerGain }
    var testOnly_coreTargetUserMixerGain: Double { mailbox.core.pointee.targetUserMixerGain }
#endif
}
