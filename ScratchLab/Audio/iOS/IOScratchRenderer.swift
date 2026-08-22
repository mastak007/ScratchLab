// IOScratchRenderer.swift
// ScratchLab — iOS Continuous Scratch Renderer
//
// Stereo scratch renderer that owns the loaded PCM sample and renders it
// through an AVAudioSourceNode render callback. PlatterPosition remains the
// sole playback authority: the main thread publishes its signed velocity and
// authoritative phase. The render thread advances continuously at that
// velocity and applies only bounded phase correction, matching the proven
// macOS DVS playback model without sharing any platform audio code.
//
// Thread model: the render callback runs on the audio render thread and must
// never touch MainActor/SwiftUI state, allocate, or block. Cross-thread
// publication (main thread → render) uses `Synchronization.Atomic`
// exclusively — no lock, matching the pattern already established by
// `DVSContinuousVinylRenderer` (macOS) for the same problem:
// - The sample is published as a single atomic pointer (release store /
//   acquire load) to a fully initialized, immutable, heap-allocated table
//   whose PCM is a private copy retained for the renderer's lifetime — a
//   stale pointer read is always into live, immutable memory.
// - `targetFramePosition` and `isActive` are each one independent
//   `Atomic<UInt64>` (a Double stored as its bit pattern). No epoch: these
//   two fields have no cross-field consistency requirement of their own —
//   the render-side follower already smooths over the rare case where one
//   is read a callback apart from the other.
// - `currentFramePosition` (the render thread's own smoothed playhead) is
//   never shared: it lives purely on the audio thread. A fresh `load(buffer:)`
//   is detected by the render thread noticing the published table's
//   `identity` changed, at which point it snaps the playhead to 0 itself
//   rather than requiring a separate cross-thread reset signal.

import AVFoundation
import Foundation
import Synchronization

/// A snapshot of the scratch playback state — retained for API compatibility
/// with earlier phases; not read internally by the renderer.
struct ScratchPlaybackState: Sendable {
    var framePosition: Double = 0
    var direction: PlatterDirection = .idle
    var velocity: Double = 0
}

/// One immutable, fully initialized description of the installed hot-cue
/// sample. Allocated once per `load(buffer:)`, published by a single atomic
/// pointer store, and never mutated afterwards.
private struct ScratchSampleTable {
    /// Monotonic install identity — lets the render thread detect a fresh
    /// load (including the same sample re-triggered) and snap the playhead
    /// to 0 itself, without a separate cross-thread reset signal.
    let identity: UInt64
    let channelL: UnsafePointer<Float>
    let channelR: UnsafePointer<Float>  // == channelL for a mono source
    let totalFrames: Int
    /// Audible hot-cue origin and the one-revolution playback window measured
    /// from that origin. Long padded WAVs therefore play at vinyl speed rather
    /// than being compressed wholesale into one revolution.
    let cueStartFrame: Int
    let loopFrameCount: Int
    let framesPerPlatterStep: Double
}

final class IOScratchRenderer {

    // MARK: - Cross-thread state (lock-free)

    private let sampleTablePointer = Atomic<UnsafeMutableRawPointer?>(nil)
    private let targetFrameBits = Atomic<UInt64>(0)
    private let velocityFramesPerSecondBits = Atomic<UInt64>(0)
    private let snapPhaseWord = Atomic<UInt64>(0)
    private let controlEpoch = Atomic<UInt64>(0)
    private let isActiveWord = Atomic<UInt64>(0)
    private let nextIdentity = Atomic<UInt64>(0)

    /// PCM + table allocations, retained for the renderer's lifetime so the
    /// render thread never reads through a freed pointer. Touched only from
    /// the main thread (`load(buffer:)`), freed in `deinit`.
    private var retainedPCMAllocations: [UnsafeMutablePointer<Float>] = []
    private var retainedTableAllocations: [UnsafeMutablePointer<ScratchSampleTable>] = []
    private var lastPublishedRevolution: Double?

    // MARK: - Render-thread-owned state
    //
    // Touched only inside `render(...)` — Core Audio never calls a node's
    // render block reentrantly, so these need no synchronization at all.

