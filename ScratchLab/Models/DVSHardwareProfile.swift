// DVSHardwareProfile.swift
// ScratchLab - Known-hardware DVS defaults
//
// Most audio interfaces have no opinion about which stereo pair carries a
// turntable's timecode signal, so `AudioHardwareRouteState.StereoPair
// .resolveSelection` defaults new/unknown hardware to the first available
// pair. A small number of interfaces are known in advance to route their
// validated DVS capture on a different pair. Add an entry here only once
// that has actually been confirmed against real hardware — never
// speculatively for a whole product line.
//
// This is a *first-time default* only: once a device UID has a remembered
// selection (user choice or a prior confirmed default), that remembered
// choice always wins over the profile default — see
// `iOSAudioHardwareRouteAdapter.refresh`. Platform-neutral (Foundation
// only): no AVAudioSession/AVAudioEngine/CoreAudio/CoreMIDI, matching
// `AudioHardwareRouteState`.

import Foundation

enum DVSHardwareProfile {
    private struct Entry {
        /// Case-insensitive substring match against the reported device
        /// (port) name.
        let deviceNameContains: String
        let firstChannelIndex: Int
        let secondChannelIndex: Int
    }

    // RANE ONE MKII: existing validated RANE ONE MKII DVS captures use
    // channels 3/4 (zero-based indices 2/3), not the first available pair.
    private static let entries: [Entry] = [
        Entry(deviceNameContains: "Rane ONE MKII", firstChannelIndex: 2, secondChannelIndex: 3)
    ]

    /// The known-good default stereo pair for `deviceName`, if any. `nil`
    /// for unrecognized hardware — callers fall back to the generic
    /// "first available pair" default in that case.
    static func preferredStereoPair(forDeviceName deviceName: String?) -> AudioHardwareRouteState.StereoPair? {
        guard let deviceName, !deviceName.isEmpty else { return nil }
        guard let match = entries.first(where: {
            deviceName.localizedCaseInsensitiveContains($0.deviceNameContains)
        }) else { return nil }
        return AudioHardwareRouteState.StereoPair(
            firstChannelIndex: match.firstChannelIndex,
            secondChannelIndex: match.secondChannelIndex
        )
    }
}

/// Known-good program-audio input pairs for routine capture/export.
/// This is deliberately separate from `DVSHardwareProfile`: the RANE DVS
/// control-vinyl input is 3/4, while the audible master program return is
/// input 13/14. Mixing those roles exports control signal instead of the
/// isolated audible scratch performance.
enum RoutineCaptureAudioHardwareProfile {
    static func preferredProgramStereoPair(
        forDeviceName deviceName: String?,
        deviceUniqueID: String? = nil,
        defaults: UserDefaults = .standard
    ) -> AudioHardwareRouteState.StereoPair? {
        if let deviceUniqueID,
           let remembered = RoutineCaptureAudioRoutingSelectionStore.rememberedStereoPair(
                forDeviceUniqueID: deviceUniqueID,
                defaults: defaults
           ) {
            return remembered
        }
        guard let deviceName,
              RanePlaybackRoutingPolicy.matchesRaneRoute(portName: deviceName) else {
            return nil
        }
        return AudioHardwareRouteState.StereoPair(
            firstChannelIndex: 12,
            secondChannelIndex: 13
        )
    }
}

/// Persists the operator-selected routine-capture programme pair per Core
/// Audio device. This is deliberately separate from the DVS pair: DVS/control
/// input and audible AHHH programme audio are different routes on RANE
/// hardware and must never overwrite one another.
enum RoutineCaptureAudioRoutingSelectionStore {
    private struct StoredPair: Codable {
        let firstChannelIndex: Int
        let secondChannelIndex: Int
    }

    private static let storageKey = "scratchlab.routineCapture.programStereoPairs.v1"

    static func rememberedStereoPair(
        forDeviceUniqueID deviceUniqueID: String,
        defaults: UserDefaults = .standard
    ) -> AudioHardwareRouteState.StereoPair? {
        let normalizedID = deviceUniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              let stored = load(defaults: defaults)[normalizedID] else {
            return nil
        }
        return AudioHardwareRouteState.StereoPair(
            firstChannelIndex: stored.firstChannelIndex,
            secondChannelIndex: stored.secondChannelIndex
        )
    }

    static func remember(
        _ pair: AudioHardwareRouteState.StereoPair,
        forDeviceUniqueID deviceUniqueID: String,
        defaults: UserDefaults = .standard
    ) {
        let normalizedID = deviceUniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }

        var selections = load(defaults: defaults)
        selections[normalizedID] = StoredPair(
            firstChannelIndex: pair.firstChannelIndex,
            secondChannelIndex: pair.secondChannelIndex
        )
        guard let data = try? JSONEncoder().encode(selections) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults) -> [String: StoredPair] {
        guard let data = defaults.data(forKey: storageKey),
              let selections = try? JSONDecoder().decode([String: StoredPair].self, from: data) else {
            return [:]
        }
        return selections
    }
}

// MARK: - RANE playback output routing

