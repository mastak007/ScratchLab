import Foundation

// MARK: - TimecodeControlPreset

/// Available timecode control presets for the prototype pipeline.
///
/// Each preset corresponds to a pre-configured `TimecodePrototypeProfile`
/// with safe defaults. The `.manual` preset exposes all calibration fields
/// for direct adjustment.
///
/// **Batch 10:** Prototype profile hardening.
public enum TimecodeControlPreset: String, Equatable, Sendable, CaseIterable {

    /// ScratchLab prototype defaults — conservative, safe for internal testing.
    case scratchLabPrototype

    /// Generic DVS control signal at standard carrier frequency.
    /// Experimental only — not a compatibility claim.
    case genericDVS

    /// Validated hardware profile for testing against a physical Rane ONE
    /// MKII over its USB DVS input. Fixes the values confirmed against real
    /// hardware across many hardware sessions: Invert direction ON, Min
    /// confidence 0.10, and (applied separately by the caller — see
    /// `TimecodeControlCard`, which has the `ENABLE_TIMECODE_LIVE_TAP`
    /// availability this profile itself does not depend on) the USB channel
    /// pair explicitly pinned to physical pair 3/4 instead of Auto, so pair
    /// auto-selection instability during a stop/reversal (Auto losing
    /// carrier and defaulting away from an already-validated pair) cannot
    /// affect a DEBUG hardware test.
    ///
    /// **Invert direction ON is correct and final, not a stale intermediate
    /// value.** Immediately after Karl physically corrected reversed RCA
    /// wiring, the measured raw phase convention briefly suggested Invert
    /// should be OFF. That was superseded once a real internal
    /// sign-convention mismatch was found between the live diagnostic
    /// classifier (`TimecodeSignalDiagnostics.estimatePhaseOffset`) and the
    /// actual decoder (`TimecodePhaseDecoder.extractPhaseDelta`) — opposite
    /// signs for the same physical quantity. Every hardware session since
    /// has confirmed Invert ON produces correct audible forward playback;
    /// audible motion is ground truth here, not either diagnostic's raw
    /// phase-sign label. Do not "fix" this back to OFF without new,
    /// audibly-confirmed hardware evidence.
    case raneOneMkiiDebug

    /// Manual calibration — all fields user-adjustable.
    case manual

    // MARK: - Labels

    /// User-facing label for the preset picker.
    public var label: String {
        switch self {
        case .scratchLabPrototype:  return "ScratchLab Prototype"
        case .genericDVS:           return "Generic DVS Control Signal"
        case .raneOneMkiiDebug:     return "Rane ONE MKII (DEBUG, pair 3/4 pinned)"
        case .manual:               return "Manual"
        }
    }

    /// Short label for status displays.
    public var shortLabel: String {
        switch self {
        case .scratchLabPrototype:  return "ScratchLab"
        case .genericDVS:           return "DVS"
        case .raneOneMkiiDebug:     return "Rane"
        case .manual:               return "Manual"
        }
    }

    /// Whether this preset is experimental (not a compatibility claim).
    public var isExperimental: Bool {
        switch self {
        case .genericDVS:  return true
        default:           return false
        }
    }

    /// Experimental warning for DVS preset.
    public var experimentalWarning: String? {
        switch self {
        case .genericDVS:
            return "Experimental — not Serato/SDJ certified or compatible"
        default:
            return nil
        }
    }

    /// Physical hardware setup reminder shown in the preset UI — the parts
    /// of a validated hardware configuration a Swift preset's values can't
    /// capture on their own (which physical USB pair to use, how to read an
    /// apparent forward/backward mismatch). Keeps the full setup
    /// reproducible from the app alone, without re-deriving it from
    /// scattered hardware-session history.
    public var setupNote: String? {
        switch self {
        case .raneOneMkiiDebug:
            return "Rane ONE MKII: USB DVS input, physical pair 3/4 (pinned automatically). " +
                "If forward/backward ever sounds swapped, trust what you hear — " +
                "do not force Invert off to match a raw decoder label."
        default:
            return nil
        }
    }

    // MARK: - Default

    public static let `default`: TimecodeControlPreset = .scratchLabPrototype
}

// MARK: - TimecodeSmoothingConfig

/// Smoothing configuration values referenced by a profile.
///
/// These values are consumed by `TimecodeMotionStabilityFilter` when the
/// profile is applied to the pipeline.
public struct TimecodeSmoothingConfig: Equatable, Sendable {

    /// EMA alpha for rate smoothing (0–1). Higher = faster response,
    /// lower = smoother.
    public let emaAlpha: Double

    /// Maximum allowed rate step between consecutive frames before the
    /// frame is rejected as a spike (position-units per second).
    public let spikeRejectionThreshold: Double

    /// Maximum consecutive frames that can be masked during a short dropout
    /// before the EMA resets (the short-hold window).
    public let shortDropoutMask: Int

    /// Minimum frames required after EMA reset before output is trusted again.
    public let trustRebuildFrames: Int

