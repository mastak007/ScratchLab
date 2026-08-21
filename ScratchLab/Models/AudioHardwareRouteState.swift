import Foundation

/// Platform-neutral observation of the audio input route currently exposed to
/// ScratchLab. Platform adapters translate AVAudioSession or Core Audio state
/// into this value; this model does not perform hardware discovery or routing.
struct AudioHardwareRouteState: Equatable, Sendable {
    enum Transport: String, Equatable, Sendable {
        case builtIn
        case usb
        case lineIn
        case headset
        case bluetooth
        case virtual
        case unknown
    }

    /// A complete adjacent stereo pair in the input buffer. Channel indices
    /// are zero-based internally and displayed one-based to match audio-hardware
    /// labelling (for example, indices 2/3 display as "3/4").
    struct StereoPair: Equatable, Hashable, Identifiable, Sendable {
        let firstChannelIndex: Int
        let secondChannelIndex: Int

        var id: Int { firstChannelIndex }

        var displayName: String {
            "\(firstChannelIndex + 1)/\(secondChannelIndex + 1)"
        }

        init?(firstChannelIndex: Int, secondChannelIndex: Int) {
            guard firstChannelIndex >= 0,
                  secondChannelIndex == firstChannelIndex + 1 else {
                return nil
            }
            self.firstChannelIndex = firstChannelIndex
            self.secondChannelIndex = secondChannelIndex
        }

        /// Complete, non-overlapping pairs available in a contiguous input
        /// buffer. An unpaired final channel is deliberately omitted.
        static func contiguousPairs(channelCount: Int) -> [StereoPair] {
            guard channelCount >= 2 else { return [] }
            return stride(from: 0, to: channelCount - 1, by: 2).compactMap {
                StereoPair(firstChannelIndex: $0, secondChannelIndex: $0 + 1)
            }
        }

        /// Decides which pair a route adapter should treat as selected: the
        /// previously remembered pair if it is still among the currently
        /// available pairs, otherwise the first available pair, otherwise
        /// `nil` (for example a true single-channel microphone, or metadata
        /// too malformed to yield any complete pair).
        static func resolveSelection(
            availablePairs: [StereoPair],
            remembered: StereoPair?
        ) -> StereoPair? {
            if let remembered, availablePairs.contains(remembered) {
                return remembered
            }
            return availablePairs.first
        }

