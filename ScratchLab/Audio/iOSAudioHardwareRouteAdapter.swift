// iOSAudioHardwareRouteAdapter.swift
// ScratchLab - iOS Hardware Route Adapter
//
// Bridges AVAudioSession/AVAudioInputNode into the platform-neutral
// AudioHardwareRouteState model. This is the only place in the iOS app that
// should read AVAudioSession route/channel metadata for that model; callers
// (AudioEngine) hand it session + input-node references and consume the
// published AudioHardwareRouteState.

import Foundation
import AVFoundation

@MainActor
final class iOSAudioHardwareRouteAdapter: ObservableObject {
    @Published private(set) var routeState: AudioHardwareRouteState = .unavailable

    // Remembers the last selected stereo pair per device UID so a device
    // that drops out and reconnects (or a route-change notification that
    // re-observes the same device) restores the user's choice instead of
    // silently resetting to the first pair.
    private var rememberedSelectionByDeviceUID: [String: AudioHardwareRouteState.StereoPair] = [:]

    #if DEBUG
    private var lastLoggedState: AudioHardwareRouteState = .unavailable
    #endif

    /// Re-derives route state from current AVAudioSession/input-node metadata.
    /// Safe to call repeatedly (route-change notifications, engine start/stop,
    /// periodic refresh) — always produces a valid state, never throws or
    /// crashes on missing/malformed hardware metadata.
    @discardableResult
    func refresh(
        session: AVAudioSession,
        inputNode: AVAudioInputNode?,
        isInputActive: Bool,
        signalLevel: Float
    ) -> AudioHardwareRouteState {
        guard let activePort = session.currentRoute.inputs.first else {
            routeState = .unavailable
            logIfChanged()
            return routeState
        }

        // `availableInputs` can carry a fuller channel description than the
        // active-route instance. Match by stable UID while keeping the current
        // route authoritative about which device is actually connected.
        let metadataPort = session.availableInputs?.first(where: {
            $0.uid == activePort.uid
        }) ?? activePort
        let channelDescriptions = (metadataPort.channels ?? activePort.channels ?? []).map {
            AudioHardwareRouteDescription.ChannelDescription(
                channelNumber: $0.channelNumber,
                channelName: $0.channelName
            )
        }
        let inputFormat = inputNode?.inputFormat(forBus: 0)
        let formatChannelCount = inputFormat.map { Int($0.channelCount) } ?? 0
        let hardwareChannelNumbers = Set(
            channelDescriptions.lazy
                .map(\.channelNumber)
                .filter { $0 > 0 }
        )
        var contiguousMetadataChannelCount = 0
        while hardwareChannelNumbers.contains(contiguousMetadataChannelCount + 1) {
            contiguousMetadataChannelCount += 1
        }
        let reportedChannelCount = max(formatChannelCount, contiguousMetadataChannelCount)
        let formatSampleRate = inputFormat?.sampleRate ?? 0
        let sampleRate = formatSampleRate.isFinite && formatSampleRate > 0
            ? formatSampleRate
            : session.sampleRate

        let availablePairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: reportedChannelCount)
        let remembered = rememberedSelectionByDeviceUID[activePort.uid]
        let selectedPair = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: availablePairs,
            remembered: remembered
        )

        let nextState = AudioHardwareRouteState.observing(
            AudioHardwareRouteDescription(
                deviceName: activePort.portName,
                deviceUID: activePort.uid,
                transport: transport(for: activePort.portType),
                sampleRate: sampleRate,
                reportedChannelCount: reportedChannelCount,
                channels: channelDescriptions,
                selectedStereoPair: selectedPair,
                isInputActive: isInputActive,
                signalLevel: signalLevel
            )
        )

        if let confirmedPair = nextState.selectedStereoPair {
            rememberedSelectionByDeviceUID[activePort.uid] = confirmedPair
        }

        routeState = nextState
        logIfChanged()
        return nextState
    }

    /// Updates only PCM-activity fields on the already-observed route,
    /// avoiding a hardware re-query on the real-time audio path.
    func updateActivity(isActive: Bool, signalLevel: Float) {
        routeState = routeState.updatingInputActivity(isActive: isActive, signalLevel: signalLevel)
    }

    /// Manually selects a stereo pair (for a future device-picker UI). No-op
    /// if the pair is not among the currently available pairs.
    func selectStereoPair(_ pair: AudioHardwareRouteState.StereoPair) {
        guard routeState.availableStereoPairs.contains(pair) else { return }
        if let uid = routeState.deviceUID {
            rememberedSelectionByDeviceUID[uid] = pair
        }
        routeState = AudioHardwareRouteState(
            deviceName: routeState.deviceName,
            deviceUID: routeState.deviceUID,
            transport: routeState.transport,
            sampleRate: routeState.sampleRate,
            channelCount: routeState.channelCount,
            availableChannels: routeState.availableChannels,
            availableStereoPairs: routeState.availableStereoPairs,
            selectedStereoPair: pair,
            isInputActive: routeState.isInputActive,
            signalLevel: routeState.signalLevel
        )
    }

    private func transport(for portType: AVAudioSession.Port) -> AudioHardwareRouteState.Transport {
        switch portType {
        case .builtInMic:
            return .builtIn
        case .usbAudio:
            return .usb
        case .lineIn:
            return .lineIn
        case .headsetMic:
            return .headset
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return .bluetooth
        default:
            return portType.rawValue.localizedCaseInsensitiveContains("virtual")
                ? .virtual
                : .unknown
        }
    }

    #if DEBUG
    // Logs only when hardware-format identity actually changes (device,
    // transport, sample rate, channel count/topology, or selected pair) —
    // never per audio callback.
    private func logIfChanged() {
        let previous = lastLoggedState
        let next = routeState
        let hardwareChanged = previous.deviceName != next.deviceName
            || previous.deviceUID != next.deviceUID
            || previous.transport != next.transport
            || previous.sampleRate != next.sampleRate
            || previous.channelCount != next.channelCount
            || previous.availableStereoPairs != next.availableStereoPairs
            || previous.selectedStereoPair != next.selectedStereoPair
        guard hardwareChanged else { return }
        lastLoggedState = next

        let pairs = next.availableStereoPairs
            .map(\.displayName)
            .joined(separator: "\n")
        print("""
        Audio Route Changed

        Device:
        \(next.deviceName ?? "None")

        Transport:
        \(next.transport.rawValue)

        Sample Rate:
        \(next.sampleRate.map { String(format: "%.0f", $0) } ?? "Unknown")

        Channels:
        \(next.channelCount)

        Stereo Pairs:
        \(pairs.isEmpty ? "None" : pairs)

        Selected:
        \(next.selectedStereoPair?.displayName ?? "None")
        """)
    }
    #endif
}