    public init(
        emaAlpha: Double = 0.15,
        spikeRejectionThreshold: Double = 20.0,
        shortDropoutMask: Int = 2,
        trustRebuildFrames: Int = 3
    ) {
        self.emaAlpha = emaAlpha
        self.spikeRejectionThreshold = spikeRejectionThreshold
        self.shortDropoutMask = shortDropoutMask
        self.trustRebuildFrames = trustRebuildFrames
    }

    /// Conservative smoothing used by ScratchLab Prototype preset.
    public static let conservative = TimecodeSmoothingConfig(
        emaAlpha: 0.12,
        spikeRejectionThreshold: 15.0,
        shortDropoutMask: 3,
        trustRebuildFrames: 4
    )

    /// Standard smoothing used by Generic DVS preset.
    public static let standard = TimecodeSmoothingConfig(
        emaAlpha: 0.18,
        spikeRejectionThreshold: 25.0,
        shortDropoutMask: 2,
        trustRebuildFrames: 3
    )
}

// MARK: - TimecodePrototypeProfile

/// A calibration + safety profile for the timecode prototype pipeline.
///
/// Each profile bundles all adjustable calibration fields, smoothing config,
/// and safety gates into a single value that can be applied atomically to a
/// `TimecodeControlPipeline`.
///
/// Profiles are created via static factory methods keyed by
/// `TimecodeControlPreset` so the UI can bind to a preset enum and resolve
/// the full profile on demand.
///
/// **Batch 10:** Prototype profile hardening.
/// Does NOT represent Serato, SDJ, or any commercial compatibility.
public struct TimecodePrototypeProfile: Equatable, Sendable {

    // MARK: - Identity

    /// The preset this profile was built from.
    public let preset: TimecodeControlPreset

    /// User-facing name for this profile.
    public let name: String

    // MARK: - Calibration

    /// Which input channel(s) to use.
    public let inputChannel: TimecodeInputChannel

    /// When true, the sign of all position deltas is flipped.
    public let invertDirection: Bool

    /// Multiplier applied to position deltas and velocities.
    /// 1.0 = no scaling.
    public let rateScale: Double

    /// Minimum confidence for a decoded frame to be accepted.
    public let minConfidence: Double

    /// Maximum absolute velocity in position-units per second.
    /// Velocities exceeding this are clamped.
    public let maxRate: Double

    // MARK: - Smoothing

    /// Smoothing configuration referenced by this profile.
    public let smoothingConfig: TimecodeSmoothingConfig

    // MARK: - Safety gates

    /// When true, the playback bridge is blocked until validation passes
    /// or the user explicitly overrides.
    public let validationRequired: Bool

    /// When true, the playback bridge is allowed to produce output once
    /// all other gates pass.
    public let playbackBridgeAllowed: Bool

    // MARK: - Init

    public init(
        preset: TimecodeControlPreset,
        name: String,
        inputChannel: TimecodeInputChannel = .stereo,
        invertDirection: Bool = false,
        rateScale: Double = 1.0,
        minConfidence: Double = 0.3,
        maxRate: Double = 5.0,
        smoothingConfig: TimecodeSmoothingConfig = .conservative,
        validationRequired: Bool = true,
        playbackBridgeAllowed: Bool = false
    ) {
        self.preset = preset
        self.name = name
        self.inputChannel = inputChannel
        self.invertDirection = invertDirection
        self.rateScale = rateScale
        self.minConfidence = minConfidence
        self.maxRate = maxRate
        self.smoothingConfig = smoothingConfig
        self.validationRequired = validationRequired
        self.playbackBridgeAllowed = playbackBridgeAllowed
    }

    // MARK: - Static factories

    /// ScratchLab Prototype profile — conservative defaults for internal
    /// prototype testing.
    ///
    /// - Stereo input
    /// - No direction inversion
    /// - 1.0× rate scale
    /// - 0.3 min confidence
    /// - 5.0 u/s max rate
    /// - Conservative smoothing
    /// - Validation required before playback bridge
    /// - Playback bridge NOT allowed by default
    public static func scratchLabPrototype() -> TimecodePrototypeProfile {
        TimecodePrototypeProfile(
            preset: .scratchLabPrototype,
            name: "ScratchLab Prototype",
            inputChannel: .stereo,
            invertDirection: false,
            rateScale: 1.0,
            minConfidence: 0.3,
            maxRate: 5.0,
            smoothingConfig: .conservative,
            validationRequired: true,
            playbackBridgeAllowed: false
        )
    }

    /// Generic DVS control signal profile — experimental only.
    ///
    /// - Stereo input
    /// - No direction inversion
    /// - 1.0× rate scale
    /// - 0.25 min confidence
    /// - 8.0 u/s max rate
    /// - Standard smoothing
    /// - Validation required before playback bridge
    /// - Playback bridge NOT allowed by default
    ///
    /// **Experimental — not a Serato/SDJ compatibility claim.**
    public static func genericDVS() -> TimecodePrototypeProfile {
        TimecodePrototypeProfile(
            preset: .genericDVS,
            name: "Generic DVS Control Signal",
            inputChannel: .stereo,
            invertDirection: false,
            rateScale: 1.0,
            minConfidence: 0.25,
            maxRate: 8.0,
            smoothingConfig: .standard,
            validationRequired: true,
            playbackBridgeAllowed: false
        )
    }

