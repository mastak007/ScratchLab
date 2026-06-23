import Foundation
import CoreGraphics

// MARK: - ScratchNotationViewportMapper

/// Pure, testable math for the Notation Lab's playhead-relative scrolling
/// viewport. All functions are static and side-effect-free — they read only
/// their arguments.
///
/// The viewport uses a fixed playhead fraction and a fixed visible-duration
/// window. Time → x-position is computed so that when `now` equals a stroke's
/// time, the stroke lands exactly on the playhead line.
///
/// ## Mapping
///
/// ```
/// playheadX        = width * playheadFraction
/// leadInDuration   = viewportDuration * playheadFraction
/// visibleStart     = now - leadInDuration
/// xFor(time, now)  = playheadX + (time - now) * pointsPerSecond
/// ```
///
/// With `playheadFraction = 0.30` and `viewportDuration = 2.4`:
/// - leadInDuration = 0.72 s
/// - At `now = 0.0`: visibleStart = -0.72, first stroke at 0.0 maps to playheadX
/// - A stroke at `now + 0.5` maps to `playheadX + 0.5 / 2.4 * width` (right of playhead)
/// - A stroke at `now - 0.3` maps to `playheadX - 0.3 / 2.4 * width` (left of playhead)
///
/// There are **no** hard clamps — visibleStart is allowed to be negative
/// (empty lead-in space before the phrase) and to extend past phraseEnd
/// (empty tail-out space after the phrase).
struct ScratchNotationViewportMapper: Equatable, Sendable {

    // MARK: - Configuration

    /// How many seconds are visible at once in the viewport.
    let viewportDuration: TimeInterval
    /// Playhead position as a fraction from the left edge (0.0 = left, 1.0 = right).
    let playheadFraction: Double

    // MARK: - Derived constants

    /// Seconds of lead-in shown to the left of the playhead.
    var leadInDuration: TimeInterval {
        viewportDuration * playheadFraction
    }

    /// Seconds of lookahead shown to the right of the playhead.
    var secondsAhead: TimeInterval {
        viewportDuration * (1.0 - playheadFraction)
    }

    /// Pixels per timeline second for a given canvas width.
    func pointsPerSecond(forWidth width: CGFloat) -> CGFloat {
        guard viewportDuration > 0 else { return 0 }
        return width / CGFloat(viewportDuration)
    }

    /// X-position of the playhead line for a given canvas width.
    func playheadX(forWidth width: CGFloat) -> CGFloat {
        width * CGFloat(playheadFraction)
    }

    // MARK: - Notation Lab factory

    /// The fixed configuration used by the Notation Lab canvas.
    static let notationLab = ScratchNotationViewportMapper(
        viewportDuration: 2.4,
        playheadFraction: 0.30
    )

    // MARK: - Time → X

    /// Maps a timeline time to an x-position on the canvas.
    ///
    /// - Parameters:
    ///   - time: The absolute timeline time (in seconds).
    ///   - now: The current playback position (in seconds).
    ///   - width: The canvas width in points.
    /// - Returns: The x-position where `time` appears on screen.
    func xFor(time: TimeInterval, now: TimeInterval, width: CGFloat) -> CGFloat {
        let pps = pointsPerSecond(forWidth: width)
        let phX = playheadX(forWidth: width)
        return phX + CGFloat(time - now) * pps
    }

    /// The visible time window at the current playback position.
    ///
    /// - Returns: A range `[visibleStart, visibleEnd]` in seconds.
    ///   visibleStart may be negative (lead-in before phrase start);
    ///   visibleEnd may extend past phraseEnd (tail-out).
    func visibleTimeRange(now: TimeInterval, width: CGFloat) -> ClosedRange<TimeInterval> {
        let visibleStart = now - leadInDuration
        let visibleEnd = visibleStart + viewportDuration
        return visibleStart...visibleEnd
    }

    /// Whether a time interval `[start, end]` overlaps the visible window.
    func isVisible(from start: TimeInterval, to end: TimeInterval, now: TimeInterval, width: CGFloat) -> Bool {
        let window = visibleTimeRange(now: now, width: width)
        return end >= window.lowerBound && start <= window.upperBound
    }

    // MARK: - Loop wrapping

    /// Wraps audio time into phrase-local time using the notation's phrase duration.
    ///
    /// Returns a value in `[0, phraseDuration)` that cycles continuously as audio
    /// time advances. No clamping — the wrap is seamless so the notation loops.
    static func phraseTime(forAudioTime audioTime: TimeInterval, phraseDuration: TimeInterval) -> TimeInterval {
        guard phraseDuration > 0 else { return max(0, audioTime) }
        return audioTime.truncatingRemainder(dividingBy: phraseDuration)
    }
}