    private var currentFramePosition: Double = 0
    private var currentVelocity: Double = 0
    private var pendingPhaseCorrection: Double = 0
    private var lastSeenControlEpoch: UInt64 = 0
    private var framesSinceControlUpdate = Int.max / 2
    private var lastSeenIdentity: UInt64 = 0
    /// Click-free fade-in gain, reset to 0 whenever a fresh load is noticed
    /// (see `nextIdentity`/`lastSeenIdentity`) and ramped back to unity —
    /// covers the "activation" and "sample-boundary reset" click sources
    /// without a crossfade/DSP engine. Direction reversals need no separate
    /// handling: the position follower below is already continuous, so a
    /// reversed target is chased smoothly, not jumped to.
    private var renderGain: Double = 1

    private static let renderSampleRate: Double = 44_100
    private static let velocityTimeConstant: Double = 0.004
    private static let velocityAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * velocityTimeConstant))
    private static let phaseCorrectionTimeConstant: Double = 0.150
    private static let phaseCorrectionAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * phaseCorrectionTimeConstant))
    private static let maximumPhaseCorrectionRatio: Double = 0.02
    private static let staleControlFrames = Int(renderSampleRate * 0.25)
    private static let gainTimeConstant: Double = 0.003
    private static let gainAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * gainTimeConstant))
    /// Measured direct-MIDI CC6 resolution, shared with the macOS path.
    private static let raneStepsPerRevolution: Double = 3600
    private static let nominalVinylRPM: Double = 33 + 1.0 / 3.0
    private static let loopEdgeFadeFrames: Double = 64

    /// The audio source node. The owning engine attaches it to an AVAudioEngine.
    lazy var sourceNode: AVAudioSourceNode = {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.renderSampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(isSilence: isSilence, frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }()

    deinit {
        for allocation in retainedPCMAllocations {
            allocation.deallocate()
        }
        for allocation in retainedTableAllocations {
            allocation.deinitialize(count: 1)
            allocation.deallocate()
        }
    }

    /// Install a loaded PCM sample. Copies the sample's own channel data into
    /// privately owned storage (never freed while this renderer is alive), so
    /// the render thread's pointer reads never depend on `AVAudioPCMBuffer`'s
    /// own lifetime/thread-safety. Preserves stereo — both channels are
    /// copied, no downmix.
    func load(buffer: AVAudioPCMBuffer) {
        guard let source = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let totalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        let storageL = UnsafeMutablePointer<Float>.allocate(capacity: totalFrames)
        storageL.update(from: source[0], count: totalFrames)
        retainedPCMAllocations.append(storageL)

        let channelR: UnsafePointer<Float>
        if channelCount > 1 {
            let storageR = UnsafeMutablePointer<Float>.allocate(capacity: totalFrames)
            storageR.update(from: source[1], count: totalFrames)
            retainedPCMAllocations.append(storageR)
            channelR = UnsafePointer(storageR)
        } else {
            channelR = UnsafePointer(storageL)
        }

        let identity = nextIdentity.wrappingAdd(1, ordering: .relaxed).newValue
        let cueStartFrame = Self.detectAudibleOnset(in: buffer)
        let vinylSecondsPerRevolution = 60 / Self.nominalVinylRPM
        let framesPerPlatterStep = buffer.format.sampleRate
            * vinylSecondsPerRevolution
            / Self.raneStepsPerRevolution
        let revolutionFrames = max(1, Int((framesPerPlatterStep * Self.raneStepsPerRevolution).rounded()))
        // A platter loop is always one physical revolution. Short DVS assets
        // occupy the beginning of that loop and the remainder renders as
        // silence, so the vocal occurs once per revolution instead of being
        // repeated at the WAV's own shorter duration.
        let loopFrameCount = revolutionFrames
        let table = UnsafeMutablePointer<ScratchSampleTable>.allocate(capacity: 1)
        table.initialize(to: ScratchSampleTable(
            identity: identity,
            channelL: UnsafePointer(storageL),
            channelR: channelR,
            totalFrames: totalFrames,
            cueStartFrame: cueStartFrame,
            loopFrameCount: loopFrameCount,
            framesPerPlatterStep: framesPerPlatterStep
        ))
        retainedTableAllocations.append(table)

        targetFrameBits.store(Double.zero.bitPattern, ordering: .relaxed)
        velocityFramesPerSecondBits.store(Double.zero.bitPattern, ordering: .relaxed)
        // Releasing store publishes the fully initialized table.
        sampleTablePointer.store(UnsafeMutableRawPointer(table), ordering: .releasing)
    }

    /// Update the playback target from platter travel measured relative to the
    /// most recent hotcue press. The per-step frame rate is fixed by 33⅓ RPM,
    /// not by WAV length, preserving the vocal's natural pitch and duration.
    func update(relativePlatterSteps: Double, signedVelocityStepsPerSecond: Double) {
        guard let raw = sampleTablePointer.load(ordering: .acquiring) else { return }
        let table = raw.assumingMemoryBound(to: ScratchSampleTable.self).pointee
        let loopLength = Double(table.loopFrameCount)
        var localTarget = (relativePlatterSteps * table.framesPerPlatterStep)
            .truncatingRemainder(dividingBy: loopLength)
        if localTarget < 0 { localTarget += loopLength }
        let rawVelocity = signedVelocityStepsPerSecond.isFinite
            ? signedVelocityStepsPerSecond * table.framesPerPlatterStep
            : 0
        let velocityLimit = Self.renderSampleRate * 8
        let velocity = min(max(rawVelocity, -velocityLimit), velocityLimit)
        let revolution = (relativePlatterSteps / Self.raneStepsPerRevolution).rounded(.down)
        let crossedRevolutionBoundary = lastPublishedRevolution.map { $0 != revolution } ?? false
        lastPublishedRevolution = revolution
        targetFrameBits.store(localTarget.bitPattern, ordering: .relaxed)
        velocityFramesPerSecondBits.store(velocity.bitPattern, ordering: .relaxed)
        snapPhaseWord.store(crossedRevolutionBoundary ? 1 : 0, ordering: .relaxed)
        controlEpoch.wrappingAdd(1, ordering: .releasing)
    }

    /// Arm the render callback to start outputting audio. Called after
    /// `load(buffer:)` by a hotcue trigger.
    func activate() {
        isActiveWord.store(1, ordering: .relaxed)
    }

    /// Deactivate output and re-target the top. The render thread's own
    /// playhead snaps to 0 the next time it notices a fresh `load(buffer:)`
    /// (every hotcue re-trigger bumps the install identity), so no separate
    /// cross-thread position reset is needed here.
    func reset() {
        targetFrameBits.store(Double(0).bitPattern, ordering: .relaxed)
        velocityFramesPerSecondBits.store(Double.zero.bitPattern, ordering: .relaxed)
        snapPhaseWord.store(0, ordering: .relaxed)
        lastPublishedRevolution = nil
        isActiveWord.store(0, ordering: .relaxed)
        controlEpoch.wrappingAdd(1, ordering: .releasing)
    }

    // MARK: - Render callback

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard isActiveWord.load(ordering: .relaxed) != 0,
              let raw = sampleTablePointer.load(ordering: .acquiring) else {
            isSilence.pointee = true
            return noErr
        }
        let table = raw.assumingMemoryBound(to: ScratchSampleTable.self).pointee
        guard table.totalFrames > 0 else {
            isSilence.pointee = true
            return noErr
        }

        // A fresh load (even of the "same" sample) always carries a new
        // identity: snap the playhead to 0 and restart the click-free fade
        // instead of gliding in from wherever the previous sample left off.
        if table.identity != lastSeenIdentity {
            lastSeenIdentity = table.identity
            currentFramePosition = 0
            currentVelocity = 0
            pendingPhaseCorrection = 0
            framesSinceControlUpdate = Int.max / 2
            renderGain = 0
        }

        let rawTarget = Double(bitPattern: targetFrameBits.load(ordering: .relaxed))
        let rawVelocity = Double(bitPattern: velocityFramesPerSecondBits.load(ordering: .relaxed))
        let epoch = controlEpoch.load(ordering: .acquiring)
        var current = currentFramePosition
        var velocity = currentVelocity
        var gain = renderGain

        isSilence.pointee = false
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let dstL = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
            isSilence.pointee = true
            return noErr
        }
        let dstR = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let srcL = table.channelL
        let srcR = table.channelR
        let loopLength = Double(table.loopFrameCount)
        var localTarget = rawTarget.truncatingRemainder(dividingBy: loopLength)
        if localTarget < 0 { localTarget += loopLength }
        let contentFrames = max(0, table.totalFrames - table.cueStartFrame)

        if epoch != lastSeenControlEpoch {
            lastSeenControlEpoch = epoch
            framesSinceControlUpdate = 0
            if snapPhaseWord.load(ordering: .relaxed) != 0 {
                current = localTarget
                pendingPhaseCorrection = 0
            } else {
                pendingPhaseCorrection = Self.wrappedSignedDelta(
                    localTarget - current,
                    loop: loopLength
                )
            }
        }

        var renderedAudibleSample = false

        let rendererIsActive = isActiveWord.load(ordering: .relaxed) != 0
        for frame in 0..<Int(frameCount) {
            if framesSinceControlUpdate < Int.max / 2 {
                framesSinceControlUpdate += 1
            }
            let controlIsFresh = framesSinceControlUpdate <= Self.staleControlFrames
            let engaged = rendererIsActive && controlIsFresh
            let targetVelocity = engaged && rawVelocity.isFinite ? rawVelocity : 0
            velocity += (targetVelocity - velocity) * Self.velocityAlpha

            if pendingPhaseCorrection != 0 {
                let correctionLimit = abs(velocity)
                    * Self.maximumPhaseCorrectionRatio
                    / Self.renderSampleRate
                var correction = pendingPhaseCorrection * Self.phaseCorrectionAlpha
                correction = min(max(correction, -correctionLimit), correctionLimit)
                current += correction
                pendingPhaseCorrection -= correction
            }

            current += velocity / Self.renderSampleRate
            if current >= loopLength || current < 0 {
                current = current.truncatingRemainder(dividingBy: loopLength)
                if current < 0 { current += loopLength }
            }
            gain += ((engaged ? 1.0 : 0.0) - gain) * Self.gainAlpha

            let base = current.rounded(.down)
            let fraction = Float(current - base)
            let index1 = Int(base)
            let index0 = index1 - 1 < 0 ? table.loopFrameCount - 1 : index1 - 1
            let index2 = index1 + 1 >= table.loopFrameCount ? 0 : index1 + 1
            let index3 = index2 + 1 >= table.loopFrameCount ? 0 : index2 + 1
            let sampleGain = Float(gain)
            let left = Self.catmullRom(
                Self.loopSample(srcL, index: index0, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcL, index: index1, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcL, index: index2, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcL, index: index3, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                fraction
            ) * sampleGain
            let right = Self.catmullRom(
                Self.loopSample(srcR, index: index0, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcR, index: index1, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcR, index: index2, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                Self.loopSample(srcR, index: index3, contentFrames: contentFrames, cueStart: table.cueStartFrame),
                fraction
            ) * sampleGain
            dstL[frame] = left
            dstR?[frame] = right
            if left != 0 || right != 0 { renderedAudibleSample = true }
        }

        currentFramePosition = current
        currentVelocity = velocity
        renderGain = gain
        isSilence.pointee = ObjCBool(!renderedAudibleSample)

        return noErr
    }

    @inline(__always)
    private static func loopSample(
        _ channel: UnsafePointer<Float>,
        index: Int,
        contentFrames: Int,
        cueStart: Int
    ) -> Float {
        guard index >= 0, index < contentFrames else { return 0 }
        let edgeDistance = min(index, contentFrames - index)
        let fade = Float(min(Double(edgeDistance), loopEdgeFadeFrames) / loopEdgeFadeFrames)
        return channel[cueStart + index] * fade
    }

    @inline(__always)
    private static func catmullRom(
        _ p0: Float,
        _ p1: Float,
        _ p2: Float,
        _ p3: Float,
        _ t: Float
    ) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1)
            + (-p0 + p2) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    @inline(__always)
    private static func wrappedSignedDelta(_ delta: Double, loop: Double) -> Double {
        guard loop > 0, delta.isFinite else { return 0 }
        var wrapped = delta.truncatingRemainder(dividingBy: loop)
        if wrapped > loop / 2 { wrapped -= loop }
        if wrapped < -loop / 2 { wrapped += loop }
        return wrapped
    }

    /// First 5 ms RMS block containing sustained audible content. This is the
    /// minimal iOS equivalent of macOS hot-cue onset alignment; it prevents a
    /// padded WAV's leading silence from moving the cue away from HC1.
    private static func detectAudibleOnset(
        in buffer: AVAudioPCMBuffer,
        thresholdRatio: Float = 0.01,
        windowSeconds: Double = 0.005
    ) -> Int {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let channels = buffer.floatChannelData,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let windowFrames = max(1, Int(windowSeconds * buffer.format.sampleRate))

        var start = 0
        while start < frameCount {
            let end = min(start + windowFrames, frameCount)
            var sumSquares: Double = 0
            var sampleCount = 0
            for channelIndex in 0..<channelCount {
                let channel = channels[channelIndex]
                for frameIndex in start..<end {
                    let value = Double(channel[frameIndex])
                    sumSquares += value * value
                    sampleCount += 1
                }
            }
            guard sampleCount > 0 else { return start }
            let rms = Float((sumSquares / Double(sampleCount)).squareRoot())
            if rms >= thresholdRatio { return start }
            start = end
        }
        return 0
    }
}
