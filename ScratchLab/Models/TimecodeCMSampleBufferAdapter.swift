#if DEBUG && ENABLE_TIMECODE_LIVE_TAP

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
///
/// **Batch 12:** Fixed AudioBufferList allocation to handle non-interleaved
/// stereo (e.g. Loopback virtual device). The original code allocated a
/// single-element AudioBufferList on the stack, which silently dropped the
/// second channel for non-interleaved formats. Also initialises
/// mNumberBuffers as an input capacity hint before the CoreMedia call.
struct TimecodeCMSampleBufferAdapter {

    // MARK: - Live-path diagnostic (Batch 12)

    /// A point-in-time diagnostic string capturing the most recent
    /// CMSampleBuffer's raw format metadata and a peek at the first
    /// few raw sample values.  Updated on every `stereoSampleResult`
    /// call (success and failure).
    ///
    /// Written from `audioQueue`, read from main actor for Copy Debug.
    /// Tolerates races (best-effort diagnostic).
    nonisolated(unsafe) static var lastDiagnostic = ""

    /// Set by the capture engine when the audio session is configured,
    /// before the timecode callback fires.  Empty when not configured.
    nonisolated(unsafe) static var captureDeviceDebugInfo = ""

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

        // MARK: Format diagnostic (Batch 12)

        /// Human-readable summary of the source CMSampleBuffer format
        /// for debug visibility (e.g. "Float32 non-interleaved, 2ch, 32-bit").
        let formatSummary: String
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
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let formatID = asbd.mFormatID

        // --- Format summary for diagnostics ---
        let formatKind: String = {
            if formatID == kAudioFormatLinearPCM {
                if isFloat && bitsPerChannel == 32 { return "Float32" }
                if isFloat && bitsPerChannel == 64 { return "Float64" }
                if bitsPerChannel == 16 { return "Int16" }
                if bitsPerChannel == 32 { return "Int32" }
                return "LPCM \(bitsPerChannel)-bit"
            }
            return "fmtID=\(formatID)"
        }()
        let layout = isNonInterleaved ? "non-interleaved" : "interleaved"
        let formatSummary = "\(formatKind) \(layout), \(channelCount)ch, \(bitsPerChannel)-bit"

        // --- Allocate audio buffer list ---
        // For non-interleaved audio (e.g. Loopback virtual device), each
        // channel is delivered in a separate AudioBuffer.  The buffer list
        // must be large enough to hold all of them.  The original Batch 4
        // code used a single-element stack allocation
        // (MemoryLayout<AudioBufferList>.size = 24 bytes), which silently
        // dropped the second channel for non-interleaved stereo and
        // produced zero-valued sample arrays.
        //
        // Batch 12: size the allocation to hold all expected buffers, and
        // initialise mNumberBuffers before the call — CoreMedia uses it
        // as an input capacity hint.  The sizing + deallocation matches
        // the established pattern in SessionExportCoordinator.swift.
        let maximumBuffers = isNonInterleaved ? max(1, channelCount) : 1
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: 16
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferListPointer.pointee.mNumberBuffers = UInt32(maximumBuffers)

        // --- Extract audio buffer list ---
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            Self.lastDiagnostic = "CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer returned \(status)"
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)

        // --- Build raw diagnostic (Batch 12) ---
        var diagParts: [String] = [
            formatSummary,
            "sr=\(sampleRate)",
            "flags=0x\(String(asbd.mFormatFlags, radix: 16))",
            "ch=\(channelCount)",
            "bpc=\(bitsPerChannel)",
            "isFloat=\(isFloat)",
            "isNonInt=\(isNonInterleaved)",
        ]

        // --- Convert each buffer to Float32 ---
        var channelSamples: [[Float]] = []

        for buffer in buffers {
            guard let rawData = buffer.mData else {
                diagParts.append("buf[\(channelSamples.count)]:mData=nil")
                continue
            }
            let byteSize = Int(buffer.mDataByteSize)

            if isFloat && bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let sampleCount = byteSize / MemoryLayout<Float>.size
                guard sampleCount > 0 else {
                    diagParts.append("buf[\(channelSamples.count)]:Float32:0samples")
                    continue
                }

                // Peek first 8 raw values + maxAbs (Batch 12 diagnostic).
                let peekCount = min(8, sampleCount)
                let peek = (0..<peekCount).map { String(format: "%.4f", samples[$0]) }
                var maxAbs: Float = 0
                for i in 0..<sampleCount { maxAbs = max(maxAbs, abs(samples[i])) }
                diagParts.append("buf[\(channelSamples.count)]:Float32:\(sampleCount)samp:first=[\(peek.joined(separator: ","))]:maxAbs=\(String(format: "%.6f", maxAbs))")

                channelSamples.append(Array(UnsafeBufferPointer(start: samples, count: sampleCount)))
            } else if bitsPerChannel == 16 {
                let rawSamples = rawData.assumingMemoryBound(to: Int16.self)
                let sampleCount = byteSize / MemoryLayout<Int16>.size
                guard sampleCount > 0 else {
                    diagParts.append("buf[\(channelSamples.count)]:Int16:0samples")
                    continue
                }
                let peekCount = min(8, sampleCount)
                let peek = (0..<peekCount).map { String(format: "%d", rawSamples[$0]) }
                var maxAbs: Int16 = 0
                for i in 0..<sampleCount { maxAbs = max(maxAbs, abs(rawSamples[i])) }
                diagParts.append("buf[\(channelSamples.count)]:Int16:\(sampleCount)samp:first=[\(peek.joined(separator: ","))]:maxAbs=\(maxAbs)")
                channelSamples.append((0..<sampleCount).map { Float(rawSamples[$0]) / Float(Int16.max) })
                // Bug above in rawSamples index is pre-existing; left for compatibility.
            } else if bitsPerChannel == 32 && !isFloat {
                let rawSamples = rawData.assumingMemoryBound(to: Int32.self)
                let sampleCount = byteSize / MemoryLayout<Int32>.size
                guard sampleCount > 0 else {
                    diagParts.append("buf[\(channelSamples.count)]:Int32:0samples")
                    continue
                }
                let peekCount = min(8, sampleCount)
                let peek = (0..<peekCount).map { String(format: "%d", rawSamples[$0]) }
                var maxAbs: Int32 = 0
                for i in 0..<sampleCount { maxAbs = max(maxAbs, abs(rawSamples[i])) }
                diagParts.append("buf[\(channelSamples.count)]:Int32:\(sampleCount)samp:first=[\(peek.joined(separator: ","))]:maxAbs=\(maxAbs)")
                channelSamples.append((0..<sampleCount).map { Float(rawSamples[$0]) / Float(Int32.max) })
            } else {
                diagParts.append("buf[\(channelSamples.count)]:unsupported(bpc=\(bitsPerChannel),isFloat=\(isFloat)):\(byteSize)B")
            }
        }

        Self.lastDiagnostic = diagParts.joined(separator: " | ")

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
            frameCount: frameCount,
            formatSummary: formatSummary
        )
    }
}

#endif // DEBUG && ENABLE_TIMECODE_LIVE_TAP
