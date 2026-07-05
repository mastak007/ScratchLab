#if DEBUG && ENABLE_TIMECODE_LIVE_TAP

import AVFoundation
import CoreMedia

/// DEBUG-only conversion and channel routing for the DVS live diagnostics tap.
struct TimecodeCMSampleBufferAdapter {

    enum ChannelPairSelection: Hashable {
        case auto
        case pair(startChannel: Int)

        var label: String {
            switch self {
            case .auto:
                return "Auto"
            case .pair(let startChannel):
                return "\(startChannel + 1)/\(startChannel + 2)"
            }
        }
    }

    struct ChannelDiagnostic: Equatable {
        let channelIndex: Int
        let rms: Float
        let peak: Float
        let maxAbsRaw: Int64?
        let zeroCrossingRate: Float
        let dominantFrequencyHz: Float
        let isNearSilent: Bool
        let isClipping: Bool
    }

    struct PairDiagnostic: Equatable {
        let label: String
        let startChannel: Int
        let rms: Float
        let peak: Float
        let correlation: Float
        let score: Float
        let rejectionReason: String?
    }

    struct StereoResult: Equatable {
        let left: [Float]
        let right: [Float]
        let sampleRate: Double
        let hostTime: UInt64?
        let frameCount: Int
        let formatSummary: String
        let sourceChannelCount: Int
        let selectedChannelPair: String
        let autoRecommendedChannelPair: String?
        let perChannelDiagnostics: [ChannelDiagnostic]
        let perPairDiagnostics: [PairDiagnostic]
        let warning: String?
    }

    struct DiagnosticsSnapshot: Equatable {
        let formatSummary: String
        let sampleRate: Double
        let sourceChannelCount: Int
        let selectedChannelPair: String
        let autoRecommendedChannelPair: String?
        let perChannelDiagnostics: [ChannelDiagnostic]
        let perPairDiagnostics: [PairDiagnostic]
        let warning: String?
    }

    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var storedSelection: ChannelPairSelection = .auto
    private nonisolated(unsafe) static var storedDiagnostics: DiagnosticsSnapshot?
    private nonisolated(unsafe) static var storedLastDiagnostic = ""
    private nonisolated(unsafe) static var storedCaptureDeviceDebugInfo = ""

    static var channelPairSelection: ChannelPairSelection {
        get { stateLock.withLock { storedSelection } }
        set { stateLock.withLock { storedSelection = newValue } }
    }

    static var latestDiagnostics: DiagnosticsSnapshot? {
        stateLock.withLock { storedDiagnostics }
    }

    static var lastDiagnostic: String {
        get { stateLock.withLock { storedLastDiagnostic } }
        set { stateLock.withLock { storedLastDiagnostic = newValue } }
    }

    static var captureDeviceDebugInfo: String {
        get { stateLock.withLock { storedCaptureDeviceDebugInfo } }
        set { stateLock.withLock { storedCaptureDeviceDebugInfo = newValue } }
    }

