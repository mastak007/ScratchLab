import Foundation

// MARK: - NotationViewportWindowRule

/// Configuration for picking a fixed-duration viewport window around
/// a moving playhead time.
///
/// - `duration` is the target viewport duration. Always honoured when
///   the content is long enough to fit it; otherwise the viewport
///   spans the full content.
/// - `leadIn` is how much of the viewport sits *before* the
///   playhead. The playhead lands at `viewport.startTime + leadIn`
///   when the content is large enough to permit it. `leadIn` may be
///   zero (playhead at the left edge).
///
/// **Invariants enforced at construction and decode time:**
///
/// - `duration` is finite and `> 0`.
/// - `leadIn` is finite and `>= 0`.
///
/// The rule does not enforce `leadIn <= duration` — callers can
/// choose to peek backward by more than the viewport width if that
/// makes sense in their context; the mapper still clamps to content.
struct NotationViewportWindowRule: Equatable, Sendable, Codable {
    let duration: TimeInterval
    let leadIn: TimeInterval

    init?(duration: TimeInterval, leadIn: TimeInterval) {
        guard NotationViewportWindowRule.isValid(duration: duration, leadIn: leadIn) else {
            return nil
        }
        self.duration = duration
        self.leadIn = leadIn
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case duration, leadIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try container.decode(TimeInterval.self, forKey: .duration)
        let leadIn = try container.decode(TimeInterval.self, forKey: .leadIn)
        guard NotationViewportWindowRule.isValid(duration: duration, leadIn: leadIn) else {
            throw DecodingError.dataCorruptedError(
                forKey: .duration,
                in: container,
                debugDescription: "viewport-window rule requires finite duration > 0 and finite leadIn ≥ 0"
            )
        }
        self.duration = duration
        self.leadIn = leadIn
    }

    private static func isValid(duration: TimeInterval, leadIn: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        guard leadIn.isFinite, leadIn >= 0 else { return false }
        return true
    }
}

// MARK: - NotationViewportWindowMapper

/// Pure, deterministic factory that picks a `NotationLaneViewport`
/// of `rule.duration` around a given playhead `time`, clamped to
/// `[contentStart, contentEnd]`.
///
/// **What the mapper does (and only this):**
///
/// - Validates all numeric inputs are finite, `contentEnd ≥
///   contentStart`, `width > 0`, and `height > 0`. Returns `nil`
///   otherwise.
/// - Returns `nil` when `contentStart == contentEnd` (no positive
///   span available, and `NotationLaneViewport` requires `endTime >
///   startTime`).
/// - If `contentEnd - contentStart < rule.duration`, returns a
///   viewport that spans the entire content.
/// - Otherwise computes `desiredStart = time - rule.leadIn`,
///   `desiredEnd = desiredStart + rule.duration`, then shifts the
///   pair (keeping its fixed duration) to lie inside
///   `[contentStart, contentEnd]`.
///
/// **What the mapper does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no mutation of inputs.
enum NotationViewportWindowMapper {

    static func viewport(
        around time: TimeInterval,
        contentStart: TimeInterval,
        contentEnd: TimeInterval,
        width: Double,
        height: Double,
        rule: NotationViewportWindowRule
    ) -> NotationLaneViewport? {
        guard time.isFinite,
              contentStart.isFinite,
              contentEnd.isFinite,
              width.isFinite,
              height.isFinite else { return nil }
        guard contentEnd >= contentStart else { return nil }
        guard width > 0, height > 0 else { return nil }
        // NotationLaneViewport requires endTime > startTime, so a
        // zero-width content range can't yield a valid viewport.
        guard contentEnd > contentStart else { return nil }

        let contentDuration = contentEnd - contentStart
        let startTime: TimeInterval
        let endTime: TimeInterval
        if contentDuration < rule.duration {
            startTime = contentStart
            endTime = contentEnd
        } else {
            let desiredStart = time - rule.leadIn
            let desiredEnd = desiredStart + rule.duration
            if desiredStart < contentStart {
                startTime = contentStart
                endTime = contentStart + rule.duration
            } else if desiredEnd > contentEnd {
                endTime = contentEnd
                startTime = contentEnd - rule.duration
            } else {
                startTime = desiredStart
                endTime = desiredEnd
            }
        }
        return NotationLaneViewport(
            startTime: startTime,
            endTime: endTime,
            width: width,
            height: height
        )
    }
}
