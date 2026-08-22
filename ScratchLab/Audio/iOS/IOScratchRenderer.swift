// IOScratchRenderer.swift
// ScratchLab — iOS Continuous Scratch Renderer
//
// Stereo scratch renderer that owns the loaded PCM sample and renders it
// through an AVAudioSourceNode render callback. PlatterPosition remains the
// sole playback authority: the main thread converts a PlatterPosition into a
// target frame index (via update(position:)). The render thread never sets
// that target itself — it only smoothly follows it, sample by sample, so
// audio doesn't step at the ~60Hz rate PlatterPosition updates arrive at.
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
}

final class IOScratchRenderer {

    // MARK: - Cross-thread state (lock-free)

    private let sampleTablePointer = Atomic<UnsafeMutableRawPointer?>(nil)
    private let targetFrameBits = Atomic<UInt64>(0)
    private let isActiveWord = Atomic<UInt64>(0)
    private let nextIdentity = Atomic<UInt64>(0)

    /// PCM + table allocations, retained for the renderer's lifetime so the
    /// render thread never reads through a freed pointer. Touched only from
    /// the main thread (`load(buffer:)`), freed in `deinit`.
    private var retainedPCMAllocations: [UnsafeMutablePointer<Float>] = []
    private var retainedTableAllocations: [UnsafeMutablePointer<ScratchSampleTable>] = []

    // MARK: - Render-thread-owned state
    //
    // Touched only inside `render(...)` — Core Audio never calls a node's
    // render block reentrantly, so these need no synchronization at all.

    private var currentFramePosition: Double = 0
    private var lastSeenIdentity: UInt64 = 0
    /// Click-free fade-in gain, reset to 0 whenever a fresh load is noticed
    /// (see `nextIdentity`/`lastSeenIdentity`) and ramped back to unity —
    /// covers the "activation" and "sample-boundary reset" click sources
    /// without a crossfade/DSP engine. Direction reversals need no separate
    /// handling: the position follower below is already continuous, so a
    /// reversed target is chased smoothly, not jumped to.
    private var renderGain: Double = 1

    private static let renderSampleRate: Double = 44_100
    /// How quickly the render thread's playhead closes the gap to the
    /// target — short enough to erase the ~60Hz PlatterPosition step (a new
    /// target roughly every 16.7ms) and stay tight to the finger, long enough
    /// to smooth the jump between targets into a continuous sweep instead of
    /// a step. Not a clock: with a fixed target this asymptotically settles
    /// and holds, it never keeps moving on its own.
    private static let followTimeConstant: Double = 0.008
    private static let followAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * followTimeConstant))
    private static let gainTimeConstant: Double = 0.005
    private static let gainAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * gainTimeConstant))

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
        let table = UnsafeMutablePointer<ScratchSampleTable>.allocate(capacity: 1)
        table.initialize(to: ScratchSampleTable(
            identity: identity,
            channelL: UnsafePointer(storageL),
            channelR: channelR,
            totalFrames: totalFrames
        ))
        retainedTableAllocations.append(table)

        targetFrameBits.store(Double(0).bitPattern, ordering: .relaxed)
        // Releasing store publishes the fully initialized table.
        sampleTablePointer.store(UnsafeMutableRawPointer(table), ordering: .releasing)
    }

    /// Update the playback target from a PlatterPosition. PlatterPosition is
    /// the only playback authority — this only ever moves where the render
    /// thread is *heading*; the render thread itself decides how smoothly it
    /// gets there.
    func update(position: PlatterPosition) {
        guard let raw = sampleTablePointer.load(ordering: .acquiring) else { return }
        let totalFrames = raw.assumingMemoryBound(to: ScratchSampleTable.self).pointee.totalFrames
        let target = position.normalizedPosition * Double(totalFrames)
        targetFrameBits.store(target.bitPattern, ordering: .relaxed)
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
        isActiveWord.store(0, ordering: .relaxed)
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
            renderGain = 0
        }

        let target = Double(bitPattern: targetFrameBits.load(ordering: .relaxed))
        var current = currentFramePosition
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
        let lastFrame = table.totalFrames - 1

        for frame in 0..<Int(frameCount) {
            // Follow the target, not run a clock: with a fixed target this
            // term shrinks to ~0 and `current` holds, it does not keep
            // advancing under its own power.
            current += (target - current) * Self.followAlpha
            gain += (1 - gain) * Self.gainAlpha

            let clamped = min(max(current, 0), Double(lastFrame))
            let i0 = Int(clamped)
            let frac = Float(clamped - Double(i0))
            let i1 = min(i0 + 1, lastFrame)
            let sampleGain = Float(gain)
            dstL[frame] = (srcL[i0] + frac * (srcL[i1] - srcL[i0])) * sampleGain
            dstR?[frame] = (srcR[i0] + frac * (srcR[i1] - srcR[i0])) * sampleGain
        }

        // Persist the clamped position, not the raw follower value, so a
        // stale target can't leave a runaway value to carry into the next
        // callback.
        currentFramePosition = min(max(current, 0), Double(lastFrame))
        renderGain = gain

        return noErr
    }
}
