import Foundation

/// Pure model for the live notation overlay cursor and visible-stroke filtering.
///
/// Used by `LiveNotationOverlayView` and testable without any SwiftUI import.
///
/// In `.captured` mode the model acts as a performance guard: strokes are
/// revealed only as `currentTime` advances past their `startTime`, so no
/// phantom future notes appear before they are played.
///
/// In `.target` mode all strokes are visible at all times — for coach /
/// reference displays that are instructional rather than performative.
///
/// Silence suppression: events whose `CapturedNotationStrokeGeometry
/// .travelFraction` is zero are excluded from `visibleEvents(at:)` in both
/// modes, so silence/idle columns remain empty.
struct LiveNotationOverlayModel: Equatable {

    enum Mode: Equatable {
        case target    // coach/reference — all strokes visible always
        case captured  // performance — strokes revealed as currentTime advances
    }

    let events: [CaptureCore.DetectedNotationRecordMovementEvent]
    /// Total phrase / take span. Zero when the model is empty.
    let duration: TimeInterval
    let mode: Mode

    // MARK: - Cursor

    /// Cursor position over `[0, 1]`.
    ///
    /// Monotonic: for any `a ≤ b`, `cursorFraction(at: a) ≤ cursorFraction(at: b)`.
    /// Clamped to `[0, 1]`; returns `0` when `duration == 0`.
    func cursorFraction(at currentTime: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let clamped = max(0, min(currentTime, duration))
        return clamped / duration
    }

    // MARK: - Visible strokes

    /// Events eligible to draw at `currentTime`.
    ///
    /// - `.captured`: only events whose `startTime ≤ currentTime`.
    /// - `.target`: all events.
    ///
    /// In both modes, events with `travelFraction == 0` are excluded so idle
    /// / zero-travel columns remain empty (silence produces no strokes).
    func visibleEvents(
        at currentTime: TimeInterval
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        let filtered: [CaptureCore.DetectedNotationRecordMovementEvent]
        switch mode {
        case .target:
            filtered = events
        case .captured:
            filtered = events.filter { $0.startTime <= currentTime }
        }
        return filtered.filter {
            CapturedNotationStrokeGeometry.travelFraction(for: $0) > 0
        }
    }

    func hasMeaningfulStrokes(at currentTime: TimeInterval) -> Bool {
        !visibleEvents(at: currentTime).isEmpty
    }

    var isEmpty: Bool { events.isEmpty }
}
