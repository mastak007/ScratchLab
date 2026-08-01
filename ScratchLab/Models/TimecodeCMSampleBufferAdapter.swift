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
        let leftDominantFrequencyHz: Float
        let rightDominantFrequencyHz: Float
        let leftZeroCrossingRate: Float
        let rightZeroCrossingRate: Float
        let frequenciesStable: Bool
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
#if DEBUG
        if DebugTimecodeCapture.isCapturing,
           channels.count > 3 {
            DebugTimecodeCapture.record(
                channels: channels,
                sampleRate: sampleRate,
                hostTime: hostTime,
                formatSummary: formatSummary
            )
        }
#endif

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

        let pairSummary = result.perPairDiagnostics.map { pair -> String in
            "\(pair.label):rms=\(String(format: "%.5f", pair.rms))"
                + ",peak=\(String(format: "%.5f", pair.peak))"
                + ",score=\(String(format: "%.3f", pair.score))"
                + ",freqStable=\(pair.frequenciesStable)"
                + ",freqHzL=\(Int(pair.leftDominantFrequencyHz))"
                + ",freqHzR=\(Int(pair.rightDominantFrequencyHz))"
                + ",zcrL=\(String(format: "%.4f", pair.leftZeroCrossingRate))"
                + ",zcrR=\(String(format: "%.4f", pair.rightZeroCrossingRate))"
                + ",reject=\(pair.rejectionReason ?? "none")"
        }.joined(separator: ";")
        diagnosticParts.append("selected=\(result.selectedChannelPair)")
        diagnosticParts.append("recommended=\(result.autoRecommendedChannelPair ?? "none")")
        diagnosticParts.append("pairs=[\(pairSummary)]")
        if let recommendedDiagnostic = result.perPairDiagnostics.first(
            where: { $0.label == result.autoRecommendedChannelPair }
        ) {
            let autoSelectionReason = recommendedDiagnostic.rejectionReason.map {
                "no pair passed validity checks; defaulted to \(recommendedDiagnostic.label) (reason: \($0))"
            } ?? "\(recommendedDiagnostic.label) highest-scoring usable carrier pair"
                + " (score=\(String(format: "%.3f", recommendedDiagnostic.score)),"
                + " freqStable=\(recommendedDiagnostic.frequenciesStable))"
            diagnosticParts.append("autoReason=\(autoSelectionReason)")
        }
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

    /// Broad plausible DVS control-tone carrier band. A pair whose per-channel
    /// dominant frequency falls outside this range (including 0 Hz — no
    /// oscillation at all) cannot be real quadrature timecode, regardless of
    /// how loud it is.
    private static let carrierRangeHz: ClosedRange<Float> = 500...2_500

    /// A channel with a zero-crossing rate at or below this floor is not
    /// oscillating in any meaningful sense (e.g. DC, silence, or a 0 Hz
    /// reading) and cannot be carrying a timecode carrier.
    private static let minimumCarrierZeroCrossingRate: Float = 0.001

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
        // Frequency agreement alone isn't enough — a pair with 0 Hz / 0
        // zero-crossings on both channels (no oscillation at all) trivially
        // "agrees" and must not be mistaken for a carrier. Require both
        // channels to show an actual oscillation in the plausible DVS
        // carrier band before a loud pair can be considered timecode.
        let hasCarrierEvidence = Self.carrierRangeHz.contains(leftDiagnostic.dominantFrequencyHz)
            && Self.carrierRangeHz.contains(rightDiagnostic.dominantFrequencyHz)
            && leftDiagnostic.zeroCrossingRate > Self.minimumCarrierZeroCrossingRate
            && rightDiagnostic.zeroCrossingRate > Self.minimumCarrierZeroCrossingRate
        let usable = rms >= 0.001 && peak >= 0.002 && peak < 0.999
            && frequenciesStable && hasCarrierEvidence
        let score = usable
            ? rms * 4 + correlation * 0.25 + 0.15
            : -1
        let rejection: String?
        if rms < 0.001 {
            rejection = "near silence"
        } else if peak >= 0.999 {
            rejection = "clipping"
        } else if !hasCarrierEvidence {
            rejection = "no timecode carrier"
        } else if !frequenciesStable {
            rejection = "no timecode evidence"
        } else {
            rejection = nil
        }
        return PairDiagnostic(
            label: "\(startChannel + 1)/\(startChannel + 2)",
            startChannel: startChannel,
            rms: rms,
            peak: peak,
            correlation: correlation,
            leftDominantFrequencyHz: leftDiagnostic.dominantFrequencyHz,
            rightDominantFrequencyHz: rightDiagnostic.dominantFrequencyHz,
            leftZeroCrossingRate: leftDiagnostic.zeroCrossingRate,
            rightZeroCrossingRate: rightDiagnostic.zeroCrossingRate,
            frequenciesStable: frequenciesStable,
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


// MARK: - DEBUG labelled capture for DVS signal analysis

/// DEBUG-only disk-backed recorder for labelled DVS hardware fixtures.
///
/// Audio callbacks only copy already-deinterleaved channel arrays and enqueue
/// them onto a private utility queue. All audio-file and metadata I/O happens
/// on that queue, never on the realtime callback. Each fixture preserves the
/// full pre-selection source channel set and also writes physical pair 3/4 as
/// a stereo WAV for direct use by `TimecodeFixtureLoader`.
public struct DebugTimecodeCapture {

    public static let labels = [
        "stationary",
        "steady_normal",
        "slow_forward",
        "slow_backward",
        "fast_forward",
        "fast_backward",
        "slow_reversals",
        "fast_reversals",
        "fine_flicks",
        "baby_scratch",
        "start_stop",
        "needle_lift",
        "position_start",
        "position_middle",
        "position_end"
    ]
    public static let sourcePair = "3/4"
    public static let maxDuration: TimeInterval = 90

    public struct Summary: Equatable, Sendable {
        public let label: String
        public let directoryURL: URL
        public let rawMultichannelURL: URL?
        public let stereoPairURL: URL?
        public let callbacksURL: URL
        public let manifestURL: URL
        public let sampleRate: Double
        public let sourceChannelCount: Int
        public let sampleCount: Int
        public let callbackCount: Int
        public let leftRMS: Float
        public let rightRMS: Float
        public let leftPeak: Float
        public let rightPeak: Float
        public let leftZCRFrequency: Float
        public let rightZCRFrequency: Float
        public let correlation: Float
        public let phaseOffset: Float?
        public let errors: [String]

        public var text: String {
            let phaseText = phaseOffset.map { String(format: "%.1f°", $0) } ?? "unavailable"
            let errorText = errors.isEmpty ? "none" : errors.joined(separator: " | ")
            return """
            DVS Fixture Capture
            label: \(label)
            folder: \(directoryURL.path)
            source pair: \(DebugTimecodeCapture.sourcePair) (raw physical channels, before selection/rejection)
            sample rate: \(String(format: "%.1f", sampleRate)) Hz
            source channels: \(sourceChannelCount)
            sample count: \(sampleCount)
            callbacks: \(callbackCount)
            duration: \(String(format: "%.3f", duration)) s
            multichannel audio: \(rawMultichannelURL?.lastPathComponent ?? "not written")
            pair 3/4 WAV: \(stereoPairURL?.lastPathComponent ?? "not written")
            callback timeline: \(callbacksURL.lastPathComponent)
            manifest: \(manifestURL.lastPathComponent)
            left RMS: \(String(format: "%.6f", leftRMS))
            right RMS: \(String(format: "%.6f", rightRMS))
            left peak: \(String(format: "%.6f", leftPeak))
            right peak: \(String(format: "%.6f", rightPeak))
            left ZCR frequency: \(String(format: "%.1f", leftZCRFrequency)) Hz
            right ZCR frequency: \(String(format: "%.1f", rightZCRFrequency)) Hz
            correlation: \(String(format: "%.6f", correlation))
            phase offset: \(phaseText)
            errors: \(errorText)
            """
        }

        public var duration: TimeInterval {
            sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
        }
    }

    private struct CallbackRecord: Codable, Sendable {
        let sequenceNumber: Int
        let sourceFrameStart: Int
        let frameCount: Int
        let hostTime: UInt64?
        let callbackUptime: TimeInterval
        let sampleRate: Double
        let sourceChannelCount: Int
        let formatSummary: String
    }

    private struct Manifest: Codable, Sendable {
        let schemaVersion: Int
        let label: String
        let startedAt: Date
        let completedAt: Date
        let sampleRate: Double
        let sourceChannelCount: Int
        let sampleCount: Int
        let callbackCount: Int
        let sourcePair: String
        let rawMultichannelFile: String?
        let stereoPairFile: String?
        let callbacksFile: String
        let captureDeviceDebugInfo: String
        let sourceFormatSummaries: [String]
        let errors: [String]
        let preservationNote: String
    }

    private struct PendingBuffer: Sendable {
        let channels: [[Float]]
        let sampleRate: Double
        let hostTime: UInt64?
        let callbackUptime: TimeInterval
        let formatSummary: String
        let sequenceNumber: Int
    }

    private final class CaptureSession: @unchecked Sendable {
        let label: String
        let directoryURL: URL
        let rawMultichannelURL: URL
        let stereoPairURL: URL
        let callbacksURL: URL
        let manifestURL: URL
        let startedAt: Date
        let captureDeviceDebugInfo: String

        private let writerQueue = DispatchQueue(
            label: "com.scratchlab.debug-dvs-fixture-writer",
            qos: .utility
        )
        private var rawFile: AVAudioFile?
        private var pairFile: AVAudioFile?
        private var callbacksHandle: FileHandle?
        private var sampleRate: Double = 0
        private var sourceChannelCount = 0
        private var sampleCount = 0
        private var callbackCount = 0
        private var sourceFormatSummaries: Set<String> = []
        private var errors: [String] = []
        private var writerInitializationAttempted = false

        private var metricCount = 0
        private var leftSum: Double = 0
        private var rightSum: Double = 0
        private var leftSumSquares: Double = 0
        private var rightSumSquares: Double = 0
        private var productSum: Double = 0
        private var leftPeak: Float = 0
        private var rightPeak: Float = 0
        private var leftCrossings = 0
        private var rightCrossings = 0
        private var previousLeft: Float?
        private var previousRight: Float?
        private var phaseProbeLeft: [Float] = []
        private var phaseProbeRight: [Float] = []

        init(
            label: String,
            rootDirectoryURL: URL,
            captureDeviceDebugInfo: String
        ) throws {
            self.label = label
            self.startedAt = Date()
            self.captureDeviceDebugInfo = captureDeviceDebugInfo

            let identifier = Self.timestampIdentifier(for: startedAt)
            let folderName = "\(identifier)_\(Self.safePathComponent(label))_\(UUID().uuidString.prefix(8))"
            directoryURL = rootDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
            rawMultichannelURL = directoryURL.appendingPathComponent("raw_multichannel_float32.caf")
            stereoPairURL = directoryURL.appendingPathComponent("pair_3_4_float32.wav")
            callbacksURL = directoryURL.appendingPathComponent("callbacks.jsonl")
            manifestURL = directoryURL.appendingPathComponent("manifest.json")

            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(
                atPath: callbacksURL.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            callbacksHandle = try FileHandle(forWritingTo: callbacksURL)
        }

        func enqueue(_ buffer: PendingBuffer) {
            writerQueue.async { [self] in
                append(buffer)
            }
        }

        func finishAndWait() -> Summary {
            writerQueue.sync {
                finishOnQueue()
            }
        }

        private func append(_ pending: PendingBuffer) {
            let channelCount = pending.channels.count
            guard channelCount >= 4,
                  let frameCount = pending.channels.map(\.count).min(),
                  frameCount > 0 else {
                appendErrorOnce("Capture requires at least four non-empty source channels for physical pair 3/4.")
                return
            }

            if !writerInitializationAttempted {
                writerInitializationAttempted = true
                configureWriters(
                    sampleRate: pending.sampleRate,
                    sourceChannelCount: channelCount
                )
            }
            guard pending.sampleRate == sampleRate,
                  channelCount == sourceChannelCount,
                  let rawFile,
                  let pairFile else {
                appendErrorOnce(
                    "Source format changed during capture; expected \(sourceChannelCount)ch @ \(sampleRate) Hz, received \(channelCount)ch @ \(pending.sampleRate) Hz."
                )
                return
            }

            do {
                let rawBuffer = try makeBuffer(
                    channels: pending.channels,
                    frameCount: frameCount,
                    format: rawFile.processingFormat
                )
                try rawFile.write(from: rawBuffer)

                let pairChannels = [
                    Array(pending.channels[2].prefix(frameCount)),
                    Array(pending.channels[3].prefix(frameCount))
                ]
                let pairBuffer = try makeBuffer(
                    channels: pairChannels,
                    frameCount: frameCount,
                    format: pairFile.processingFormat
                )
                try pairFile.write(from: pairBuffer)

                let callback = CallbackRecord(
                    sequenceNumber: pending.sequenceNumber,
                    sourceFrameStart: sampleCount,
                    frameCount: frameCount,
                    hostTime: pending.hostTime,
                    callbackUptime: pending.callbackUptime,
                    sampleRate: pending.sampleRate,
                    sourceChannelCount: channelCount,
                    formatSummary: pending.formatSummary
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var callbackData = try encoder.encode(callback)
                callbackData.append(0x0A)
                try callbacksHandle?.write(contentsOf: callbackData)

                sampleCount += frameCount
                callbackCount += 1
                sourceFormatSummaries.insert(pending.formatSummary)
                updateMetrics(left: pairChannels[0], right: pairChannels[1])
            } catch {
                appendErrorOnce("Fixture write failed: \(error.localizedDescription)")
            }
        }

        private func configureWriters(sampleRate: Double, sourceChannelCount: Int) {
            let discreteLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder
                | AudioChannelLayoutTag(sourceChannelCount)
            guard sampleRate > 0,
                  sourceChannelCount >= 4,
                  let rawChannelLayout = AVAudioChannelLayout(
                    layoutTag: discreteLayoutTag
                  ),
                  let pairFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 2,
                    interleaved: false
                  ) else {
                appendErrorOnce("Unable to create Float32 fixture audio formats.")
                return
            }
            let rawFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: rawChannelLayout
            )

            do {
                rawFile = try AVAudioFile(
                    forWriting: rawMultichannelURL,
                    settings: rawFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                pairFile = try AVAudioFile(
                    forWriting: stereoPairURL,
                    settings: pairFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                self.sampleRate = sampleRate
                self.sourceChannelCount = sourceChannelCount
            } catch {
                appendErrorOnce("Unable to open fixture audio files: \(error.localizedDescription)")
            }
        }

        private func makeBuffer(
            channels: [[Float]],
            frameCount: Int,
            format: AVAudioFormat
        ) throws -> AVAudioPCMBuffer {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.floatChannelData else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for channelIndex in 0..<Int(format.channelCount) {
                channels[channelIndex].withUnsafeBufferPointer { source in
                    guard let sourceBase = source.baseAddress else { return }
                    channelData[channelIndex].update(
                        from: sourceBase,
                        count: frameCount
                    )
                }
            }
            return buffer
        }

        private func updateMetrics(left: [Float], right: [Float]) {
            let count = min(left.count, right.count)
            guard count > 0 else { return }
            let maximumProbeFrames = max(1, Int(sampleRate * 2))
            let remainingProbeFrames = max(0, maximumProbeFrames - phaseProbeLeft.count)
            if remainingProbeFrames > 0 {
                let probeCount = min(count, remainingProbeFrames)
                phaseProbeLeft.append(contentsOf: left.prefix(probeCount))
                phaseProbeRight.append(contentsOf: right.prefix(probeCount))
            }

            for index in 0..<count {
                let l = left[index]
                let r = right[index]
                leftSum += Double(l)
                rightSum += Double(r)
                leftSumSquares += Double(l * l)
                rightSumSquares += Double(r * r)
                productSum += Double(l * r)
                leftPeak = max(leftPeak, abs(l))
                rightPeak = max(rightPeak, abs(r))
                if let previousLeft, (previousLeft >= 0) != (l >= 0) {
                    leftCrossings += 1
                }
                if let previousRight, (previousRight >= 0) != (r >= 0) {
                    rightCrossings += 1
                }
                previousLeft = l
                previousRight = r
            }
            metricCount += count
        }

        private func finishOnQueue() -> Summary {
            do {
                try callbacksHandle?.close()
            } catch {
                appendErrorOnce("Unable to close callback timeline: \(error.localizedDescription)")
            }
            callbacksHandle = nil
            rawFile = nil
            pairFile = nil

            let completedAt = Date()
            let rawExists = FileManager.default.fileExists(atPath: rawMultichannelURL.path)
            let pairExists = FileManager.default.fileExists(atPath: stereoPairURL.path)
            let manifest = Manifest(
                schemaVersion: 1,
                label: label,
                startedAt: startedAt,
                completedAt: completedAt,
                sampleRate: sampleRate,
                sourceChannelCount: sourceChannelCount,
                sampleCount: sampleCount,
                callbackCount: callbackCount,
                sourcePair: DebugTimecodeCapture.sourcePair,
                rawMultichannelFile: rawExists ? rawMultichannelURL.lastPathComponent : nil,
                stereoPairFile: pairExists ? stereoPairURL.lastPathComponent : nil,
                callbacksFile: callbacksURL.lastPathComponent,
                captureDeviceDebugInfo: captureDeviceDebugInfo,
                sourceFormatSummaries: sourceFormatSummaries.sorted(),
                errors: errors,
                preservationNote: "Pre-selection source channels stored as native-rate Float32 PCM; pair 3/4 is derived without normalization, fades, compression, or sample-rate conversion."
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(
                    to: manifestURL,
                    options: .atomic
                )
            } catch {
                appendErrorOnce("Unable to write fixture manifest: \(error.localizedDescription)")
            }

            let divisor = Double(max(metricCount, 1))
            let meanLeft = leftSum / divisor
            let meanRight = rightSum / divisor
            let covariance = productSum - divisor * meanLeft * meanRight
            let leftVariance = leftSumSquares - divisor * meanLeft * meanLeft
            let rightVariance = rightSumSquares - divisor * meanRight * meanRight
            let correlationDenominator = sqrt(max(0, leftVariance * rightVariance))
            let leftFrequency = metricCount > 1
                ? Float(leftCrossings) * Float(sampleRate) / Float(metricCount - 1) * 0.5
                : 0
            let rightFrequency = metricCount > 1
                ? Float(rightCrossings) * Float(sampleRate) / Float(metricCount - 1) * 0.5
                : 0

            return Summary(
                label: label,
                directoryURL: directoryURL,
                rawMultichannelURL: rawExists ? rawMultichannelURL : nil,
                stereoPairURL: pairExists ? stereoPairURL : nil,
                callbacksURL: callbacksURL,
                manifestURL: manifestURL,
                sampleRate: sampleRate,
                sourceChannelCount: sourceChannelCount,
                sampleCount: sampleCount,
                callbackCount: callbackCount,
                leftRMS: Float(sqrt(leftSumSquares / divisor)),
                rightRMS: Float(sqrt(rightSumSquares / divisor)),
                leftPeak: leftPeak,
                rightPeak: rightPeak,
                leftZCRFrequency: leftFrequency,
                rightZCRFrequency: rightFrequency,
                correlation: correlationDenominator > 0
                    ? Float(covariance / correlationDenominator)
                    : 0,
                phaseOffset: DebugTimecodeCapture.phaseOffset(
                    left: phaseProbeLeft,
                    right: phaseProbeRight,
                    sampleRate: Float(sampleRate),
                    frequency: leftFrequency > 0 ? leftFrequency : rightFrequency
                ),
                errors: errors
            )
        }

        private func appendErrorOnce(_ message: String) {
            if !errors.contains(message) {
                errors.append(message)
            }
        }

        private static func timestampIdentifier(for date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            return formatter.string(from: date)
        }

        private static func safePathComponent(_ value: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            return value.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? String(scalar) : "_"
            }.joined()
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeSession: CaptureSession?
    nonisolated(unsafe) private static var sequenceCounter: Int = 0
    nonisolated(unsafe) private static var storedLastStartError: String?

    public static var isCapturing: Bool {
        lock.withLock { activeSession != nil }
    }

    public static var lastStartError: String? {
        lock.withLock { storedLastStartError }
    }

    public static var defaultRootDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("DebugCaptures", isDirectory: true)
            .appendingPathComponent("Timecode", isDirectory: true)
    }

    @discardableResult
    public static func begin(
        label: String,
        rootDirectoryURL: URL = defaultRootDirectoryURL
    ) -> Bool {
        guard labels.contains(label) else { return false }
        do {
            let session = try CaptureSession(
                label: label,
                rootDirectoryURL: rootDirectoryURL,
                captureDeviceDebugInfo: TimecodeCMSampleBufferAdapter.captureDeviceDebugInfo
            )
            return lock.withLock {
                guard activeSession == nil else { return false }
                sequenceCounter = 0
                storedLastStartError = nil
                activeSession = session
                return true
            }
        } catch {
            lock.withLock {
                storedLastStartError = error.localizedDescription
            }
            return false
        }
    }

    /// Called on the audio callback with all raw deinterleaved physical
    /// channels, before pair selection or rejection.
    public static func record(
        channels: [[Float]],
        sampleRate: Double,
        hostTime: UInt64?,
        formatSummary: String
    ) {
        guard sampleRate > 0 else { return }
        let capture: (CaptureSession, Int)? = lock.withLock {
            guard let activeSession else { return nil }
            let sequence = sequenceCounter
            sequenceCounter += 1
            return (activeSession, sequence)
        }
        guard let (session, sequenceNumber) = capture else { return }
        session.enqueue(PendingBuffer(
            channels: channels,
            sampleRate: sampleRate,
            hostTime: hostTime,
            callbackUptime: ProcessInfo.processInfo.systemUptime,
            formatSummary: formatSummary,
            sequenceNumber: sequenceNumber
        ))
    }

    public static func finish() -> Summary? {
        let session: CaptureSession? = lock.withLock {
            let session = activeSession
            activeSession = nil
            return session
        }
        return session?.finishAndWait()
    }

    public static func cancel() {
        let session: CaptureSession? = lock.withLock {
            let session = activeSession
            activeSession = nil
            return session
        }
        _ = session?.finishAndWait()
    }

    private static func phaseOffset(left: [Float], right: [Float], sampleRate: Float, frequency: Float) -> Float? {
        let count = min(left.count, right.count)
        guard count > 1, sampleRate > 0, frequency > 0 else { return nil }
        let periodSamples = Int(sampleRate / frequency)
        let maxLag = min(count / 2, max(1, periodSamples / 2))
        var bestLag = 0
        var bestCorrelation = -Float.infinity
        for lag in -maxLag...maxLag {
            var sum: Float = 0
            var overlap = 0
            for index in 0..<count {
                let shifted = index + lag
                guard shifted >= 0, shifted < count else { continue }
                sum += left[index] * right[shifted]
                overlap += 1
            }
            if overlap > 0, sum / Float(overlap) > bestCorrelation {
                bestCorrelation = sum / Float(overlap)
                bestLag = lag
            }
        }
        let degrees = Float(bestLag) * frequency / sampleRate * 360
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized > 180 ? normalized - 360 : (normalized < -180 ? normalized + 360 : normalized)
    }

}

#endif
