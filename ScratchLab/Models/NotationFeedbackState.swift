import Foundation
import SwiftUI

/// Coarse live-performance feedback state for the notation overlay.
///
/// Derived from `ScratchAnalysisResult` accuracy and timing signals only.
/// Direction mismatch is not yet detectable from the current analysis pipeline;
/// `.wrongDirection` is reserved for a future signal and is never returned by
/// `from(result:)` today.
enum NotationFeedbackState: Equatable, Sendable {
    /// No event — base notation only, no overlay effect.
    case neutral
    /// Near-hit (accuracy 50–69) — soft glow, short fade.
    case close
    /// Good hit (accuracy ≥ 70) — electric edge highlight + short pulse.
    case correct
    /// Excellent hit (accuracy ≥ 90 and on-beat) — strong glow + brief spark.
    case excellent
    /// Detected but timed too early — timing correction marker, no reward.
    case early
    /// Detected but timed too late — timing correction marker, no reward.
    case late
    /// Wrong platter direction — reserved; not yet wired to a live signal.
    case wrongDirection
    /// Expected stroke not matched — subdued marker, no spark.
    case missed
}

extension NotationFeedbackState {

    // Thresholds kept as statics so tests can verify boundary conditions
    // without repeating magic numbers.
    static let excellentAccuracyThreshold: Double = 90
    static let correctAccuracyThreshold: Double = 70
    static let closeAccuracyThreshold: Double = 50
    /// Positive ms offset beyond which a low-accuracy result is classed `.late`.
    static let lateOffsetThresholdMs: Double = 50
    /// Negative ms offset beyond which a low-accuracy result is classed `.early`.
    static let earlyOffsetThresholdMs: Double = -50

    /// Map raw analysis scalars to a feedback state.
    ///
    /// Accuracy and beat-offset are the only signals today. Direction is not
    /// comparable — `.wrongDirection` is never returned from this factory.
    ///
    /// - Parameters:
    ///   - accuracy: Scratch accuracy in [0, 100].
    ///   - isOnBeat: Whether the detected scratch aligns with the beat grid.
    ///   - beatOffset: Beat phase offset in milliseconds (negative = early).
    static func from(
        accuracy: Double,
        isOnBeat: Bool,
        beatOffset: Double
    ) -> NotationFeedbackState {
        if accuracy >= excellentAccuracyThreshold && isOnBeat { return .excellent }
        if accuracy >= correctAccuracyThreshold { return .correct }
        if accuracy >= closeAccuracyThreshold { return .close }
        if !isOnBeat && beatOffset < earlyOffsetThresholdMs { return .early }
        if !isOnBeat && beatOffset > lateOffsetThresholdMs { return .late }
        return .missed
    }

    /// True for states that carry a positive reward cue.
    var isReward: Bool { self == .correct || self == .excellent }

    /// True for states that show a timing-correction marker.
    var isTimingCorrection: Bool { self == .early || self == .late }

    /// Returns one concise, beginner-friendly coaching message derived from the
    /// same accuracy/timing signals already produced by the detection pipeline.
    ///
    /// No per-primitive or motion-phase inference is made — the message uses only
    /// accuracy, on-beat status, and beat-offset. No early/late/reversal/primitive
    /// claims about motion phase are made — "early" and "late" refer strictly to
    /// timing relative to the beat grid (beatOffset).
    ///
    /// Precedence (highest to lowest):
    /// 1. Clearly early (beatOffset < earlyOffsetThresholdMs).
    /// 2. Clearly late (beatOffset > lateOffsetThresholdMs).
    /// 3. Excellent accuracy + on beat (no timing correction needed).
    /// 4. On-beat accuracy feedback.
    /// 5. Off-beat feedback when offset is neutral or invalid.
    /// 6. Low-accuracy fallback.
    ///
    /// Timing correction (early/late) takes precedence over praise/accuracy
    /// because beatOffset is a direct measurement — when it exceeds the
    /// threshold the user needs timing advice regardless of scratch quality.
    ///
    /// - Parameters:
    ///   - accuracy: Scratch accuracy in [0, 100].
    ///   - isOnBeat: Whether the detected scratch aligns with the beat grid.
    ///   - beatOffset: Beat phase offset in milliseconds (negative = early).
    /// - Returns: A single coaching message, or `nil` when signals are
    ///   insufficient to produce advice.
    static func coachingMessage(
        accuracy: Double,
        isOnBeat: Bool,
        beatOffset: Double
    ) -> String? {
        let offsetIsValid = beatOffset.isFinite

        // 1. Clearly early — beat offset threshold has precedence over accuracy
        //    and isOnBeat because beatOffset is a direct measurement.
        if offsetIsValid && beatOffset < earlyOffsetThresholdMs {
            return "You were slightly early. Let the beat arrive before starting the motion."
        }

        // 2. Clearly late.
        if offsetIsValid && beatOffset > lateOffsetThresholdMs {
            return "You were slightly late. Begin the motion a little sooner."
        }

        // 3. Excellent accuracy and on beat (offset is within neutral range
        //    since early/late checks above already passed).
        if accuracy >= excellentAccuracyThreshold && isOnBeat {
            return "Good timing and a clean match."
        }

        // 4. On-beat feedback based on accuracy.
        if isOnBeat {
            if accuracy >= correctAccuracyThreshold {
                return "Your timing was good. Repeat the motion more consistently."
            }
            if accuracy >= closeAccuracyThreshold {
                return "You're getting close. Keep the motion smooth and consistent."
            }
            // Falls through to low-accuracy fallback.
        }

        // 5. Generic off-beat feedback — only when offset is invalid or within
        //    the neutral threshold range (meaning the timing signal doesn't
        //    clearly indicate early or late).
        if !isOnBeat && (!offsetIsValid ||
            (beatOffset >= earlyOffsetThresholdMs && beatOffset <= lateOffsetThresholdMs)) {
            if accuracy >= correctAccuracyThreshold {
                return "Good motion. Focus on landing with the beat."
            }
            if accuracy >= closeAccuracyThreshold {
                return "Nearly there. Try to stay in time with the beat."
            }
            // Falls through to low-accuracy fallback.
        }

        // 6. Low-accuracy fallback.
        return "Slow it down and focus on one smooth forward-and-back motion."
    }

