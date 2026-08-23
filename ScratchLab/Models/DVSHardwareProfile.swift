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
