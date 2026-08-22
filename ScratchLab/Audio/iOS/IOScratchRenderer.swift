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
// never touch MainActor/SwiftUI state. It reads a lock-protected snapshot of
// the target and the last-rendered position; the main thread writes the
// target (and can force-reset the rendered position on load/reset).

import AVFoundation
import Foundation

/// A snapshot of the scratch playback state, copied for the render thread.
struct ScratchPlaybackState: Sendable {
    var framePosition: Double = 0
    var direction: PlatterDirection = .idle
    var velocity: Double = 0
}

final class IOScratchRenderer {

    private let lock = NSLock()

    // Protected by `lock`.
    private var sampleBuffer: AVAudioPCMBuffer?
    private var totalFrames = 0
    /// Set only by `update(position:)` from PlatterPosition — the playback
    /// authority. The render thread never writes this.
    private var targetFramePosition: Double = 0
    /// The actual playhead the render thread reads from. Written by the
    /// render thread each callback as it follows `targetFramePosition`, and
    /// force-reset (by the main thread) on `load`/`reset`.
    private var currentFramePosition: Double = 0

    private static let renderSampleRate: Double = 44_100
    /// How quickly the render thread's playhead closes the gap to the
    /// target — short enough to erase the ~60Hz PlatterPosition step (a new
    /// target roughly every 16.7ms) and stay tight to the finger, long enough
    /// to smooth the jump between targets into a continuous sweep instead of
    /// a step. Not a clock: with a fixed target this asymptotically settles
    /// and holds, it never keeps moving on its own.
    private static let followTimeConstant: Double = 0.008
    private static let followAlpha: Double = 1 - exp(-1.0 / (renderSampleRate * followTimeConstant))

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

    /// Install a loaded PCM sample and hold the playhead at the top, silent
    /// until a PlatterPosition update moves the target.
    func load(buffer: AVAudioPCMBuffer) {
        lock.lock()
        sampleBuffer = buffer
        totalFrames = Int(buffer.frameLength)
        targetFramePosition = 0
        currentFramePosition = 0
        lock.unlock()
    }

    /// Update the playback target from a PlatterPosition. PlatterPosition is
    /// the only playback authority — this only ever moves where the render
    /// thread is *heading*; the render thread itself decides how smoothly it
    /// gets there.
    func update(position: PlatterPosition) {
        lock.lock()
        targetFramePosition = position.normalizedPosition * Double(totalFrames)
        lock.unlock()
    }

    /// Reset the playhead and its target to the top.
    func reset() {
        lock.lock()
        targetFramePosition = 0
        currentFramePosition = 0
        lock.unlock()
    }

    // MARK: - Render callback

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        lock.lock()
        let buffer = sampleBuffer
        let totalFrames = self.totalFrames
        let target = targetFramePosition
        var current = currentFramePosition
        lock.unlock()

        guard let buffer, totalFrames > 0,
              let src = buffer.floatChannelData else {
            isSilence.pointee = true
            return noErr
        }

        isSilence.pointee = false
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let dstL = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
            isSilence.pointee = true
            return noErr
        }
        let dstR = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let channelCount = Int(buffer.format.channelCount)
        let srcL = src[0]
        let srcR = channelCount > 1 ? src[1] : src[0]  // preserve stereo; no downmix
        let lastFrame = totalFrames - 1

        for frame in 0..<Int(frameCount) {
            // Follow the target, not run a clock: with a fixed target this
            // term shrinks to ~0 and `current` holds, it does not keep
            // advancing under its own power.
            current += (target - current) * Self.followAlpha

            let clamped = min(max(current, 0), Double(lastFrame))
            let i0 = Int(clamped)
            let frac = Float(clamped - Double(i0))
            let i1 = min(i0 + 1, lastFrame)
            dstL[frame] = srcL[i0] + frac * (srcL[i1] - srcL[i0])
            dstR?[frame] = srcR[i0] + frac * (srcR[i1] - srcR[i0])
        }

        // Persist the clamped position, not the raw follower value, so a
        // stale target (e.g. buffer swapped mid-callback) can't leave a
        // runaway value to carry into the next callback.
        lock.lock()
        currentFramePosition = min(max(current, 0), Double(lastFrame))
        lock.unlock()

        return noErr
    }
}
