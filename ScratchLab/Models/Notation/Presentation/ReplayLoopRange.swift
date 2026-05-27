import Foundation

// MARK: - ReplayLoopRange

/// A validated finite range used by `StudioReplayScrubber` to bound a
/// looped playback span. Pure value type — no clock, no UI, no
/// AVFoundation.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `startTime`, `endTime` are finite.
/// - `endTime > startTime`.
struct ReplayLoopRange: Equatable, Sendable, Codable {
    let startTime: TimeInterval
    let endTime: TimeInterval

    init?(startTime: TimeInterval, endTime: TimeInterval) {
        guard ReplayLoopRange.isValid(startTime: startTime, endTime: endTime) else { return nil }
        self.startTime = startTime
        self.endTime = endTime
    }

    /// Duration of the looped span. Always positive — the init guards
    /// `endTime > startTime`.
    var duration: TimeInterval { endTime - startTime }

    /// Clamps a `time` into the range. Used by the scrubber to wrap a
    /// playhead crossing back to the loop start.
    func clamp(_ time: TimeInterval) -> TimeInterval {
        if !time.isFinite { return startTime }
        return min(max(time, startTime), endTime)
    }

    /// Returns the next playhead position after `time` advances by
    /// `delta`. Wraps to `startTime` when the playhead would cross
    /// `endTime`, so the scrubber loops the span deterministically.
    func advance(from time: TimeInterval, by delta: TimeInterval) -> TimeInterval {
        guard delta.isFinite, delta >= 0 else { return clamp(time) }
        guard duration > 0 else { return startTime }
        let clamped = clamp(time)
        let candidate = clamped + delta
        if candidate < endTime { return candidate }
        // Wrap into the range. `truncatingRemainder` keeps the wrap
        // deterministic even when delta exceeds the span length.
        let overflow = (candidate - startTime).truncatingRemainder(dividingBy: duration)
        return startTime + overflow
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case startTime, endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        let endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        guard ReplayLoopRange.isValid(startTime: startTime, endTime: endTime) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime,
                in: container,
                debugDescription: "ReplayLoopRange requires finite startTime and endTime with endTime > startTime"
            )
        }
        self.startTime = startTime
        self.endTime = endTime
    }

    private static func isValid(startTime: TimeInterval, endTime: TimeInterval) -> Bool {
        guard startTime.isFinite, endTime.isFinite else { return false }
        return endTime > startTime
    }
}

// MARK: - ReplayPlaybackRate

/// The discrete visual playback rates the scrubber supports.
///
/// **Audio rate stays 1.0×** at every setting — the scrubber is a
/// visual-inspection tool only and never time-stretches audio.
enum ReplayPlaybackRate: Double, Equatable, CaseIterable, Sendable, Codable {
    case quarter  = 0.25
    case half     = 0.5
    case threeQuarter = 0.75
    case normal   = 1.0

    var label: String {
        switch self {
        case .quarter:        return "0.25×"
        case .half:           return "0.5×"
        case .threeQuarter:   return "0.75×"
        case .normal:         return "1×"
        }
    }
}
