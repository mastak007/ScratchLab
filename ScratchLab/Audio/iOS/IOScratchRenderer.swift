// IOScratchRenderer.swift
// ScratchLab — iOS Continuous Scratch Renderer
//
// Continuous scratch renderer that owns the loaded PCM sample and renders it
// through an AVAudioSourceNode render callback. The main thread feeds in a
// PlatterPosition (via update(position:)); the render thread reads the playhead
// frame and streams the sample forward, backward, or held (silence when idle).
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
    private var sampleRate: Double = 44_100
    private var framePosition: Double = 0
    private var direction: PlatterDirection = .idle
    private var velocity: Double = 0

    /// The audio source node. The owning engine attaches it to an AVAudioEngine.
    lazy var sourceNode: AVAudioSourceNode = {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        return AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(isSilence: isSilence, frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }()

    /// Install a loaded PCM sample and reset the playhead.
    func load(buffer: AVAudioPCMBuffer) {
        lock.lock()
        sampleBuffer = buffer
        totalFrames = Int(buffer.frameLength)
        sampleRate = buffer.format.sampleRate
        framePosition = 0
        direction = .idle
        velocity = 0
        lock.unlock()
    }

    /// Update the playhead from a PlatterPosition. The angular velocity
    /// (radians/sec) is converted to a signed frame rate (frames per output
    /// frame) assuming the sample maps one full platter revolution — a rough
    /// approximation, not the audible-span derivative.
    func update(position: PlatterPosition) {
        lock.lock()
        framePosition = position.normalizedPosition * Double(totalFrames)
        direction = position.direction
        let framesPerRadian = Double(totalFrames) / (2.0 * .pi)
        velocity = position.velocity * framesPerRadian / sampleRate
        lock.unlock()
    }

    /// Reset the playhead to the top and go silent.
    func reset() {
        lock.lock()
        framePosition = 0
        direction = .idle
        velocity = 0
        lock.unlock()
    }

    /// Start playing forward from the top at native rate (one frame per output
    /// frame). Used by `playHotCue` before platter movement takes over.
    func startForward() {
        lock.lock()
        framePosition = 0
        direction = .forward
        velocity = 1.0
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
        var pos = framePosition
        let dir = direction
        let vel = velocity
        lock.unlock()

        guard let buffer, totalFrames > 0, dir != .idle,
              let src = buffer.floatChannelData else {
            isSilence.pointee = true
            return noErr
        }

        isSilence.pointee = false
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let dst = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
            isSilence.pointee = true
            return noErr
        }
        let channel = src[0]  // mono render: read the sample's first channel
        let lastFrame = totalFrames - 1

        for frame in 0..<Int(frameCount) {
            let clamped = min(max(pos, 0), Double(lastFrame))
            let i0 = Int(clamped)
            let frac = Float(clamped - Double(i0))
            let i1 = min(i0 + 1, lastFrame)
            dst[frame] = channel[i0] + frac * (channel[i1] - channel[i0])
            pos += vel
        }

        lock.lock()
        framePosition = pos
        lock.unlock()

        return noErr
    }
}
