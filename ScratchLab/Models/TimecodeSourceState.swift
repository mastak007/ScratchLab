import Foundation

// MARK: - TimecodeSourceState

/// Models the selection state of a timecode audio input source.
///
/// **Batch 1:** Selection model only. No live audio routing. The `.active`
/// state is wired only when a `TimecodeInputTap` has been explicitly started
/// (currently DEBUG-gated).
public enum TimecodeSourceState: Equatable, Sendable {
    /// No timecode source is selected or configured.
    case inactive

    /// A timecode source has been selected but is not yet receiving buffers.
    case selected(name: String)

    /// A timecode source is actively delivering audio buffers.
    case active(name: String, sampleRate: Double, channelCount: Int)

    /// The selected source encountered an error.
    case error(name: String, description: String)

    // MARK: - Convenience

    /// Human-readable label for UI display.
    public var displayLabel: String {
        switch self {
        case .inactive:
            return "Inactive"
        case .selected(let name):
            return name
        case .active(let name, _, _):
            return name
        case .error(let name, _):
            return name
        }
    }

    /// Whether the source is currently delivering buffers.
    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// Format summary string for debug display.
    public var formatSummary: String? {
        switch self {
        case .active(_, let sampleRate, let channelCount):
            let rateStr = String(format: "%.1f kHz", sampleRate / 1000)
            return "\(rateStr) · \(channelCount)ch"
        case .inactive, .selected, .error:
            return nil
        }
    }
}