    /// How quickly the effect decays, in seconds. Independent of render settings
    /// so callers can schedule a reset without holding a style reference.
    var decayDuration: TimeInterval {
        switch self {
        case .neutral:       return 0
        case .close, .missed: return 0.25
        case .correct:       return 0.30
        case .excellent, .wrongDirection: return 0.35
        case .early, .late:  return 0.40
        }
    }
}

// MARK: - Feedback Style

/// Resolved visual parameters for a `NotationFeedbackState`.
///
/// Computed once per state-change and passed to `NotationFeedbackOverlay`
/// so the overlay never needs to re-derive constants at render time.
struct NotationFeedbackStyle {
    let glowColor: Color?
    let glowRadius: CGFloat
    let glowOpacity: Double
    let hasSpark: Bool
    let hasPulse: Bool
    let timingMarkerColor: Color?
    let decayDuration: TimeInterval

    static func style(for state: NotationFeedbackState, reduceMotion: Bool) -> NotationFeedbackStyle {
        switch state {
        case .neutral:
            return NotationFeedbackStyle(glowColor: nil, glowRadius: 0, glowOpacity: 0,
                                         hasSpark: false, hasPulse: false,
                                         timingMarkerColor: nil, decayDuration: 0)
        case .close:
            return NotationFeedbackStyle(
                glowColor: Color(red: 0.20, green: 0.88, blue: 0.55),
                glowRadius: 6, glowOpacity: 0.28,
                hasSpark: false, hasPulse: false,
                timingMarkerColor: nil, decayDuration: 0.25)
        case .correct:
            return NotationFeedbackStyle(
                glowColor: Color(red: 0.20, green: 0.88, blue: 0.55),
                glowRadius: 10, glowOpacity: 0.55,
                hasSpark: false, hasPulse: !reduceMotion,
                timingMarkerColor: nil, decayDuration: 0.30)
        case .excellent:
            return NotationFeedbackStyle(
                glowColor: Color(red: 0.15, green: 0.95, blue: 0.70),
                glowRadius: 16, glowOpacity: 0.80,
                hasSpark: !reduceMotion, hasPulse: !reduceMotion,
                timingMarkerColor: nil, decayDuration: 0.35)
        case .early:
            return NotationFeedbackStyle(
                glowColor: Color(red: 0.85, green: 0.65, blue: 0.15),
                glowRadius: 4, glowOpacity: 0.38,
                hasSpark: false, hasPulse: false,
                timingMarkerColor: Color(red: 0.85, green: 0.65, blue: 0.15),
                decayDuration: 0.40)
        case .late:
            return NotationFeedbackStyle(
                glowColor: Color(red: 1.00, green: 0.55, blue: 0.10),
                glowRadius: 4, glowOpacity: 0.38,
                hasSpark: false, hasPulse: false,
                timingMarkerColor: Color(red: 1.00, green: 0.55, blue: 0.10),
                decayDuration: 0.40)
        case .wrongDirection:
            return NotationFeedbackStyle(
                glowColor: Color(red: 0.80, green: 0.35, blue: 0.35),
                glowRadius: 3, glowOpacity: 0.22,
                hasSpark: false, hasPulse: false,
                timingMarkerColor: Color(red: 0.80, green: 0.35, blue: 0.35),
                decayDuration: 0.35)
        case .missed:
            return NotationFeedbackStyle(
                glowColor: Color(white: 0.40),
                glowRadius: 2, glowOpacity: 0.18,
                hasSpark: false, hasPulse: false,
                timingMarkerColor: nil, decayDuration: 0.25)
        }
    }
}
