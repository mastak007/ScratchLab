#if ENABLE_TIMECODE_LIVE_TAP

import AVFoundation
import CoreMedia
import Accelerate

// MARK: - TimecodeCMSampleBufferAdapter

/// Converts a `CMSampleBuffer` from an `AVCaptureAudioDataOutput` into
/// separate left/right Float32 arrays suitable for
/// `TimecodeControlPipeline.pushStereoBuffer(_)`.
///
/// Unlike the production `MacCaptureEngine.audioPacket(from:)` which
/// downmixes to mono for scratch detection, this adapter preserves the
/// stereo channel separation required by the quadrature phase decoder.
///
/// **Batch 4:** Live audio tap wiring. DEBUG/prototype only.
struct TimecodeCMSampleBufferAdapter {

    // MARK: - StereoResult

    /// A successfully adapted stereo audio buffer.
    struct StereoResult: Equatable {
        /// Left channel samples, normalised to [-1, +1].
        let left: [Float]
        /// Right channel samples, normalised to [-1, +1].
        let right: [Float]
        /// Sample rate in Hz.
        let sampleRate: Double
        /// Host-clock timestamp, if available.
        let hostTime: UInt64?
        /// Number of audio frames in each channel.
        let frameCount: Int
    }

    // MARK: - Conversion

    /// Convert a `CMSampleBuffer` into separate left/right Float32 arrays.
    ///
    /// - Parameter sampleBuffer: The audio sample buffer from
    ///   `AVCaptureAudioDataOutput`.
    /// - Returns: A `StereoResult` with normalised Float32 channel data,
    ///   or `nil` when the format is unsupported, the buffer is empty,
    ///   or an error occurs during extraction.
    static func stereoSampleResult(from sampleBuffer: CMSampleBuffer) -> StereoResult? {
        // --- Format description ---
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let sampleRate = asbd.mSampleRate
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))

        // --- Extract audio buffer list ---
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        // --- Parse format flags ---
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        // --- Convert each buffer to Float32 ---
        var channelSamples: [[Float]] = []

        for buffer in buffers {
            guard let rawData = buffer.mData else { continue }

            if isFloat && bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                channelSamples.append(Array(UnsafeBufferPointer(start: samples, count: sampleCount)))
            } else if bitsPerChannel == 16 {
                let samples = rawData.assumingMemoryBound(to: Int16.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int16.max) })
            } else if bitsPerChannel == 32 {
                // Signed 32-bit integer — normalise to [-1, +1].
                let samples = rawData.assumingMemoryBound(to: Int32.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int32.max) })
            }
            // Unsupported bit depths are silently skipped.
        }

        guard !channelSamples.isEmpty else { return nil }

        // --- Route to stereo ---
        let left: [Float]
        let right: [Float]
        let frameCount: Int

        if buffers.count == 1 && channelCount > 1 && !isNonInterleaved {
            // Interleaved multi-channel: deinterleave into individual channels.
            let interleaved = channelSamples[0]
            let frames = interleaved.count / channelCount
            guard frames > 0 else { return nil }

            if channelCount >= 2 {
                // Deinterleave first two channels.
                var leftSamples = [Float](repeating: 0, count: frames)
                var rightSamples = [Float](repeating: 0, count: frames)
                for frameIndex in 0..<frames {
                    leftSamples[frameIndex] = interleaved[frameIndex * channelCount]
                    rightSamples[frameIndex] = interleaved[frameIndex * channelCount + 1]
                }
                left = leftSamples
                right = rightSamples
            } else {
                // Mono interleaved (unusual but handled).
                left = Array(interleaved.prefix(frames))
                right = left
            }
            frameCount = frames
        } else if channelSamples.count >= 2 {
            // Non-interleaved multi-channel: use first two buffers as L/R.
            let minFrames = min(channelSamples[0].count, channelSamples[1].count)
            guard minFrames > 0 else { return nil }
            left = Array(channelSamples[0].prefix(minFrames))
            right = Array(channelSamples[1].prefix(minFrames))
            frameCount = minFrames
        } else {
            // Single channel (mono): duplicate as both L and R.
            let mono = channelSamples[0]
            guard !mono.isEmpty else { return nil }
            left = mono
            right = mono
            frameCount = mono.count
        }

        // --- Host time ---
        let hostTime: UInt64? = {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.flags.contains(.valid) else { return nil }
            return pts.value > 0 ? UInt64(pts.value) : mach_absolute_time()
        }()

        return StereoResult(
            left: left,
            right: right,
            sampleRate: sampleRate,
            hostTime: hostTime,
            frameCount: frameCount
        )
    }
}

#endif // ENABLE_TIMECODE_LIVE_TAP