    /// Rane ONE MKII DEBUG hardware profile — validated against real
    /// hardware this session.
    ///
    /// - Stereo input
    /// - Invert direction ON (confirmed: audible forward playback matches
    ///   Invert ON on this hardware — treat audible motion as ground truth,
    ///   not the raw decoder's phase-sign label)
    /// - 1.0× rate scale
    /// - 0.10 min confidence
    /// - 5.0 u/s max rate
    /// - Conservative smoothing
    /// - Validation required before playback bridge
    /// - Playback bridge NOT allowed by default
    ///
    /// Does NOT itself pin the USB channel pair — `TimecodeCMSampleBuffer
    /// Adapter` (the DEBUG live-tap channel router) is gated by
    /// `ENABLE_TIMECODE_LIVE_TAP`, an availability this cross-platform model
    /// file does not assume. The caller applying this profile in a build
    /// that has that capability (see `TimecodeControlCard.applyPreset`)
    /// pins physical pair 3/4 explicitly instead of Auto.
    public static func raneOneMkiiDebug() -> TimecodePrototypeProfile {
        TimecodePrototypeProfile(
            preset: .raneOneMkiiDebug,
            name: "Rane ONE MKII (DEBUG)",
            inputChannel: .stereo,
            invertDirection: true,
            rateScale: 1.0,
            minConfidence: 0.10,
            maxRate: 5.0,
            smoothingConfig: .conservative,
            validationRequired: true,
            playbackBridgeAllowed: false
        )
    }

    /// Manual profile — all fields user-adjustable.
    ///
    /// Starts from conservative defaults; the user is expected to tune
    /// each field individually via the calibration UI.
    public static func manual(
        inputChannel: TimecodeInputChannel = .stereo,
        invertDirection: Bool = false,
        rateScale: Double = 1.0,
        minConfidence: Double = 0.3,
        maxRate: Double = 5.0,
        smoothingConfig: TimecodeSmoothingConfig = .conservative
    ) -> TimecodePrototypeProfile {
        TimecodePrototypeProfile(
            preset: .manual,
            name: "Manual",
            inputChannel: inputChannel,
            invertDirection: invertDirection,
            rateScale: rateScale,
            minConfidence: minConfidence,
            maxRate: maxRate,
            smoothingConfig: smoothingConfig,
            validationRequired: false,
            playbackBridgeAllowed: false
        )
    }

    /// Resolve the profile for a given preset, using current pipeline
    /// calibration values when the manual preset is selected.
    public static func make(
        preset: TimecodeControlPreset,
        pipeline: TimecodeControlPipeline
    ) -> TimecodePrototypeProfile {
        switch preset {
        case .scratchLabPrototype:
            return .scratchLabPrototype()
        case .genericDVS:
            return .genericDVS()
        case .raneOneMkiiDebug:
            return .raneOneMkiiDebug()
        case .manual:
            return .manual(
                inputChannel: pipeline.inputChannel,
                invertDirection: pipeline.invertDirection,
                rateScale: pipeline.rateScale,
                minConfidence: pipeline.minConfidence,
                maxRate: pipeline.maxRate
            )
        }
    }
}

// MARK: - TimecodeDVSProfile

/// A marker type for the Generic DVS control signal preset.
///
/// Provides DVS-specific defaults and an explicit experimental label so
/// consumers cannot accidentally claim compatibility.
///
/// ## Experimental only
///
/// This profile targets the standard 1 kHz timecode carrier used by
/// many DVS systems for **experimental prototype testing only**.
/// It is NOT a Serato, SDJ, or commercial DVS compatibility claim.
///
/// **Batch 10:** Prototype profile hardening.
public struct TimecodeDVSProfile: Equatable, Sendable {

    /// The underlying prototype profile.
    public let profile: TimecodePrototypeProfile

    /// Always `true` — the DVS profile is experimental and not a
    /// compatibility claim.
    public let isExperimental: Bool = true

    /// Explicit experimental label.
    public let experimentalLabel: String = "Experimental — not Serato/SDJ certified or compatible"

    // MARK: - Init

    public init(profile: TimecodePrototypeProfile = .genericDVS()) {
        self.profile = profile
    }

    /// The default DVS profile (Generic DVS Control Signal).
    public static let `default` = TimecodeDVSProfile()
}

// MARK: - Profile application

extension TimecodePrototypeProfile {

    /// Apply this profile's calibration values to a pipeline.
    ///
    /// Sets input channel, invert direction, rate scale, min confidence,
    /// and max rate atomically, via `TimecodeControlPipeline.
    /// applyCalibrationBatch(_:...)` — a single configuration swap, not
    /// five sequential property writes. Does NOT change the pipeline mode
    /// or live tap state.
    ///
    /// - Parameter pipeline: The pipeline to configure.
    public func apply(to pipeline: TimecodeControlPipeline) {
        pipeline.applyCalibrationBatch(
            inputChannel: inputChannel,
            invertDirection: invertDirection,
            rateScale: rateScale,
            minConfidence: minConfidence,
            maxRate: maxRate
        )
    }
}
