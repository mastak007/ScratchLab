import Foundation

// MARK: - TimecodeControlMode

/// Prototype timecode control mode for the Batch 3 pipeline.
///
/// Controls whether the timecode input path is inactive, runs diagnostics
/// only, or runs the full prototype decode→adapter chain and publishes
/// platter motion.
///
/// **Batch 3:** Control pipeline only. No live AVCapture wiring. No
/// notation/capture pipeline injection. Default is `.disabled` — timecode
/// must never silently hijack audio or motion input.
public enum TimecodeControlMode: String, Equatable, Sendable, CaseIterable {

    /// Timecode input is disabled. No diagnostics, no decoder, no motion.
    case disabled

    /// Run signal diagnostics only (RMS, peak, health, warnings).
    /// Publishes health and counters but does NOT run the decoder or emit
    /// any platter motion output.
    case diagnosticsOnly

    /// Run the full prototype pipeline: diagnostics → decoder → adapter.
    /// Publishes a `PlatterPositionTimeline?` with `.timecodeLive` source
    /// for trusted decoded motion. Bad signal fails closed.
    ///
    /// Label: "Timecode Prototype" — not "live-ready."
    case controlPrototype

    // MARK: - Labels

    /// User-facing label for the mode picker.
    public var label: String {
        switch self {
        case .disabled:          return "Disabled"
        case .diagnosticsOnly:   return "Diagnostics Only"
        case .controlPrototype:  return "Timecode Prototype"
        }
    }

    /// Short label for status displays.
    public var shortLabel: String {
        switch self {
        case .disabled:          return "Off"
        case .diagnosticsOnly:   return "Diag"
        case .controlPrototype:  return "Proto"
        }
    }

    // MARK: - Default

    /// The default timecode control mode is `.disabled`.
    public static let `default`: TimecodeControlMode = .disabled
}

// MARK: - TimecodeInputChannel

/// Which channel(s) of a stereo timecode input to use for decoding.
public enum TimecodeInputChannel: String, Equatable, Sendable, CaseIterable {
    /// Use the left channel only.
    case left

    /// Use the right channel only.
    case right

    /// Use both channels (stereo). Required for quadrature phase extraction.
    case stereo

    public var label: String {
        switch self {
        case .left:   return "Left"
        case .right:  return "Right"
        case .stereo: return "Stereo"
        }
    }
}
