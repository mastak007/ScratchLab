// IOScratchRenderer.swift
// ScratchLab — iOS Continuous Scratch Renderer
//
// Stereo scratch renderer that owns the loaded PCM sample and renders it
// through an AVAudioSourceNode render callback. PlatterPosition is the sole
// playback authority: the main thread converts a PlatterPosition into a frame
// index (via update(position:)); the render thread only ever reads and holds
// that frame — it never runs its own clock.
//
// Thread model: the render callback runs on the audio render thread and must
// never touch MainActor/SwiftUI state. It reads a lock-protected snapshot of the
// playhead; the main thread writes that snapshot.

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

    // Protected by `lock`; read by the render thread, written by the main thread.
    private var sampleBuffer: AVAudioPCMBuffer?
    private var totalFrames = 0
    private var framePosition: Double = 0

    /// The audio source node. The owning engine attaches it to an AVAudioEngine.
    lazy var sourceNode: AVAudioSourceNode = {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(isSilence: isSilence, frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }()

    /// Install a loaded PCM sample and hold the playhead at the top, silent
    /// until a PlatterPosition update moves it.
    func load(buffer: AVAudioPCMBuffer) {
        lock.lock()
        sampleBuffer = buffer
        totalFrames = Int(buffer.frameLength)
        framePosition = 0
        lock.unlock()
    }

    /// Update the playhead from a PlatterPosition. PlatterPosition is the only
    /// playback authority — the render thread never advances this on its own;
    /// it only ever holds whatever frame was last written here.
    func update(position: PlatterPosition) {
        lock.lock()
        framePosition = position.normalizedPosition * Double(totalFrames)
        lock.unlock()
    }

    /// Reset the playhead to the top.
    func reset() {
        lock.lock()
        framePosition = 0
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
        let pos = framePosition
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

        // PlatterPosition sets one frame per update; hold it for the entire
        // buffer — the render thread does not advance its own clock.
        let clamped = min(max(pos, 0), Double(lastFrame))
        let i0 = Int(clamped)
        let frac = Float(clamped - Double(i0))
        let i1 = min(i0 + 1, lastFrame)
        let sampleL = srcL[i0] + frac * (srcL[i1] - srcL[i0])
        let sampleR = srcR[i0] + frac * (srcR[i1] - srcR[i0])

        for frame in 0..<Int(frameCount) {
            dstL[frame] = sampleL
            dstR?[frame] = sampleR
        }

        return noErr
    }
}
