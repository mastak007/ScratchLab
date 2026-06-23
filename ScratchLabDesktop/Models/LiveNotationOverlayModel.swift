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

    enum Mode: Equatable, Hashable {
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

    /// Events that intersect the given time range.
    ///
    /// - In `.target` mode: all events that overlap `[rangeMin, rangeMax]`.
    /// - In `.captured` mode: same but only events with `startTime ≤ currentTime`
    ///   are marked as played; events with `startTime > currentTime` are
    ///   returned as well (for grey future-guide rendering).
    ///
    /// Zero-travel events are always excluded.
    func eventsInViewport(
        rangeMin: TimeInterval,
        rangeMax: TimeInterval,
        currentTime: TimeInterval
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        return events.filter { event in
            // Overlaps viewport?
            guard event.endTime > rangeMin && event.startTime < rangeMax else {
                return false
            }
            // Has real travel?
            guard CapturedNotationStrokeGeometry.travelFraction(for: event) > 0 else {
                return false
            }
            return true
        }
    }

    // MARK: - Factory: target notation from ScratchNotation

    /// Build a `.target`-mode model from an authored `ScratchNotation`.
    ///
    /// Each `ScratchNotation.Stroke` becomes one
    /// `DetectedNotationRecordMovementEvent` with:
    /// - timing: `startTime` / `endTime` from the stroke
    /// - direction: `stroke.direction.rawValue` (`"forward"` / `"backward"`)
    /// - **fixed instructional travel**: `startPosition = 0.0`,
    ///   `endPosition = 0.5` (travel fraction = 0.5) so target mode
    ///   never uses captured movement amplitude
    /// - `movementKind`: from `stroke.movementKind`
    /// - `confidence`: `1.0`, `source`: `"target_notation"`
    ///
    /// An empty or `nil` notation produces an empty model with
    /// `duration = 0`, which callers can treat as the empty state.
    static func targetNotation(
        from notation: ScratchNotation?
    ) -> LiveNotationOverlayModel {
        guard let notation, !notation.strokes.isEmpty else {
            return LiveNotationOverlayModel(
                events: [],
                duration: 0,
                mode: .target
            )
        }
        let events: [CaptureCore.DetectedNotationRecordMovementEvent] =
            notation.strokes.map { stroke in
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: stroke.startTime,
                    endTime: stroke.endTime,
                    startPosition: 0.0,
                    endPosition: 0.5,
                    direction: stroke.direction.rawValue,
                    movementKind: stroke.movementKind,
                    speed: 0.5,
                    confidence: 1.0,
                    source: "target_notation"
                )
            }
        return LiveNotationOverlayModel(
            events: events,
            duration: notation.timelineDuration,
            mode: .target
        )
    }

    // MARK: - Factory: replay notation from ScratchNotation

    /// Build a `.captured`-mode model from an authored `ScratchNotation`
    /// with **duration-derived amplitude** so short/fast strokes render
    /// as visually smaller peaks and long/slow strokes render as
    /// full-amplitude arcs.
    ///
    /// Each `ScratchNotation.Stroke` becomes one
    /// `DetectedNotationRecordMovementEvent` with:
    /// - timing and direction preserved exactly
    /// - `startPosition = 0.0`, `endPosition` scaled by stroke duration
    ///   relative to the longest stroke in the notation
    /// - a floor of `0.15` so even the shortest stroke is visible
    /// - mode `.captured` so future strokes remain hidden during replay
    ///
    /// An empty or `nil` notation produces an empty model with
    /// `duration = 0`.
    static func replayNotation(
        from notation: ScratchNotation?
    ) -> LiveNotationOverlayModel {
        guard let notation, !notation.strokes.isEmpty else {
            return LiveNotationOverlayModel(
                events: [],
                duration: 0,
                mode: .captured
            )
        }
        let maxDuration = notation.strokes.map(\.duration).max() ?? 1.0
        let floorFraction: Double = 0.15
        let rangeFraction: Double = 1.0 - floorFraction
        let events: [CaptureCore.DetectedNotationRecordMovementEvent] =
            notation.strokes.map { stroke in
                let normalized = maxDuration > 0
                    ? stroke.duration / maxDuration
                    : 1.0
                let amplitude = floorFraction + rangeFraction * normalized
                return CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: stroke.startTime,
                    endTime: stroke.endTime,
                    startPosition: 0.0,
                    endPosition: amplitude,
                    direction: stroke.direction.rawValue,
                    movementKind: stroke.movementKind,
                    speed: 0.5,
                    confidence: 1.0,
                    source: "replay_notation"
                )
            }
        return LiveNotationOverlayModel(
            events: events,
            duration: notation.timelineDuration,
            mode: .captured
        )
    }

    // MARK: - Factory: gap-compressed replay notation

    /// A contiguous span of strokes that belong to the same scratch phrase.
    /// Gaps larger than `gapThreshold` between consecutive strokes are
    /// treated as phrase boundaries.
    struct PhraseSegment: Equatable {
        let startTime: TimeInterval   // real time
        let endTime: TimeInterval     // real time
        var compressedStart: TimeInterval
    }

    /// Detects phrase segments from a `ScratchNotation` by finding
    /// inter-stroke gaps larger than `gapThreshold`.
    ///
    /// The Baby Scratch demo has ~5 s instructional hold periods between
    /// its four phrases. A threshold of 2 s cleanly separates them
    /// without splitting the small (~0.37 s) intra-phrase gaps.
    static func phraseSegments(
        from notation: ScratchNotation,
        gapThreshold: TimeInterval = 2.0
    ) -> [PhraseSegment] {
        guard !notation.strokes.isEmpty else { return [] }
        var segments: [PhraseSegment] = []
        var segStart = notation.strokes[0].startTime
        for i in 0..<(notation.strokes.count - 1) {
            let gap = notation.strokes[i + 1].startTime - notation.strokes[i].endTime
            if gap > gapThreshold {
                segments.append(PhraseSegment(
                    startTime: segStart,
                    endTime: notation.strokes[i].endTime,
                    compressedStart: 0  // filled below
                ))
                segStart = notation.strokes[i + 1].startTime
            }
        }
        segments.append(PhraseSegment(
            startTime: segStart,
            endTime: notation.strokes.last!.endTime,
            compressedStart: 0
        ))
        // Back-fill compressedStart offsets.
        var offset: TimeInterval = 0
        for i in segments.indices {
            var seg = segments[i]
            seg.compressedStart = offset
            offset += seg.endTime - seg.startTime
            segments[i] = seg
        }
        return segments
    }

    /// Maps real demo playback time to gap-compressed display time.
    ///
    /// During instructional hold gaps between phrases, the compressed
    /// time holds steady at the end of the just-finished phrase so the
    /// cursor pauses naturally rather than scanning through empty space.
    ///
    /// - Returns: compressed display time in `[0, activeDuration]`
    static func gapCompressedDisplayTime(
        for realTime: TimeInterval,
        segments: [PhraseSegment]
    ) -> TimeInterval {
        var accumulated: TimeInterval = 0
        for seg in segments {
            let segDuration = seg.endTime - seg.startTime
            if realTime <= seg.startTime {
                return accumulated
            }
            if realTime < seg.endTime {
                return accumulated + (realTime - seg.startTime)
            }
            accumulated += segDuration
        }
        return accumulated
    }

    /// Build a `.captured`-mode model from an authored `ScratchNotation`
    /// with **gap-compressed timing and duration-derived amplitude**.
    ///
    /// The full extracted stroke resource spans ~42.4 s but includes
    /// ~15 s of instructional hold gaps between the four Baby Scratch
    /// phrases. This factory collapses those gaps so the active scratch
    /// timeline (~26–27 s) fills the stage overlay display width without
    /// the cursor scanning through 5-second blank stretches.
    ///
    /// - Amplitude: derived from stroke duration, normalized against the
    ///   longest stroke, with a 0.15 floor.
    /// - Timing: strokes are shifted so the four phrases appear
    ///   consecutively with no inter-phrase gaps.
    /// - Mode: `.captured` — future strokes hidden during replay.
    ///
    /// An empty or `nil` notation produces an empty model with
    /// `duration = 0`.
    static func replayNotationGapCompressed(
        from notation: ScratchNotation?,
        gapThreshold: TimeInterval = 2.0
    ) -> LiveNotationOverlayModel {
        guard let notation, !notation.strokes.isEmpty else {
            return LiveNotationOverlayModel(
                events: [],
                duration: 0,
                mode: .captured
            )
        }
        let segments = phraseSegments(from: notation, gapThreshold: gapThreshold)
        let maxDuration = notation.strokes.map(\.duration).max() ?? 1.0
        let floorFraction: Double = 0.15
        let rangeFraction: Double = 1.0 - floorFraction

        var compressedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []
        for seg in segments {
            let segStart = seg.startTime
            let offset = seg.compressedStart
            for stroke in notation.strokes {
                guard stroke.startTime >= segStart - 0.001,
                      stroke.endTime <= seg.endTime + 0.001 else { continue }
                let compressedStart = (stroke.startTime - segStart) + offset
                let compressedEnd = (stroke.endTime - segStart) + offset

                let normalized = maxDuration > 0
                    ? stroke.duration / maxDuration
                    : 1.0
                let amplitude = floorFraction + rangeFraction * normalized

                compressedEvents.append(CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: compressedStart,
                    endTime: compressedEnd,
                    startPosition: 0.0,
                    endPosition: amplitude,
                    direction: stroke.direction.rawValue,
                    movementKind: stroke.movementKind,
                    speed: 0.5,
                    confidence: 1.0,
                    source: "replay_notation_gap_compressed"
                ))
            }
        }

        let activeDuration = segments.map({ $0.endTime - $0.startTime }).reduce(0, +)
        return LiveNotationOverlayModel(
            events: compressedEvents,
            duration: activeDuration,
            mode: .captured
        )
    }
}