        /// Extracts this pair's left/right samples from interleaved
        /// multichannel PCM without downmixing any other channel. `samples`
        /// is frame-major interleaved audio (`frame0Ch0, frame0Ch1, ...,
        /// frame1Ch0, ...`); `channelCount` is the number of channels each
        /// frame carries. Returns `nil` rather than trapping when the buffer
        /// is too short or narrower than this pair requires.
        func extractInterleaved(_ samples: [Float], channelCount: Int) -> (left: [Float], right: [Float])? {
            guard channelCount > 0, secondChannelIndex < channelCount else { return nil }
            let frameCount = samples.count / channelCount
            guard frameCount > 0 else { return nil }

            var left = [Float](repeating: 0, count: frameCount)
            var right = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                let base = frame * channelCount
                left[frame] = samples[base + firstChannelIndex]
                right[frame] = samples[base + secondChannelIndex]
            }
            return (left, right)
        }
    }

    struct Channel: Equatable, Hashable, Identifiable, Sendable {
        /// Zero-based position in the input buffer.
        let index: Int
        /// One-based channel number reported by the hardware API.
        let hardwareChannelNumber: Int
        let name: String?

        var id: Int { index }

        var displayName: String {
            name ?? "Channel \(hardwareChannelNumber)"
        }
    }

    let deviceName: String?
    let deviceUID: String?
    let transport: Transport
    let sampleRate: Double?
    let channelCount: Int
    let availableChannels: [Channel]
    let availableStereoPairs: [StereoPair]
    let selectedStereoPair: StereoPair?

    /// True only after the platform adapter has observed PCM callbacks from
    /// this route. This is independent of signal amplitude: silent PCM is
    /// active input with a zero signal level.
    let isInputActive: Bool

    /// Normalised RMS/activity level in 0...1.
    let signalLevel: Float

    static let unavailable = AudioHardwareRouteState()

    init(
        deviceName: String? = nil,
        deviceUID: String? = nil,
        transport: Transport = .unknown,
        sampleRate: Double? = nil,
        channelCount: Int = 0,
        availableChannels: [Channel]? = nil,
        availableStereoPairs: [StereoPair]? = nil,
        selectedStereoPair: StereoPair? = nil,
        isInputActive: Bool = false,
        signalLevel: Float = 0
    ) {
        let normalizedChannelCount = max(0, channelCount)
        let normalizedDeviceName = deviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceUID = deviceUID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateChannels = availableChannels ?? (0..<normalizedChannelCount).map {
            Channel(index: $0, hardwareChannelNumber: $0 + 1, name: nil)
        }
        var observedChannelIndices = Set<Int>()
        let normalizedChannels = candidateChannels
            .filter {
                $0.index >= 0
                    && $0.index < normalizedChannelCount
                    && $0.hardwareChannelNumber > 0
                    && observedChannelIndices.insert($0.index).inserted
            }
            .sorted { $0.index < $1.index }
        let availableChannelIndices = Set(normalizedChannels.map(\.index))
        let candidatePairs = availableStereoPairs
            ?? StereoPair.contiguousPairs(channelCount: normalizedChannelCount)
        let normalizedPairs = Array(Set(candidatePairs.filter {
            $0.secondChannelIndex < normalizedChannelCount
                && availableChannelIndices.contains($0.firstChannelIndex)
                && availableChannelIndices.contains($0.secondChannelIndex)
        })).sorted { $0.firstChannelIndex < $1.firstChannelIndex }

        self.deviceName = normalizedDeviceName?.isEmpty == false
            ? normalizedDeviceName
            : nil
        self.deviceUID = normalizedDeviceUID?.isEmpty == false
            ? normalizedDeviceUID
            : nil
        self.transport = transport
        self.sampleRate = sampleRate.flatMap { rate in
            rate.isFinite && rate > 0 ? rate : nil
        }
        self.channelCount = normalizedChannelCount
        self.availableChannels = normalizedChannels
        self.availableStereoPairs = normalizedPairs
        self.selectedStereoPair = selectedStereoPair.flatMap { pair in
            normalizedPairs.contains(pair) ? pair : nil
        }
        self.isInputActive = isInputActive
        self.signalLevel = signalLevel.isFinite
            ? min(max(signalLevel, 0), 1)
            : 0
    }

    /// Builds shared route state from a platform adapter's hardware
    /// description without depending on AVFoundation or Core Audio.
    static func observing(_ description: AudioHardwareRouteDescription?) -> AudioHardwareRouteState {
        guard let description else { return .unavailable }

        let reportedChannelCount = max(0, description.reportedChannelCount)
        let metadataUpperBound = reportedChannelCount > 0
            ? reportedChannelCount
            : description.channels.count
        var observedHardwareNumbers = Set<Int>()
        let validMetadata = description.channels
            .filter {
                $0.channelNumber > 0
                    && $0.channelNumber <= metadataUpperBound
                    && observedHardwareNumbers.insert($0.channelNumber).inserted
            }
            .sorted { $0.channelNumber < $1.channelNumber }
        let channelCount = max(reportedChannelCount, validMetadata.count)
        let metadataByNumber = Dictionary(
            uniqueKeysWithValues: validMetadata.map { ($0.channelNumber, $0) }
        )
        let channels = channelCount > 0 ? (1...channelCount).map { number in
            Channel(
                index: number - 1,
                hardwareChannelNumber: number,
                name: metadataByNumber[number]?.channelName
            )
        } : []

        return AudioHardwareRouteState(
            deviceName: description.deviceName,
            deviceUID: description.deviceUID,
            transport: description.transport,
            sampleRate: description.sampleRate,
            channelCount: channelCount,
            availableChannels: channels,
            selectedStereoPair: description.selectedStereoPair,
            isInputActive: description.isInputActive,
            signalLevel: description.signalLevel
        )
    }

    func updatingInputActivity(
        isActive: Bool,
        signalLevel: Float
    ) -> AudioHardwareRouteState {
        AudioHardwareRouteState(
            deviceName: deviceName,
            deviceUID: deviceUID,
            transport: transport,
            sampleRate: sampleRate,
            channelCount: channelCount,
            availableChannels: availableChannels,
            availableStereoPairs: availableStereoPairs,
            selectedStereoPair: selectedStereoPair,
            isInputActive: isActive,
            signalLevel: signalLevel
        )
    }
}

/// Platform-neutral input used by hardware route adapters. Tests can supply
/// the same shape without constructing framework-owned hardware objects.
struct AudioHardwareRouteDescription: Equatable, Sendable {
    struct ChannelDescription: Equatable, Sendable {
        let channelNumber: Int
        let channelName: String?
    }

    let deviceName: String?
    let deviceUID: String?
    let transport: AudioHardwareRouteState.Transport
    let sampleRate: Double?
    let reportedChannelCount: Int
    let channels: [ChannelDescription]
    let selectedStereoPair: AudioHardwareRouteState.StereoPair?
    let isInputActive: Bool
    let signalLevel: Float

    init(
        deviceName: String?,
        deviceUID: String? = nil,
        transport: AudioHardwareRouteState.Transport,
        sampleRate: Double?,
        reportedChannelCount: Int,
        channels: [ChannelDescription] = [],
        selectedStereoPair: AudioHardwareRouteState.StereoPair? = nil,
        isInputActive: Bool = false,
        signalLevel: Float = 0
    ) {
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.transport = transport
        self.sampleRate = sampleRate
        self.reportedChannelCount = reportedChannelCount
        self.channels = channels
        self.selectedStereoPair = selectedStereoPair
        self.isInputActive = isInputActive
        self.signalLevel = signalLevel
    }
}