/// Where ScratchLab's rendered scratch audio must land on a RANE ONE route.
///
/// **Measured hardware truth (iPhone K + RANE ONE MKII, 2026-08-29):** the
/// device exposes **10** USB output channels. USB output **1/2 is the left
/// deck** and **3/4 is the right deck** (Karl, hardware-confirmed). 13/14 is
/// the master path and must never be used for deck playback — routing there
/// bypasses the channel strip, fader, and meter.
///
/// This policy exists because the previous implementation hardcoded a
/// *guessed* 14-channel requirement and gated the whole channel map on
/// `maximumOutputNumberOfChannels >= 14`. The real device reports 10, so the
/// gate was always false, no channel map was ever installed, and playback fell
/// back to plain stereo — the device's first pair, 1/2, the **left** deck.
/// That is why two different pair constants both lit the left meter: the pair
/// index was never the operative value.
///
/// The requirement is not "14 channels"; it is "enough channels to reach the
/// right-deck pair", so the gate is derived from the pair itself.
///
/// **Independent of DVS input.** `DVSHardwareProfile` above pins the DVS
/// *capture* pair to channels 3/4. Core Audio input and output channel
/// namespaces are separate, so both using 3/4 is not a collision and neither
/// value may be derived from the other.
///
/// Platform-neutral (Foundation only) so both platforms and the tests share
/// one definition — the engine that applies it is iOS-only and therefore not
/// reachable from the macOS test target.
enum RanePlaybackRoutingPolicy {

    /// Zero-based destination index of the right deck's first channel.
    /// Destination 2/3 == physical USB output 3/4 == right deck.
    static let rightDeckPairStartIndex = 2

    /// Enough channels to reach the right-deck pair — derived, not guessed.
    static var minimumRequiredOutputChannels: Int { rightDeckPairStartIndex + 2 }

    /// Renderer source channels. 0 = L, 1 = R.
    private static let rendererLeftSourceChannel = 0
    private static let rendererRightSourceChannel = 1

    /// A destination that must receive nothing.
    static let silentDestination = -1

    static func matchesRaneRoute(portName: String) -> Bool {
        let normalized = portName.lowercased()
        return normalized.contains("rane") && normalized.contains("one")
    }

    /// Why a recognized RANE route could not be honoured. Never silently
    /// downgraded to stereo — that is what put AHHH on the left deck.
    enum RoutingFailure: Equatable, Sendable {
        case insufficientGrantedChannels(granted: Int, required: Int)
        case insufficientOutputNodeChannels(channels: Int, required: Int)
        case channelMapRejected(expectedPairStartIndex: Int, applied: [Int]?)

        var message: String {
            switch self {
            case let .insufficientGrantedChannels(granted, required):
                return "RANE playback needs \(required) output channels for the right deck but the audio session granted \(granted)."
            case let .insufficientOutputNodeChannels(channels, required):
                return "RANE playback needs \(required) output channels for the right deck but the output node exposes \(channels)."
            case let .channelMapRejected(expectedPairStartIndex, applied):
                let appliedText = applied.map { "[\($0.map(String.init).joined(separator: ","))]" } ?? "nil"
                return "RANE playback could not place audio on the right deck: channel map \(appliedText) does not put the renderer on destination \(expectedPairStartIndex)/\(expectedPairStartIndex + 1)."
            }
        }
    }

    enum Decision: Equatable, Sendable {
        /// Recognized RANE with enough channels: apply this destination map.
        case raneRightDeck(channelMap: [Int])
        /// Any non-RANE route keeps the ordinary stereo graph, unchanged.
        case ordinaryStereo
        /// Recognized RANE that cannot be honoured. Callers must surface this
        /// and refuse playback rather than land on the wrong deck.
        case unroutable(RoutingFailure)
    }

    /// The destination-indexed channel map, sized to the destination count the
    /// hardware actually reports — never a guessed count. Renderer L/R go to
    /// the right-deck pair and every other destination is silenced.
    static func channelMap(destinationChannelCount: Int) -> [Int] {
        var map = [Int](repeating: silentDestination, count: destinationChannelCount)
        map[rightDeckPairStartIndex] = rendererLeftSourceChannel
        map[rightDeckPairStartIndex + 1] = rendererRightSourceChannel
        return map
    }

    /// Whether an applied/read-back map really places the renderer on the
    /// right-deck pair. Used to verify assignment survived, not to assume it.
    static func mapPlacesRendererOnRightDeck(_ map: [Int]?) -> Bool {
        guard let map, map.count > rightDeckPairStartIndex + 1 else { return false }
        return map[rightDeckPairStartIndex] == rendererLeftSourceChannel
            && map[rightDeckPairStartIndex + 1] == rendererRightSourceChannel
    }

    /// Decides routing from what the hardware actually reported.
    ///
    /// `grantedOutputChannels` is the session's real `outputNumberOfChannels`
    /// after requesting the route's maximum; `outputNodeChannels` is what the
    /// engine's output node exposes. Both must clear the requirement — the
    /// session granting enough is not proof the node did.
    static func decide(
        portName: String,
        grantedOutputChannels: Int,
        outputNodeChannels: Int
    ) -> Decision {
        guard matchesRaneRoute(portName: portName) else { return .ordinaryStereo }

        guard grantedOutputChannels >= minimumRequiredOutputChannels else {
            return .unroutable(.insufficientGrantedChannels(
                granted: grantedOutputChannels,
                required: minimumRequiredOutputChannels
            ))
        }
        guard outputNodeChannels >= minimumRequiredOutputChannels else {
            return .unroutable(.insufficientOutputNodeChannels(
                channels: outputNodeChannels,
                required: minimumRequiredOutputChannels
            ))
        }
        return .raneRightDeck(channelMap: channelMap(destinationChannelCount: outputNodeChannels))
    }
}

/// Playback routing failed in a way the operator must be told about, rather
/// than silently played on the wrong deck.
enum IOScratchPlaybackRoutingError: Error, Equatable {
    case raneRightDeckUnavailable(RanePlaybackRoutingPolicy.RoutingFailure)

    var userMessage: String {
        switch self {
        case let .raneRightDeckUnavailable(failure):
            return "\(failure.message) ScratchLab did not play the sample rather than send it to the left deck."
        }
    }
}

extension IOScratchPlaybackRoutingError: LocalizedError {
    var errorDescription: String? { userMessage }
}