    static func stereoSampleResult(from sampleBuffer: CMSampleBuffer) -> StereoResult? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            recordFailure("Missing audio format description")
            return nil
        }

        let asbd = asbdPointer.pointee
        let sampleRate = asbd.mSampleRate
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let formatKind: String

        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            recordFailure("Unsupported audio format id \(asbd.mFormatID)")
            return nil
        }
        switch (isFloat, bitsPerChannel) {
        case (true, 32): formatKind = "Float32"
        case (false, 16): formatKind = "Int16"
        case (false, 32): formatKind = "Int32"
        default:
            recordFailure(unsupportedFormatWarning(bitsPerChannel: bitsPerChannel, isFloat: isFloat))
            return nil
        }

        let layout = isNonInterleaved ? "non-interleaved" : "interleaved"
        let formatSummary = "\(formatKind) \(layout), \(channelCount)ch, \(bitsPerChannel)-bit"
        let maximumBuffers = isNonInterleaved ? channelCount : 1
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: 16)
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferListPointer.pointee.mNumberBuffers = UInt32(maximumBuffers)

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
            recordFailure("CMSampleBuffer audio extraction failed: \(status)")
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var convertedBuffers: [[Float]] = []
        var rawMaxima: [[Int64]] = []
        var diagnosticParts = [
            formatSummary,
            "sr=\(sampleRate)",
            "flags=0x\(String(asbd.mFormatFlags, radix: 16))"
        ]

        for (bufferIndex, buffer) in buffers.enumerated() {
            guard let rawData = buffer.mData else {
                diagnosticParts.append("buf[\(bufferIndex)]:mData=nil")
                continue
            }
            let byteSize = Int(buffer.mDataByteSize)
            let conversion = convertPCM(
                rawData: rawData,
                byteSize: byteSize,
                bitsPerChannel: bitsPerChannel,
                isFloat: isFloat
            )
            guard let conversion else {
                diagnosticParts.append("buf[\(bufferIndex)]:unsupported")
                continue
            }
            convertedBuffers.append(conversion.samples)
            rawMaxima.append(conversion.rawAbsoluteValues)
            diagnosticParts.append(
                "buf[\(bufferIndex)]:\(conversion.samples.count)samp:maxAbs=\(conversion.maximumRawDescription)"
            )
        }

        guard !convertedBuffers.isEmpty else {
            recordFailure((diagnosticParts + ["No decodable PCM buffers"]).joined(separator: " | "))
            return nil
        }

        let channels = deinterleave(
            convertedBuffers: convertedBuffers,
            channelCount: channelCount,
            isNonInterleaved: isNonInterleaved
        )
        let channelRawMaxima = deinterleaveRawMaxima(
            convertedBuffers: rawMaxima,
            channelCount: channelCount,
            isNonInterleaved: isNonInterleaved
        )
        guard !channels.isEmpty else {
            recordFailure((diagnosticParts + ["No audio frames"]).joined(separator: " | "))
            return nil
        }

        let hostTime: UInt64? = {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.flags.contains(.valid) else { return nil }
            return pts.value > 0 ? UInt64(pts.value) : mach_absolute_time()
        }()
        let result = makeStereoResult(
            channels: channels,
            rawMaxima: channelRawMaxima,
            sampleRate: sampleRate,
            hostTime: hostTime,
            formatSummary: formatSummary,
            selection: channelPairSelection
        )
        guard let result else {
            recordFailure((diagnosticParts + ["Unable to select channel pair"]).joined(separator: " | "))
            return nil
        }

        let pairSummary = result.perPairDiagnostics.map {
            "\($0.label):rms=\(String(format: "%.5f", $0.rms)),peak=\(String(format: "%.5f", $0.peak))"
        }.joined(separator: ";")
        diagnosticParts.append("selected=\(result.selectedChannelPair)")
        diagnosticParts.append("recommended=\(result.autoRecommendedChannelPair ?? "none")")
        diagnosticParts.append("pairs=[\(pairSummary)]")
        if let warning = result.warning {
            diagnosticParts.append("warning=\(warning)")
        }
        let diagnostic = diagnosticParts.joined(separator: " | ")
        let snapshot = DiagnosticsSnapshot(
            formatSummary: result.formatSummary,
            sampleRate: result.sampleRate,
            sourceChannelCount: result.sourceChannelCount,
            selectedChannelPair: result.selectedChannelPair,
            autoRecommendedChannelPair: result.autoRecommendedChannelPair,
            perChannelDiagnostics: result.perChannelDiagnostics,
            perPairDiagnostics: result.perPairDiagnostics,
            warning: result.warning
        )
        stateLock.withLock {
            storedLastDiagnostic = diagnostic
            storedDiagnostics = snapshot
        }
        return result
    }

    /// Pure conversion entry point used by focused diagnostics tests.
    static func adaptInterleavedInt32(
        _ samples: [Int32],
        channelCount: Int,
        sampleRate: Double,
        selection: ChannelPairSelection
    ) -> StereoResult? {
        guard channelCount > 0, samples.count >= channelCount else { return nil }
        let normalized = samples.map { Float(Double($0) / 2_147_483_648.0) }
        let raw = samples.map { Int64(abs(Double($0))) }
        let channels = deinterleaveInterleaved(normalized, channelCount: channelCount)
        let rawChannels = deinterleaveInterleaved(raw, channelCount: channelCount)
        return makeStereoResult(
            channels: channels,
            rawMaxima: rawChannels,
            sampleRate: sampleRate,
            hostTime: nil,
            formatSummary: "Int32 interleaved, \(channelCount)ch, 32-bit",
            selection: selection
        )
    }

    static func unsupportedFormatWarning(bitsPerChannel: Int, isFloat: Bool) -> String {
        "Unsupported LPCM format: \(isFloat ? "Float" : "Int")\(bitsPerChannel)"
    }

    private struct PCMConversion {
        let samples: [Float]
        let rawAbsoluteValues: [Int64]
        let maximumRawDescription: String
    }

    private static func convertPCM(
        rawData: UnsafeMutableRawPointer,
        byteSize: Int,
        bitsPerChannel: Int,
        isFloat: Bool
    ) -> PCMConversion? {
        if isFloat && bitsPerChannel == 32 {
            let count = byteSize / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            let pointer = rawData.assumingMemoryBound(to: Float.self)
            let samples = (0..<count).map { min(max(pointer[$0], -1), 1) }
            let maximum = samples.map(abs).max() ?? 0
            return PCMConversion(samples: samples, rawAbsoluteValues: [], maximumRawDescription: "\(maximum)")
        }
        if !isFloat && bitsPerChannel == 16 {
            let count = byteSize / MemoryLayout<Int16>.size
            guard count > 0 else { return nil }
            let pointer = rawData.assumingMemoryBound(to: Int16.self)
            let samples = (0..<count).map { Float(pointer[$0]) / 32_768.0 }
            let raw = (0..<count).map { Int64(abs(Int32(pointer[$0]))) }
            return PCMConversion(samples: samples, rawAbsoluteValues: raw, maximumRawDescription: "\(raw.max() ?? 0)")
        }
        if !isFloat && bitsPerChannel == 32 {
            let count = byteSize / MemoryLayout<Int32>.size
            guard count > 0 else { return nil }
            let pointer = rawData.assumingMemoryBound(to: Int32.self)
            let samples = (0..<count).map { Float(Double(pointer[$0]) / 2_147_483_648.0) }
            let raw = (0..<count).map { Int64(abs(Double(pointer[$0]))) }
            return PCMConversion(samples: samples, rawAbsoluteValues: raw, maximumRawDescription: "\(raw.max() ?? 0)")
        }
        return nil
    }

    private static func deinterleave(
        convertedBuffers: [[Float]],
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [[Float]] {
        if isNonInterleaved {
            return Array(convertedBuffers.prefix(channelCount))
        }
        return deinterleaveInterleaved(convertedBuffers[0], channelCount: channelCount)
    }

    private static func deinterleaveRawMaxima(
        convertedBuffers: [[Int64]],
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [[Int64]] {
        guard !convertedBuffers.isEmpty, !convertedBuffers[0].isEmpty else {
            return Array(repeating: [], count: channelCount)
        }
        if isNonInterleaved {
            return Array(convertedBuffers.prefix(channelCount))
        }
        return deinterleaveInterleaved(convertedBuffers[0], channelCount: channelCount)
    }

    private static func deinterleaveInterleaved<T>(_ samples: [T], channelCount: Int) -> [[T]] {
        let frameCount = samples.count / channelCount
        return (0..<channelCount).map { channel in
            (0..<frameCount).map { samples[$0 * channelCount + channel] }
        }
    }

    private static func makeStereoResult(
        channels: [[Float]],
        rawMaxima: [[Int64]],
        sampleRate: Double,
        hostTime: UInt64?,
        formatSummary: String,
        selection: ChannelPairSelection
    ) -> StereoResult? {
        guard let first = channels.first, !first.isEmpty else { return nil }
        if channels.count == 1 {
            let diagnostic = makeChannelDiagnostic(
                samples: first,
                rawSamples: rawMaxima.first ?? [],
                channelIndex: 0,
                sampleRate: sampleRate
            )
            return StereoResult(
                left: first,
                right: first,
                sampleRate: sampleRate,
                hostTime: hostTime,
                frameCount: first.count,
                formatSummary: formatSummary,
                sourceChannelCount: 1,
                selectedChannelPair: "1/1",
                autoRecommendedChannelPair: nil,
                perChannelDiagnostics: [diagnostic],
                perPairDiagnostics: [],
                warning: nil
            )
        }

        let frameCount = channels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return nil }
        let trimmedChannels = channels.map { Array($0.prefix(frameCount)) }
        let channelDiagnostics = trimmedChannels.enumerated().map {
            makeChannelDiagnostic(
                samples: $0.element,
                rawSamples: $0.offset < rawMaxima.count ? rawMaxima[$0.offset] : [],
                channelIndex: $0.offset,
                sampleRate: sampleRate
            )
        }
        let pairDiagnostics = stride(from: 0, to: trimmedChannels.count - 1, by: 2).map { start in
            makePairDiagnostic(
                left: trimmedChannels[start],
                right: trimmedChannels[start + 1],
                startChannel: start,
                channelDiagnostics: channelDiagnostics
            )
        }
        guard let recommended = pairDiagnostics.max(by: { $0.score < $1.score }) else { return nil }

        let requestedStart: Int
        switch selection {
        case .auto:
            requestedStart = recommended.startChannel
        case .pair(let startChannel):
            requestedStart = startChannel
        }
        let selectedStart = requestedStart >= 0 && requestedStart + 1 < trimmedChannels.count
            ? requestedStart
            : recommended.startChannel
        let selectedPair = pairDiagnostics.first { $0.startChannel == selectedStart } ?? recommended
        let warning: String?
        if selectedPair.rms < 0.001, recommended.rms >= 0.001,
           selectedPair.startChannel != recommended.startChannel {
            warning = "Selected pair \(selectedPair.label) is silent; \(recommended.label) has signal"
        } else if requestedStart != selectedStart {
            warning = "Requested pair is unavailable; using \(selectedPair.label)"
        } else {
            warning = nil
        }

        return StereoResult(
            left: trimmedChannels[selectedStart],
            right: trimmedChannels[selectedStart + 1],
            sampleRate: sampleRate,
            hostTime: hostTime,
            frameCount: frameCount,
            formatSummary: formatSummary,
            sourceChannelCount: trimmedChannels.count,
            selectedChannelPair: selectedPair.label,
            autoRecommendedChannelPair: recommended.label,
            perChannelDiagnostics: channelDiagnostics,
            perPairDiagnostics: pairDiagnostics,
            warning: warning
        )
    }

    private static func makeChannelDiagnostic(
        samples: [Float],
        rawSamples: [Int64],
        channelIndex: Int,
        sampleRate: Double
    ) -> ChannelDiagnostic {
        let rms = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        let peak = samples.map(abs).max() ?? 0
        var crossings = 0
        if samples.count > 1 {
            for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
                crossings += 1
            }
        }
        let zcr = samples.count > 1 ? Float(crossings) / Float(samples.count - 1) : 0
        return ChannelDiagnostic(
            channelIndex: channelIndex,
            rms: rms,
            peak: peak,
            maxAbsRaw: rawSamples.max(),
            zeroCrossingRate: zcr,
            dominantFrequencyHz: zcr * Float(sampleRate) * 0.5,
            isNearSilent: rms < 0.001,
            isClipping: peak >= 0.999
        )
    }

    private static func makePairDiagnostic(
        left: [Float],
        right: [Float],
        startChannel: Int,
        channelDiagnostics: [ChannelDiagnostic]
    ) -> PairDiagnostic {
        let leftDiagnostic = channelDiagnostics[startChannel]
        let rightDiagnostic = channelDiagnostics[startChannel + 1]
        let rms = (leftDiagnostic.rms + rightDiagnostic.rms) * 0.5
        let peak = max(leftDiagnostic.peak, rightDiagnostic.peak)
        let correlation = absoluteCorrelation(left, right)
        let frequenciesStable = abs(
            leftDiagnostic.dominantFrequencyHz - rightDiagnostic.dominantFrequencyHz
        ) < 2_000
        let usable = rms >= 0.001 && peak >= 0.002 && peak < 0.999
        let score = usable
            ? rms * 4 + correlation * 0.25 + (frequenciesStable ? 0.15 : 0)
            : -1
        let rejection: String?
        if rms < 0.001 {
            rejection = "near silence"
        } else if peak >= 0.999 {
            rejection = "clipping"
        } else if !frequenciesStable {
            rejection = "unstable channel frequencies"
        } else {
            rejection = nil
        }
        return PairDiagnostic(
            label: "\(startChannel + 1)/\(startChannel + 2)",
            startChannel: startChannel,
            rms: rms,
            peak: peak,
            correlation: correlation,
            score: score,
            rejectionReason: rejection
        )
    }

    private static func absoluteCorrelation(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        let dot = zip(left, right).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let leftEnergy = left.reduce(Float.zero) { $0 + $1 * $1 }
        let rightEnergy = right.reduce(Float.zero) { $0 + $1 * $1 }
        let denominator = sqrt(leftEnergy * rightEnergy)
        return denominator > 0 ? min(abs(dot / denominator), 1) : 0
    }

    private static func recordFailure(_ warning: String) {
        let selectionLabel = channelPairSelection.label
        stateLock.withLock {
            storedLastDiagnostic = warning
            storedDiagnostics = DiagnosticsSnapshot(
                formatSummary: "Unsupported",
                sampleRate: 0,
                sourceChannelCount: 0,
                selectedChannelPair: selectionLabel,
                autoRecommendedChannelPair: nil,
                perChannelDiagnostics: [],
                perPairDiagnostics: [],
                warning: warning
            )
        }
    }
}

#endif
