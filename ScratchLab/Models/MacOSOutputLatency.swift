//  MacOSOutputLatency.swift
//  ScratchLab — macOS audio output latency query for the demo clock.
//
//  Pure compute helper + a Core Audio query that returns the current
//  default-output-device's latency in seconds. Used to populate
//  `ScratchCoachDemoAudioPlayer.currentOutputLatency()` on the
//  `#else` branch (macOS / Mac Catalyst) so `DemoAudioClock` can
//  pull the notation playhead back to match the audio the listener
//  actually hears.
//
//  Scope: demo/replay clock only. Live capture (mic / line-in /
//  Serato / TV background audio) uses a different code path and is
//  intentionally unaffected by this fix.
//
//  iOS continues to read `AVAudioSession.outputLatency` and is not
//  routed through this helper.

import Foundation

#if !canImport(UIKit)
import CoreAudio
#endif

// MARK: - MacOSOutputLatency

enum MacOSOutputLatency {

    /// Conservative fallback used when the Core Audio query fails or
    /// returns non-finite / out-of-range values. Sized to be small
    /// enough that it never overcorrects on built-in speakers
    /// (where real latency is ~10–25 ms) and large enough to apply
    /// *some* compensation when the query is unavailable. 20 ms.
    static let fallback: TimeInterval = 0.020

    /// Pure mapping from raw Core Audio readings to seconds. Total
    /// output latency = (device latency frames + buffer frame size)
    /// / sample rate. Returns `fallback` for any non-finite or
    /// non-positive sample rate so the caller is never given NaN /
    /// Infinity. Testable without any real Core Audio access.
    static func compute(
        deviceLatencyFrames: UInt32,
        bufferFrameSize: UInt32,
        sampleRate: Double
    ) -> TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0 else { return fallback }
        let totalFrames = Double(deviceLatencyFrames) + Double(bufferFrameSize)
        let seconds = totalFrames / sampleRate
        guard seconds.isFinite, seconds >= 0 else { return fallback }
        return seconds
    }

    /// Queries the default output device and returns its latency in
    /// seconds. Falls back to `fallback` on any Core Audio error so
    /// the calling site is never given NaN / Infinity.
    ///
    /// On iOS this function is unreachable (the caller is platform-
    /// gated by `#if canImport(UIKit)`) — the iOS path returns
    /// `AVAudioSession.outputLatency` directly. The function is
    /// defined for both platforms so the type compiles into the
    /// iOS target; the body is `fallback` on iOS.
    static func query() -> TimeInterval {
        #if !canImport(UIKit)
        return queryDefaultOutputDeviceLatency()
        #else
        return fallback
        #endif
    }

    #if !canImport(UIKit)
    /// Walks the four required Core Audio properties and assembles
    /// the result. Any property access error → fallback. Kept
    /// `nonisolated` so it can run from background contexts (the
    /// caller may be the audio-render thread).
    private static func queryDefaultOutputDeviceLatency() -> TimeInterval {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceErr = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0, nil,
            &deviceIDSize,
            &deviceID
        )
        guard deviceErr == noErr, deviceID != AudioDeviceID(0) else {
            return fallback
        }

        var deviceLatencyFrames = UInt32(0)
        if !readUInt32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyLatency,
            scope: kAudioDevicePropertyScopeOutput,
            into: &deviceLatencyFrames
        ) {
            return fallback
        }

        var bufferFrames = UInt32(0)
        if !readUInt32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioDevicePropertyScopeOutput,
            into: &bufferFrames
        ) {
            return fallback
        }

        var sampleRate = Double(0)
        var sampleRateSize = UInt32(MemoryLayout<Double>.size)
        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let sampleRateErr = AudioObjectGetPropertyData(
            deviceID,
            &sampleRateAddress,
            0, nil,
            &sampleRateSize,
            &sampleRate
        )
        guard sampleRateErr == noErr else { return fallback }

        return compute(
            deviceLatencyFrames: deviceLatencyFrames,
            bufferFrameSize: bufferFrames,
            sampleRate: sampleRate
        )
    }

    private static func readUInt32Property(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        into value: inout UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0, nil,
            &size,
            &value
        )
        return err == noErr
    }
    #endif
}

// MARK: - TODO: user calibration offset
//
// If the Core Audio query under-reports latency on routes that go
// through Bluetooth / AirPlay / aggregate devices (which sometimes
// happens because those routes interpose buffer stages the query
// can't see), a future slice can layer a user-controlled calibration
// offset on top of this value. The hook would live on the calling
// side (`ScratchCoachDemoAudioPlayer.currentOutputLatency()`) — read
// a `UserDefaults` value and add it after this query returns. The
// helper itself stays a pure Core Audio reading and does not own
// user calibration.
