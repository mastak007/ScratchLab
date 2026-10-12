import CoreGraphics
import Foundation

// Derived platter-motion geometry for the Scratch Motion Lane.
//
// The notation renderer used to draw each stroke as an isolated block. This
// turns the SAME stroke data into a *platter-position curve* — a
// continuous line of where the platter sits over time. Forward motion rises,
// backward motion falls, gaps and holds stay flat; a stroke's duration is the
// curve's horizontal length and its travel is the vertical rise or fall.
//
// `MotionPath` is pure, derived, and never persisted — it adds no field to any
// notation JSON schema. It is computed from the existing `LaneContent` /
// `LaneStroke` data, so it touches no capture, export, session, or training
// code. `ScratchMotionRenderer` consumes it; this file only shapes it.

// MARK: - Segment

/// Whether a motion segment is a platter stroke (a ramp) or a hold (flat).
enum MotionSegmentKind: Equatable, Sendable {
    /// A platter stroke — `forward` ramps the curve up, `backward` ramps it down.
    case stroke(ScratchNotationDirection)
    /// A pause between strokes — the curve holds flat.
    case hold
}

/// One span of the platter-position curve. Positions are normalized 0...1
/// (0 = the curve's lowest point, 1 = its highest) so the path always fits the
/// lane whatever the pattern.
struct MotionSegment: Equatable, Sendable {
    /// Legacy gaps are layout padding. Canonical holds have position evidence
    /// and must remain visible. Fader uncertainty never changes platter position.
    enum EvidenceStyle: Equatable, Sendable {
        case legacy, open, closed, unknownFader
    }
    let kind: MotionSegmentKind
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Normalized platter position at `startTime` (0...1).
    let startPosition: CGFloat
    /// Normalized platter position at `endTime` (0...1).
    let endPosition: CGFloat
    /// Speed of the originating stroke — `medium` for holds. Drives the
    /// renderer's easing sharpness and line weight, not the geometry.
    let speed: ScratchNotationSpeedClassification
    /// True for a derived copy-window ghost (Demo mode).
    let isGhost: Bool
    var evidenceStyle: EvidenceStyle = .legacy

    var drawsLine: Bool { !isHold || evidenceStyle != .legacy }

    var duration: TimeInterval { max(0, endTime - startTime) }

    /// Vertical distance the platter travelled across this segment.
    var travel: CGFloat { abs(endPosition - startPosition) }

    var isHold: Bool {
        if case .hold = kind { return true }
        return false
    }

    /// `true` for a forward (rising) stroke, `false` for backward, `nil` for a hold.
    var isRising: Bool? {
        switch kind {
        case .stroke(let direction): return direction == .forward
        case .hold:                  return nil
        }
    }
}

// MARK: - Path

/// The integrated platter-position curve for one stretch of lane content — a
/// continuous chain of `MotionSegment`s covering `timeRange` with no gaps.
struct MotionPath: Equatable, Sendable {
    let segments: [MotionSegment]
    /// The timeline span the path covers.
    let timeRange: ClosedRange<TimeInterval>

    var isEmpty: Bool { segments.isEmpty }

    /// Linearly-interpolated platter position (0...1) at `time`, clamped to the
    /// path's ends. This is the geometric ground truth; the renderer adds
    /// easing on top purely for display.
    func position(at time: TimeInterval) -> CGFloat {
        guard let first = segments.first, let last = segments.last else { return 0.5 }
        if time <= first.startTime { return first.startPosition }
        if time >= last.endTime { return last.endPosition }
        for segment in segments where time >= segment.startTime && time <= segment.endTime {
            let span = segment.endTime - segment.startTime
            guard span > 1e-9 else { return segment.startPosition }
            let fraction = CGFloat((time - segment.startTime) / span)
            return segment.startPosition
                + (segment.endPosition - segment.startPosition) * fraction
        }
        return last.endPosition
    }

    /// The path with every time shifted by `offset` — used to tile a looping
    /// pattern seamlessly across the lane.
    func shifted(by offset: TimeInterval) -> MotionPath {
        guard offset != 0 else { return self }
        return MotionPath(
            segments: segments.map {
                MotionSegment(kind: $0.kind,
                              startTime: $0.startTime + offset,
                              endTime: $0.endTime + offset,
                              startPosition: $0.startPosition,
                              endPosition: $0.endPosition,
                              speed: $0.speed, isGhost: $0.isGhost,
                              evidenceStyle: $0.evidenceStyle)
            },
            timeRange: (timeRange.lowerBound + offset)...(timeRange.upperBound + offset))
    }
}

// MARK: - Derivation

/// Turns lane content into its platter-position curve.
enum ScratchStrokeGeometry {

    /// Per-stroke amplitude — how far the platter moves in one stroke.
    /// A slow drag reads as a small excursion; a medium push is mid-amplitude;
    /// a fast stab hits the rail. The speed bucket is the only signal driving
    /// this first amplitude pass — duration, direction sign, fader state and
    /// confidence stay out of it. Rest / starting position is always raw 0,
    /// so a balanced forward/backward pair returns to 0 and the loop seam
    /// closes regardless of how the rail end is scaled.
    private static func rawAmplitude(for stroke: LaneStroke) -> CGFloat {
        // Travel-driven amplitude takes precedence when present (PR 2 supplies it from analysis);
        // otherwise the existing speed-bucket amplitude is used unchanged.
        if let travel = stroke.normalizedTravel {
            return min(1, max(0, CGFloat(travel)))
        }
        switch stroke.speed {
        case .slow:   return 0.55
        case .medium: return 0.78
        case .fast:   return 1.0
        }
    }

    /// Derives the platter-position curve for `content` as ONE continuous
    /// physical position trace, not a series of isolated out/return bumps.
    /// The platter starts at its resting position (raw 0) and integrates
    /// forward: a forward stroke raises the position over its full
    /// `[startTime, endTime]` window, a backward stroke lowers it, and the
    /// next stroke begins exactly where the previous one ended. Gaps and
    /// holds keep the position flat, so the platter never springs back to
    /// centre between strokes. A balanced forward/backward pair returns to
    /// its starting position; an unbalanced or incomplete phrase ends
    /// wherever its last stroke left it (no fabricated closing move). A
    /// stroke with measured endpoints (`LaneStroke.measuredStartPosition` /
    /// `.measuredEndPosition`) is drawn as that exact measured span instead
    /// of an integrated amplitude — that is how the MY PERFORMANCE row
    /// preserves captured motion truthfully.
    /// A raw (un-normalized) platter-position span before the 0…1 vertical
    /// normalization. Raw 0 is the platter's starting/rest position; forward
    /// motion raises it and backward motion lowers it, cumulatively.
    private struct RawMotionSpan {
        let kind: MotionSegmentKind
        let start: TimeInterval
        let end: TimeInterval
        let startPos: CGFloat
        let endPos: CGFloat
        let speed: ScratchNotationSpeedClassification
        let isGhost: Bool
    }

    /// Builds the ordered raw spans for `content` (one directional segment
    /// per stroke + holds), shared by every normalization variant so a stroke
    /// is shaped identically no matter which vertical frame the caller
    /// chooses. Stroke times are preserved exactly — each stroke is a single
    /// segment covering `[stroke.startTime, stroke.endTime]` and nothing else.
    private static func rawSpans(for content: LaneContent) -> [RawMotionSpan] {
        let duration = max(content.duration, 0.001)
        let strokes = content.strokes.sorted { $0.startTime < $1.startTime }
        let epsilon = 1e-6

        guard !strokes.isEmpty else {
            // No strokes — one flat hold across the whole timeline.
            return [RawMotionSpan(kind: .hold, start: 0, end: duration,
                                  startPos: 0, endPos: 0,
                                  speed: .medium, isGhost: false)]
        }

        var spans: [RawMotionSpan] = []
        func appendHold(start: TimeInterval, end: TimeInterval, position: CGFloat,
                        isGhost: Bool) {
            guard end > start + epsilon else { return }
            spans.append(RawMotionSpan(kind: .hold, start: start, end: end,
                                       startPos: position, endPos: position,
                                       speed: .medium, isGhost: isGhost))
        }

        // The platter starts at rest (raw 0) for authored content, or at the
        // first measured position for captured content, and integrates from
        // there. Holds freeze `current`; strokes move it.
        var current: CGFloat = strokes[0].measuredStartPosition.map { CGFloat($0) } ?? 0

        appendHold(start: 0, end: strokes[0].startTime, position: current,
                   isGhost: strokes[0].isGhost)

        for (index, stroke) in strokes.enumerated() {
            // One directional segment over the stroke's full window. Measured
            // endpoints are used verbatim (preserving the captured trace);
            // authored strokes integrate a signed amplitude from the current
            // position.
            let startPos: CGFloat
            let endPos: CGFloat
            if let measuredStart = stroke.measuredStartPosition,
               let measuredEnd = stroke.measuredEndPosition {
                startPos = CGFloat(measuredStart)
                endPos = CGFloat(measuredEnd)
            } else {
                let sign: CGFloat = (stroke.direction == .forward) ? 1 : -1
                let delta = sign * rawAmplitude(for: stroke)
                startPos = current
                endPos = current + delta
            }
            spans.append(RawMotionSpan(kind: .stroke(stroke.direction),
                                       start: stroke.startTime, end: stroke.endTime,
                                       startPos: startPos, endPos: endPos,
                                       speed: stroke.speed, isGhost: stroke.isGhost))
            current = endPos
            if index + 1 < strokes.count {
                appendHold(start: stroke.endTime,
                           end: strokes[index + 1].startTime,
                           position: current,
                           isGhost: stroke.isGhost)
            }
        }

        if let last = strokes.last {
            appendHold(start: last.endTime, end: duration, position: current,
                       isGhost: last.isGhost)
        }

        return spans
    }

    /// Normalizes raw spans into 0…1 over an explicit raw `[low, high]` frame
    /// and packages them as a `MotionPath`. A balanced phrase returns to its
    /// starting position, so a looping pattern is naturally seamless when
    /// tiled.
    private static func normalizedPath(spans: [RawMotionSpan],
                                       low: CGFloat, high: CGFloat,
                                       duration: TimeInterval) -> MotionPath {
        let epsilon = 1e-6
        let range = high - low
        func normalized(_ value: CGFloat) -> CGFloat {
            range > epsilon ? (value - low) / range : 0.5
        }
        let segments = spans.map {
            MotionSegment(kind: $0.kind,
                          startTime: $0.start, endTime: $0.end,
                          startPosition: normalized($0.startPos),
                          endPosition: normalized($0.endPos),
                          speed: $0.speed, isGhost: $0.isGhost)
        }
        return MotionPath(segments: segments, timeRange: 0...max(duration, 0.001))
    }

    static func motionPath(for content: LaneContent) -> MotionPath {
        let spans = rawSpans(for: content)
        let positions = spans.flatMap { [$0.startPos, $0.endPos] }
        let low = positions.min() ?? -1
        let high = positions.max() ?? 1
        return normalizedPath(spans: spans, low: low, high: high,
                              duration: max(content.duration, 0.001))
    }

    /// The same curve, but normalized against an explicit raw `[lowerBound,
    /// upperBound]` frame instead of the content's own min/max. The stacked
    /// TARGET / MY PERFORMANCE comparison passes the TARGET's `rawRange(for:)`
    /// here so a sparse performed take keeps the target's vertical coordinate
    /// frame — the neutral position and a given travel land on the same Y in
    /// both rows rather than rescaling to the performed take's own extremes.
    static func motionPath(for content: LaneContent,
                           normalizingTo frame: ClosedRange<CGFloat>) -> MotionPath {
        let spans = rawSpans(for: content)
        return normalizedPath(spans: spans,
                              low: frame.lowerBound, high: frame.upperBound,
                              duration: max(content.duration, 0.001))
    }

    /// The raw vertical frame `[min, max]` that `content`'s own
    /// `motionPath(for:)` normalization uses — the value the performed row
    /// reuses as its frame so both rows share one vertical coordinate frame.
    static func rawRange(for content: LaneContent) -> ClosedRange<CGFloat> {
        let positions = rawSpans(for: content).flatMap { [$0.startPos, $0.endPos] }
        let low = positions.min() ?? -1
        let high = positions.max() ?? 1
        return low...high
    }

    /// One forward→backward reversal boundary on a continuous motion path —
    /// the time a stroke changes direction, and the path's own position at
    /// that instant (the apex the following backward stroke returns from).
    struct TurnaroundAnchor: Equatable, Sendable {
        let time: TimeInterval
        let position: CGFloat
    }

    /// Explicit turnaround anchors at forward→backward direction-change
    /// boundaries, derived from canonical stroke direction alone (never
    /// inferred from drawn geometry). The single reversal-detection
    /// implementation every consumer (macOS phrase chart, the shared
    /// `ScratchNotationPanel`) reuses instead of re-deriving its own —
    /// extracted verbatim from `ScratchPhraseChartView.drawTurnaroundMarkers`.
    static func turnaroundAnchors(strokes: [LaneStroke], path: MotionPath) -> [TurnaroundAnchor] {
        let sorted = strokes.sorted { $0.startTime < $1.startTime }
        guard sorted.count >= 2 else { return [] }
        var anchors: [TurnaroundAnchor] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard a.direction == .forward, b.direction == .backward else { continue }
            anchors.append(TurnaroundAnchor(time: a.endTime, position: path.position(at: a.endTime)))
        }
        return anchors
    }
}

// MARK: - Recorded sample playback (presentation only)

extension ScratchStrokeGeometry {
    /// Fits the complete selected repetition on one stable review timeline.
    /// Short selections gain surrounding context, shifted inward at the file
    /// edges; a recording shorter than the requested width stays its true size.
    /// This changes only the viewport, never saved bounds or motion geometry.
    static func reviewTimeRange(selected: ClosedRange<Double>,
                                within available: ClosedRange<Double>,
                                minimumDuration: Double = 8) -> ClosedRange<Double>? {
        guard selected.lowerBound.isFinite, selected.upperBound.isFinite,
              selected.upperBound > selected.lowerBound,
              (selected.upperBound - selected.lowerBound).isFinite,
              available.lowerBound.isFinite, available.upperBound.isFinite,
              available.upperBound > available.lowerBound,
              (available.upperBound - available.lowerBound).isFinite,
              minimumDuration.isFinite, minimumDuration > 0 else { return nil }
        let selectedStart = max(selected.lowerBound, available.lowerBound)
        let selectedEnd = min(selected.upperBound, available.upperBound)
        guard selectedEnd > selectedStart else { return nil }
        let selectedDuration = selectedEnd - selectedStart
        if selectedDuration >= minimumDuration { return selectedStart...selectedEnd }
        if available.upperBound - available.lowerBound <= minimumDuration { return available }

        let padding = (minimumDuration - selectedDuration) / 2
        let start = max(available.lowerBound,
                        min(selectedStart - padding, available.upperBound - minimumDuration))
        // Preserve both selected endpoints exactly even when adding the width
        // rounds at the last bit. No measured timestamp is rounded or replaced.
        let end = min(available.upperBound, max(selectedEnd, start + minimumDuration))
        guard start.isFinite, end.isFinite, end > start,
              start <= selectedStart, end >= selectedEnd else { return nil }
        return start...end
    }

    /// Explicit, non-metric review presentation. A whole directional run gets
    /// one square-root travel scale, so small scratches remain visible beside
    /// long releases while larger excursions still draw larger. Every point
    /// inside that run retains its proportional progress and exact time.
    ///
    /// This does not change captured records, physical coordinates, exported
    /// notation or default rendering. The caller must label it Movement detail
    /// and retain the original chart as Recorded travel. The retained frame
    /// supplies time/domain context; this derived path has no physical Y scale.
    static func movementDetailChart(_ prepared: PreparedCanonicalChart,
                                    resetMarkers: [PlaybackResetMarker] = []) -> PreparedCanonicalChart? {
        let source = prepared.geometry.motion.segments
        guard !source.isEmpty else { return nil }
        var lastReset = -Double.infinity
        for marker in resetMarkers {
            guard marker.time.isFinite, marker.time > lastReset else { return nil }
            lastReset = marker.time
        }
        struct Run {
            var start: Int
            var end: Int
            var direction: Int?
        }
        var runs: [Run] = []
        var markerIndex = 0
        for (index, segment) in source.enumerated() {
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.endTime > segment.startTime,
                  segment.startPosition.isFinite, segment.endPosition.isFinite,
                  prepared.frame.timeRange.contains(segment.startTime),
                  prepared.frame.timeRange.contains(segment.endTime) else { return nil }
            let delta = Double(segment.endPosition) - Double(segment.startPosition)
            guard delta.isFinite else { return nil }
            switch segment.kind {
            case .hold: guard delta == 0 else { return nil }
            case .stroke(.forward): guard delta >= 0 else { return nil }
            case .stroke(.backward): guard delta <= 0 else { return nil }
            }
            while markerIndex < resetMarkers.count, resetMarkers[markerIndex].time < segment.startTime {
                markerIndex += 1
            }
            if markerIndex < resetMarkers.count,
               resetMarkers[markerIndex].time > segment.startTime,
               resetMarkers[markerIndex].time < segment.endTime { return nil }
            let startsAtReset = markerIndex < resetMarkers.count
                && resetMarkers[markerIndex].time == segment.startTime
            let direction: Int? = delta == 0 ? nil : (delta > 0 ? 1 : -1)
            if index > 0 {
                let previous = source[index - 1]
                guard previous.endTime <= segment.startTime else { return nil }
                if !startsAtReset, previous.endTime == segment.startTime,
                   previous.endPosition == segment.startPosition, var run = runs.last,
                   direction == nil || run.direction == nil || direction == run.direction {
                    run.end = index
                    run.direction = run.direction ?? direction
                    runs[runs.count - 1] = run
                    continue
                }
            }
            runs.append(Run(start: index, end: index, direction: direction))
        }

        var positions: [(start: Double, end: Double)] = []
        positions.reserveCapacity(source.count)
        var cursor = 0.0
        var minimum = Double.infinity, maximum = -Double.infinity
        markerIndex = 0
        for run in runs {
            let first = source[run.start], last = source[run.end]
            var resetInGap = false
            while markerIndex < resetMarkers.count, resetMarkers[markerIndex].time <= first.startTime {
                let time = resetMarkers[markerIndex].time
                if run.start == 0 || time >= source[run.start - 1].endTime { resetInGap = true }
                markerIndex += 1
            }
            if resetInGap {
                cursor = 0
            } else if run.start > 0 {
                // Preserve a known endpoint offset across a pen-up. This
                // transforms only the display anchor; no trajectory or reset
                // marker is invented inside an unavailable interval.
                let offset = Double(first.startPosition) - Double(source[run.start - 1].endPosition)
                guard offset.isFinite else { return nil }
                cursor += offset < 0 ? -sqrt(-offset) : sqrt(offset)
            }
            let origin = Double(first.startPosition)
            let travel = Double(last.endPosition) - origin
            guard travel.isFinite, cursor.isFinite else { return nil }
            let magnitude = abs(travel)
            let scale = magnitude > 0 ? sqrt(magnitude) / magnitude : 1
            let start = cursor
            for index in run.start...run.end {
                let segment = source[index]
                let from = start + (Double(segment.startPosition) - origin) * scale
                let to = start + (Double(segment.endPosition) - origin) * scale
                guard from.isFinite, to.isFinite,
                      segment.startPosition == segment.endPosition || from != to else { return nil }
                positions.append((from, to))
                minimum = min(minimum, min(from, to)); maximum = max(maximum, max(from, to))
                cursor = to
            }
        }
        let lower: Double, upper: Double
        if !resetMarkers.isEmpty {
            let radius = max(abs(minimum), abs(maximum))
            let extent = radius > 0 ? radius * 1.125 : 0.5
            lower = -extent; upper = extent
        } else {
            let span = maximum - minimum
            let padding = span > 0 ? span * 0.125 : 0.5
            lower = minimum - padding; upper = maximum + padding
        }
        let span = upper - lower
        guard lower.isFinite, upper.isFinite, span.isFinite, span > 0 else { return nil }
        var motion: [MotionSegment] = []
        motion.reserveCapacity(source.count)
        for (segment, position) in zip(source, positions) {
            let from = CGFloat((position.start - lower) / span)
            let to = CGFloat((position.end - lower) / span)
            guard from.isFinite, to.isFinite,
                  segment.startPosition == segment.endPosition || from != to else { return nil }
            motion.append(MotionSegment(kind: segment.kind,
                startTime: segment.startTime, endTime: segment.endTime,
                startPosition: from, endPosition: to, speed: segment.speed,
                isGhost: segment.isGhost, evidenceStyle: segment.evidenceStyle))
        }
        let geometry = prepared.geometry
        return PreparedCanonicalChart(frame: prepared.frame, layer: prepared.layer,
            geometry: CanonicalGeometry(motion: MotionPath(segments: motion,
                timeRange: geometry.motion.timeRange), missingMotion: geometry.missingMotion,
                fader: geometry.fader, faderEdges: geometry.faderEdges,
                hasUnplacedEvidence: geometry.hasUnplacedEvidence),
            mixerSpans: prepared.mixerSpans, combinedMixerSpans: prepared.combinedMixerSpans)
    }

    struct PlaybackResetMarker: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case loop, sampleRestart }
        let time: Double
        let kind: Kind
    }

    /// Separate from physical platter evidence. Positions describe recorded
    /// software sample-control publications, expressed in sample-loop units
    /// relative to each continuous run's origin. Only a witnessed loop/restart
    /// receives a reset marker; acquiring or recovering context does not.
    struct SamplePlaybackChart: Equatable, Sendable {
        let prepared: PreparedCanonicalChart
        let resets: [PlaybackResetMarker]
        var centreFraction: CGFloat { 0.5 }

        /// Keeps the take-wide vertical scale. Paging clips prepared geometry;
        /// it neither scans the recording again nor changes any sample value.
        func windowed(to range: ClosedRange<Double>) -> Self? {
            let old = prepared.frame
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound < range.upperBound else { return nil }
            let start = max(range.lowerBound, old.timeRange.lowerBound)
            let end = min(range.upperBound, old.timeRange.upperBound)
            guard start < end,
                  let frame = CanonicalFrame(timeRange: start...end,
                    positionRange: old.positionRange, coordinateSpace: old.coordinateSpace,
                    beatsPerMinute: old.beatsPerMinute) else { return nil }
            let bounds = frame.timeRange
            func clipped(_ range: ClosedRange<Double>) -> ClosedRange<Double>? {
                let lower = max(start, range.lowerBound), upper = min(end, range.upperBound)
                return lower < upper ? lower...upper : nil
            }
            let geometry = prepared.geometry
            return Self(prepared: PreparedCanonicalChart(frame: frame, layer: prepared.layer,
                geometry: CanonicalGeometry(
                    motion: MotionPath(segments: ScratchStrokeGeometry.sampleSegments(geometry.motion.segments, in: bounds),
                                       timeRange: bounds),
                    missingMotion: geometry.missingMotion.compactMap(clipped),
                    fader: geometry.fader.compactMap { interval in
                        clipped(interval.range).map { .init(range: $0, state: interval.state) }
                    },
                    faderEdges: geometry.faderEdges.filter { bounds.contains($0.time) },
                    hasUnplacedEvidence: geometry.hasUnplacedEvidence),
                mixerSpans: prepared.mixerSpans.map { values in
                    values.mapValues { ScratchMixerFaderEvidence.Span.clipped($0, to: bounds) }
                },
                combinedMixerSpans: prepared.combinedMixerSpans.map {
                    ScratchMixerFaderEvidence.Span.clipped($0, to: bounds)
                }),
                resets: resets.filter { bounds.contains($0.time) })
        }
    }

    /// Builds a distinct sample-relative review using the playback owner's
    /// existing signed position. No MIDI integration, loop inference, physical
    /// gesture mutation or change to the default canonical/PNG path occurs.
    static func samplePlaybackChart(
        timeline: RecordedPlaybackLoopTimeline,
        records: [ScratchNotation.GestureRecord], frame: CanonicalFrame,
        mixerFaders: ScratchMixerFaderEvidence? = nil
    ) -> SamplePlaybackChart? {
        guard timeline.version == 1, !timeline.overflowed,
              !timeline.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !timeline.takeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeline.duration.isFinite, timeline.duration > 0,
              timeline.observations.count <= RecordedPlaybackLoopRecorder.maximumObservations else { return nil }

        struct Point {
            let time: Double
            let sample: String
            let generation: UInt64
            let position: Double
            let period: Double
        }
        struct Span {
            let start: Double
            let end: Double
            let from: Double
            let to: Double
        }
        var spans: [Span] = []
        var supportedRanges: [ClosedRange<Double>] = []
        var resets: [PlaybackResetMarker] = []
        var previous: Point?
        var previousTime: Double?
        var origin = 0.0
        var radius = 0.0
        for observation in timeline.observations {
            guard observation.time.isFinite, observation.time >= 0,
                  observation.time <= timeline.duration,
                  previousTime.map({ observation.time > $0 }) ?? true else { return nil }
            previousTime = observation.time
            if observation.kind == .unavailable {
                previous = nil
                continue
            }
            guard let sample = observation.sampleID,
                  !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let generation = observation.generation,
                  let position = observation.positionSteps, position.isFinite,
                  let period = observation.loopLengthInSteps, period.isFinite, period > 0 else { return nil }
            let point = Point(time: observation.time, sample: sample, generation: generation,
                              position: position, period: period)
            let isReset = observation.kind == .loop || observation.kind == .sampleRestart
            if isReset {
                resets.append(.init(time: point.time,
                    kind: observation.kind == .loop ? .loop : .sampleRestart))
            }
            let continuousContext = previous.map { before in
                before.sample == sample && before.generation == generation && before.period == period
                    && point.time - before.time <= 0.1
            } ?? false
            if let before = previous, continuousContext, observation.kind == .loop {
                // A recorded same-context loop is an intentional display
                // pen-up, not unavailable sample evidence. Keep the interval
                // free of an unknown band without inventing a phase path.
                supportedRanges.append(before.time...point.time)
            }
            if let before = previous, !isReset, continuousContext {
                let fromOffset = before.position - origin, toOffset = position - origin
                let from = fromOffset / period, to = toOffset / period
                guard from.isFinite, to.isFinite, (to - from).isFinite,
                      fromOffset == 0 || from != 0,
                      toOffset == 0 || to != 0 else { return nil }
                spans.append(Span(start: before.time, end: point.time, from: from, to: to))
                supportedRanges.append(before.time...point.time)
                radius = max(radius, max(abs(from), abs(to)))
            } else {
                // A pen-up at a witnessed reset or an evidence discontinuity.
                // The first subsequent segment starts at the centre; no line
                // falsely describes the reset as a reverse platter movement.
                origin = position
            }
            previous = point
        }
        guard !spans.isEmpty else { return nil }
        let extent = radius > 0 ? radius * 1.125 : 0.5
        guard extent.isFinite, extent > 0, (extent * 2).isFinite,
              let sampleFrame = CanonicalFrame(timeRange: frame.timeRange,
                positionRange: -extent...extent, coordinateSpace: .samplePosition,
                beatsPerMinute: frame.beatsPerMinute) else { return nil }
        // Canonical records supply only independent fader evidence here.
        // Their physical path and unknown regions remain in the overview.
        let original = PreparedCanonicalChart(records: records, layer: .performance,
                                              frame: frame, mixerFaders: mixerFaders)
        var motion: [MotionSegment] = []
        var faderIndex = 0
        for span in spans where span.end > frame.timeRange.lowerBound && span.start < frame.timeRange.upperBound {
            let start = max(span.start, frame.timeRange.lowerBound)
            let end = min(span.end, frame.timeRange.upperBound)
            while faderIndex < original.geometry.fader.count,
                  original.geometry.fader[faderIndex].range.upperBound <= start { faderIndex += 1 }
            var index = faderIndex
            var cursor = start
            while cursor < end {
                let rail = index < original.geometry.fader.count ? original.geometry.fader[index] : nil
                let stop = min(end, rail?.range.upperBound ?? end)
                guard stop > cursor else { return nil }
                func fraction(at time: Double) -> CGFloat {
                    let value = span.from + (span.to - span.from) * ((time - span.start) / (span.end - span.start))
                    return CGFloat(0.5 + value / (extent * 2))
                }
                let from = fraction(at: cursor), to = fraction(at: stop)
                guard from.isFinite, to.isFinite else { return nil }
                let style: MotionSegment.EvidenceStyle
                switch rail?.state {
                case .open: style = .open
                case .closed: style = .closed
                case nil: style = .unknownFader
                }
                motion.append(MotionSegment(kind: span.to == span.from ? .hold
                    : .stroke(span.to > span.from ? .forward : .backward),
                    startTime: cursor, endTime: stop, startPosition: from, endPosition: to,
                    speed: .medium, isGhost: false, evidenceStyle: style))
                cursor = stop
                index += 1
            }
        }
        var missing: [ClosedRange<Double>] = []
        var cursor = frame.timeRange.lowerBound
        for range in supportedRanges where range.upperBound > frame.timeRange.lowerBound
            && range.lowerBound < frame.timeRange.upperBound {
            let start = max(range.lowerBound, frame.timeRange.lowerBound)
            let end = min(range.upperBound, frame.timeRange.upperBound)
            if start > cursor { missing.append(cursor...start) }
            cursor = end
        }
        if cursor < frame.timeRange.upperBound { missing.append(cursor...frame.timeRange.upperBound) }
        return SamplePlaybackChart(prepared: PreparedCanonicalChart(frame: sampleFrame, layer: .performance,
            geometry: CanonicalGeometry(motion: MotionPath(segments: motion, timeRange: frame.timeRange),
                missingMotion: missing, fader: original.geometry.fader,
                faderEdges: original.geometry.faderEdges,
                hasUnplacedEvidence: original.geometry.hasUnplacedEvidence),
            mixerSpans: original.mixerSpans, combinedMixerSpans: original.combinedMixerSpans),
            resets: resets.filter { frame.timeRange.contains($0.time) })
    }

    private static func sampleSegments(_ segments: [MotionSegment],
                                       in range: ClosedRange<Double>) -> [MotionSegment] {
        var low = 0, high = segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].endTime <= range.lowerBound { low = middle + 1 }
            else { high = middle }
        }
        var result: [MotionSegment] = []
        while low < segments.count, segments[low].startTime < range.upperBound {
            let segment = segments[low]
            let start = max(segment.startTime, range.lowerBound)
            let end = min(segment.endTime, range.upperBound)
            func position(at time: Double) -> CGFloat {
                segment.startPosition + (segment.endPosition - segment.startPosition)
                    * CGFloat((time - segment.startTime) / (segment.endTime - segment.startTime))
            }
            result.append(MotionSegment(kind: segment.kind, startTime: start, endTime: end,
                startPosition: position(at: start), endPosition: position(at: end),
                speed: segment.speed, isGhost: segment.isGhost, evidenceStyle: segment.evidenceStyle))
            low += 1
        }
        return result
    }
}

// MARK: - Canonical evidence projection (same MotionPath and renderer)

extension ScratchStrokeGeometry {
    enum CanonicalLayer: Equatable, Sendable { case target, performance }

    /// Supplied once for a target/performance comparison. Never auto-fit either
    /// row. Time is seconds from the shared origin; position retains its unit.
    struct CanonicalFrame: Equatable, Sendable {
        let timeRange: ClosedRange<Double>
        let positionRange: ClosedRange<Double>
        let coordinateSpace: ScratchNotation.GestureRecord.CoordinateSpace
        let beatsPerMinute: Double

        init?(timeRange: ClosedRange<Double>, positionRange: ClosedRange<Double>,
              coordinateSpace: ScratchNotation.GestureRecord.CoordinateSpace,
              beatsPerMinute: Double) {
            guard timeRange.lowerBound.isFinite, timeRange.upperBound.isFinite,
                  timeRange.upperBound > timeRange.lowerBound,
                  (timeRange.upperBound - timeRange.lowerBound).isFinite,
                  positionRange.lowerBound.isFinite, positionRange.upperBound.isFinite,
                  positionRange.upperBound > positionRange.lowerBound,
                  (positionRange.upperBound - positionRange.lowerBound).isFinite,
                  beatsPerMinute.isFinite, beatsPerMinute > 0,
                  (60 / beatsPerMinute).isFinite else { return nil }
            self.timeRange = timeRange
            self.positionRange = positionRange
            self.coordinateSpace = coordinateSpace
            self.beatsPerMinute = beatsPerMinute
        }

        /// Explicit review framing only. Fit one vertical range to supported
        /// motion inside the current time window, preserving every raw point
        /// and the shared timing/coordinate unit. Comparison rows keep their
        /// supplied frame unless a caller deliberately requests this view.
        func fittingVisibleMotion(in records: [ScratchNotation.GestureRecord],
                                  layer: CanonicalLayer) -> CanonicalFrame {
            fittedVisibleMotionFrame(in: records, layer: layer) ?? self
        }

        /// Nil means no unambiguous visible evidence can establish a fitted
        /// range. Review controls must not imply zoomable motion in that case.
        func fittedVisibleMotionFrame(in records: [ScratchNotation.GestureRecord],
                                      layer: CanonicalLayer) -> CanonicalFrame? {
            typealias Record = ScratchNotation.GestureRecord
            let originalSpan = positionRange.upperBound - positionRange.lowerBound
            var lower = Double.infinity
            var upper = -Double.infinity
            var candidates: [ClosedRange<Double>] = []
            var invalid: [ClosedRange<Double>] = []

            func include(_ position: Double) {
                lower = min(lower, position)
                upper = max(upper, position)
            }
            func usablePosition(_ position: Double) -> Bool {
                position.isFinite && ((position - positionRange.lowerBound) / originalSpan).isFinite
            }
            func bounded(_ span: Record.TimeSpan, scale: Double) -> ClosedRange<Double>? {
                let start = span.startTime * scale, end = span.endTime * scale
                guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                return start...end
            }
            func visible(_ range: ClosedRange<Double>) -> ClosedRange<Double>? {
                let start = max(range.lowerBound, timeRange.lowerBound)
                let end = min(range.upperBound, timeRange.upperBound)
                return end > start ? start...end : nil
            }
            func invalidate(_ range: ClosedRange<Double>) {
                if let range = visible(range) { invalid.append(range) }
            }

            // Match the renderer's motion validity rules without rebuilding
            // its full fader/motion partition just to choose a viewport.
            for record in records {
                let scale = record.timingDomain == .beats ? 60 / beatsPerMinute : 1
                let ranges = (record.subdivisions.map(\.span) + record.internalHolds.map(\.span))
                    .compactMap { bounded($0, scale: scale) }
                let recordRange: ClosedRange<Double>
                if let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() {
                    recordRange = start...end
                } else {
                    recordRange = timeRange
                }
                guard record.coordinateSpace == coordinateSpace,
                      record.motionValidationIssues().isEmpty else {
                    invalidate(recordRange); continue
                }
                for subdivision in record.subdivisions {
                    guard let range = bounded(subdivision.span, scale: scale) else {
                        invalidate(recordRange); continue
                    }
                    let curve = layer == .target ? subdivision.targetCurve : subdivision.measuredCurve
                    guard let curve, Record.evidenceIssues(curve.evidence, platter: true).isEmpty,
                          let first = curve.startPosition, let last = curve.endPosition else {
                        invalidate(range); continue
                    }
                    let displacement = last - first
                    guard displacement.isFinite,
                          record.direction == .forward ? displacement > 0 : displacement < 0,
                          zip(curve.points, curve.points.dropFirst()).allSatisfy({ a, b in
                        let delta = b.position - a.position
                        return delta.isFinite && (record.direction == .forward ? delta >= 0 : delta <= 0)
                            && usablePosition(a.position) && usablePosition(b.position)
                            && (a.time * scale).isFinite && (b.time * scale).isFinite
                    }) else { invalidate(range); continue }
                    for (a, b) in zip(curve.points, curve.points.dropFirst()) {
                        let start = a.time * scale, end = b.time * scale
                        guard let pair = bounded(.init(startTime: a.time, endTime: b.time), scale: scale),
                              let visiblePair = visible(pair) else { continue }
                        let duration = end - start
                        guard duration.isFinite, duration > 0 else { return nil }
                        let delta = b.position - a.position
                        let startPosition = a.position + delta * ((visiblePair.lowerBound - start) / duration)
                        let endPosition = a.position + delta * ((visiblePair.upperBound - start) / duration)
                        guard startPosition.isFinite, endPosition.isFinite else { return nil }
                        candidates.append(visiblePair)
                        include(startPosition)
                        include(endPosition)
                    }
                }
                for hold in record.internalHolds {
                    guard let range = bounded(hold.span, scale: scale) else {
                        invalidate(recordRange); continue
                    }
                    guard Record.evidenceIssues(hold.evidence, platter: true).isEmpty,
                          let position = hold.position, usablePosition(position) else {
                        invalidate(range); continue
                    }
                    guard let visibleHold = visible(range) else { continue }
                    candidates.append(visibleHold)
                    include(position)
                }
            }

            // An overlapping curve or invalid interval is UNKNOWN in the
            // renderer. Conservatively retain the original scale for the
            // whole window instead of fitting any of those invisible points.
            // Sorting once keeps this check O(n log n), not a chart partition.
            candidates.sort { $0.lowerBound < $1.lowerBound }
            invalid.sort { $0.lowerBound < $1.lowerBound }
            var previousEnd = -Double.infinity
            var invalidIndex = 0
            for candidate in candidates {
                guard candidate.lowerBound >= previousEnd else { return nil }
                previousEnd = candidate.upperBound
                while invalidIndex < invalid.count,
                      invalid[invalidIndex].upperBound <= candidate.lowerBound {
                    invalidIndex += 1
                }
                if invalidIndex < invalid.count,
                   invalid[invalidIndex].lowerBound < candidate.upperBound {
                    return nil
                }
            }

            guard lower.isFinite, upper.isFinite else { return nil }
            let span = upper - lower
            guard span.isFinite else { return nil }
            // Flat, explicitly observed holds still get a usable centered
            // viewport; absent motion never manufactures a zero baseline.
            let padding = span > 0 ? span * 0.125
                : max(originalSpan * 0.005, max(abs(lower) * 1e-9, 1e-9))
            let fittedLower = lower - padding, fittedUpper = upper + padding
            guard fittedLower.isFinite, fittedUpper.isFinite,
                  fittedUpper > fittedLower else { return nil }
            return CanonicalFrame(timeRange: timeRange, positionRange: fittedLower...fittedUpper,
                                  coordinateSpace: coordinateSpace, beatsPerMinute: beatsPerMinute)
        }
    }

    struct CanonicalFaderInterval: Equatable, Sendable {
        let range: ClosedRange<Double>
        /// Nil is explicitly unknown, never an open/closed rail.
        let state: ScratchNotationFaderState?
    }

    struct CanonicalFaderEdge: Equatable, Sendable {
        let time: Double
        let state: ScratchNotationFaderState
    }

    struct CanonicalGeometry: Equatable, Sendable {
        let motion: MotionPath
        let missingMotion: [ClosedRange<Double>]
        let fader: [CanonicalFaderInterval]
        let faderEdges: [CanonicalFaderEdge]
        /// Malformed evidence without a usable time cannot be placed on a grid.
        let hasUnplacedEvidence: Bool
    }

    /// Size-independent drawing input. Live callers prepare this on their
    /// worker; Canvas only maps the retained geometry into its current size.
    /// No evidence is decimated, persisted or fed back into capture.
    struct PreparedCanonicalChart: Equatable, Sendable {
        let frame: CanonicalFrame
        let layer: CanonicalLayer
        let geometry: CanonicalGeometry
        let mixerSpans: [ScratchMixerFaderEvidence.Control: [ScratchMixerFaderEvidence.Span]]?
        let combinedMixerSpans: [ScratchMixerFaderEvidence.Span]?

        init(records: [ScratchNotation.GestureRecord], layer: CanonicalLayer,
             frame: CanonicalFrame, wrapPeriod: Double? = nil,
             mixerFaders: ScratchMixerFaderEvidence? = nil) {
            self.frame = frame
            self.layer = layer
            geometry = canonicalGeometry(records: records, layer: layer,
                                         frame: frame, wrapPeriod: wrapPeriod)
            mixerSpans = mixerFaders.map { evidence in
                Dictionary(uniqueKeysWithValues: ScratchMixerFaderEvidence.Control.allCases.map {
                    ($0, evidence.spans(for: $0, in: frame.timeRange))
                })
            }
            combinedMixerSpans = mixerFaders?.combinedSpans(in: frame.timeRange)
        }

        init(frame: CanonicalFrame, layer: CanonicalLayer,
                         geometry: CanonicalGeometry,
                         mixerSpans: [ScratchMixerFaderEvidence.Control: [ScratchMixerFaderEvidence.Span]]?,
                         combinedMixerSpans: [ScratchMixerFaderEvidence.Span]?) {
            self.frame = frame
            self.layer = layer
            self.geometry = geometry
            self.mixerSpans = mixerSpans
            self.combinedMixerSpans = combinedMixerSpans
        }
    }

    /// Preserves every supplied curve point and hold position. No speed bucket,
    /// ratio template, release assumption, click threshold or curve fallback.
    /// Piecewise linear clipping at stream boundaries preserves the local slope.
    /// - Parameter wrapPeriod: PRESENTATION ONLY. When supplied, platter
    ///   position is drawn as bounded sample-loop PHASE instead of unbounded
    ///   displacement: the lane's bottom is phase 0 and its top is one loop
    ///   period, and a measured span that crosses a loop boundary is emitted
    ///   as two separate segments meeting at the top and the bottom. No
    ///   segment is emitted BETWEEN them, and that absence is the pen-up —
    ///   the renderer strokes each segment's own path, so nothing connects
    ///   the top back down to the bottom.
    ///
    ///   This never reaches the physical decoder, never becomes a movement
    ///   event, never changes a record's `direction`, and never mints a hold,
    ///   a reversal or a MOTION UNKNOWN band: a wrap is a discontinuity in
    ///   how measured travel is DRAWN, not evidence of anything happening on
    ///   the platter. `nil` (the default) keeps the unbounded behaviour
    ///   byte-for-byte, which is what every finalized, Practice and iOS
    ///   caller gets.
    static func canonicalGeometry(
        records: [ScratchNotation.GestureRecord], layer: CanonicalLayer,
        frame: CanonicalFrame, wrapPeriod: Double? = nil
    ) -> CanonicalGeometry {
        typealias Record = ScratchNotation.GestureRecord
        var candidates: [MotionSegment] = []
        var invalidMotion: [ClosedRange<Double>] = []
        var fader: [CanonicalFaderInterval] = []
        var edges: [CanonicalFaderEdge] = []
        var unplaced = false

        func normalized(_ position: Double) -> CGFloat {
            CGFloat((position - frame.positionRange.lowerBound)
                / (frame.positionRange.upperBound - frame.positionRange.lowerBound))
        }
        // A period must be usable before it can bound anything; an absent,
        // non-finite or non-positive one leaves the lane exactly as it was.
        let loopPeriod: Double? = {
            guard let wrapPeriod, wrapPeriod.isFinite, wrapPeriod > 0 else { return nil }
            return wrapPeriod
        }()
        // Bound presentation expansion before the shared partition below.
        // Any unsafe numeric step or excessive split count reuses the complete
        // unwrapped geometry; it never drops evidence or returns a partial loop.
        var remainingLoopPieces = 4_096
        /// Position -> lane fraction. With a loop period the lane spans ONE
        /// period, so the fraction is the wrapped phase; without one this is
        /// the existing frame mapping, unchanged.
        func laneNormalized(_ position: Double) -> CGFloat {
            guard let loopPeriod else { return normalized(position) }
            var phase = position.truncatingRemainder(dividingBy: loopPeriod)
            if phase < 0 { phase += loopPeriod }
            return CGFloat(phase / loopPeriod)
        }
        /// Which loop this span sits in. Read from the span's OWN start so a
        /// forward span ending exactly on a boundary reads as the top of the
        /// loop it travelled through rather than the bottom of the next one,
        /// and a backward span starting exactly on one reads as the top of
        /// the loop below.
        func lapIndex(startPosition: Double, forward: Bool, period: Double) -> Double {
            forward
                ? (startPosition / period).rounded(.down)
                : (startPosition / period).rounded(.up) - 1
        }
        /// One measured curve pair, split at every loop boundary it crosses.
        /// Time is interpolated linearly in position, so each piece keeps the
        /// measured slope it actually had. Nil requests a complete unwrapped fallback.
        func loopSpans(
            from a: ScratchNotation.GestureRecord.CurvePoint,
            to b: ScratchNotation.GestureRecord.CurvePoint,
            period: Double
        ) -> [(startTime: Double, endTime: Double, startPosition: CGFloat, endPosition: CGFloat)]? {
            let travel = b.position - a.position
            let startLap = a.position / period
            let endLap = b.position / period
            let estimatedPieces = abs(endLap - startLap).rounded(.up) + 1
            guard travel.isFinite, startLap.isFinite, endLap.isFinite,
                  estimatedPieces.isFinite, estimatedPieces <= Double(remainingLoopPieces) else {
                return nil
            }
            let forward = travel >= 0
            var cuts: [Double] = []
            if travel != 0 {
                let base = forward ? startLap.rounded(.down) : startLap.rounded(.up)
                var k = base + (forward ? 1 : -1)
                guard forward ? k > base : k < base else {
                    return nil
                }
                while true {
                    let cut = k * period
                    guard cut.isFinite else {
                        return nil
                    }
                    if forward ? cut >= b.position : cut <= b.position { break }
                    guard (forward ? cut > (cuts.last ?? a.position) : cut < (cuts.last ?? a.position)),
                          cuts.count + 1 < remainingLoopPieces else {
                        return nil
                    }
                    cuts.append(cut)
                    let next = k + (forward ? 1 : -1)
                    guard forward ? next > k : next < k else {
                        return nil
                    }
                    k = next
                }
            }
            var pieces: [(Double, Double, Double, Double)] = []
            var startTime = a.time, startPosition = a.position
            for cut in cuts {
                let fraction = (cut - a.position) / travel
                let time = a.time + (b.time - a.time) * fraction
                guard time.isFinite, time > startTime, time < b.time else {
                    return nil
                }
                pieces.append((startTime, time, startPosition, cut))
                startTime = time; startPosition = cut
            }
            pieces.append((startTime, b.time, startPosition, b.position))
            remainingLoopPieces -= pieces.count
            return pieces.compactMap { piece in
                let lap = lapIndex(startPosition: piece.2, forward: forward, period: period)
                func fraction(_ position: Double) -> CGFloat {
                    CGFloat((position - lap * period) / period)
                }
                guard piece.1 > piece.0 else { return nil }
                return (piece.0, piece.1, fraction(piece.2), fraction(piece.3))
            }
        }
        func bounded(_ span: Record.TimeSpan, scale: Double) -> ClosedRange<Double>? {
            let start = span.startTime * scale, end = span.endTime * scale
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return start...end
        }
        func supported(_ evidence: Record.Evidence, platter: Bool) -> Bool {
            Record.evidenceIssues(evidence, platter: platter).isEmpty
        }

        for record in records {
            let scale = record.timingDomain == .beats ? 60 / frame.beatsPerMinute : 1
            let ranges = (record.subdivisions.map(\.span) + record.internalHolds.map(\.span))
                .compactMap { bounded($0, scale: scale) }
            let recordRange: ClosedRange<Double>
            if let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() {
                recordRange = start...end
            } else {
                recordRange = frame.timeRange
                unplaced = true
            }

            if record.coordinateSpace != frame.coordinateSpace || !record.motionValidationIssues().isEmpty {
                invalidMotion.append(recordRange)
            } else {
                for subdivision in record.subdivisions {
                    guard let range = bounded(subdivision.span, scale: scale) else {
                        invalidMotion.append(recordRange); unplaced = true; continue
                    }
                    let curve = layer == .target ? subdivision.targetCurve : subdivision.measuredCurve
                    guard let curve, supported(curve.evidence, platter: true) else {
                        invalidMotion.append(range); continue
                    }
                    // A direction label cannot turn contrary or wholly stationary
                    // samples into travel. Local measured plateaus remain flat;
                    // they do not acquire a tear label or a fader glyph.
                    let pairs = Array(zip(curve.points, curve.points.dropFirst()))
                    guard let startPosition = curve.startPosition, let endPosition = curve.endPosition else {
                        invalidMotion.append(range); continue
                    }
                    let displacement = endPosition - startPosition
                    guard displacement.isFinite,
                          record.direction == .forward ? displacement > 0 : displacement < 0,
                          pairs.allSatisfy({ a, b in
                        let delta = b.position - a.position
                        return delta.isFinite && (record.direction == .forward ? delta >= 0 : delta <= 0)
                            && laneNormalized(a.position).isFinite && laneNormalized(b.position).isFinite
                            && (a.time * scale).isFinite && (b.time * scale).isFinite
                    }) else { invalidMotion.append(range); continue }
                    for (a, b) in pairs {
                        guard let loopPeriod else {
                            candidates.append(MotionSegment(kind: .stroke(record.direction),
                                startTime: a.time * scale, endTime: b.time * scale,
                                startPosition: normalized(a.position), endPosition: normalized(b.position),
                                speed: .medium, isGhost: false, evidenceStyle: .unknownFader))
                            continue
                        }
                        guard let pieces = loopSpans(from: a, to: b, period: loopPeriod) else {
                            return canonicalGeometry(records: records, layer: layer, frame: frame)
                        }
                        for piece in pieces {
                            candidates.append(MotionSegment(kind: .stroke(record.direction),
                                startTime: piece.startTime * scale, endTime: piece.endTime * scale,
                                startPosition: piece.startPosition, endPosition: piece.endPosition,
                                speed: .medium, isGhost: false, evidenceStyle: .unknownFader))
                        }
                    }
                }
                for hold in record.internalHolds {
                    guard let range = bounded(hold.span, scale: scale) else {
                        invalidMotion.append(recordRange); unplaced = true; continue
                    }
                    guard let position = hold.position, laneNormalized(position).isFinite else {
                        invalidMotion.append(range); continue
                    }
                    candidates.append(MotionSegment(kind: .hold,
                        startTime: range.lowerBound, endTime: range.upperBound,
                        startPosition: laneNormalized(position), endPosition: laneNormalized(position),
                        speed: .medium, isGhost: false, evidenceStyle: .unknownFader))
                }
            }

            // Fader is independent, including when the platter is unavailable.
            guard record.faderValidationIssues().isEmpty else {
                fader.append(.init(range: recordRange, state: nil))
                unplaced = true
                continue
            }
            for interval in record.faderIntervals {
                guard let range = bounded(interval.span, scale: scale) else {
                    fader.append(.init(range: recordRange, state: nil)); unplaced = true; continue
                }
                fader.append(.init(range: range,
                    state: supported(interval.evidence, platter: false) ? interval.state : nil))
            }
            for edge in record.faderTransitions {
                let time = edge.time * scale
                guard time.isFinite, time >= 0, supported(edge.evidence, platter: false) else {
                    unplaced = true; continue
                }
                edges.append(.init(time: time, state: edge.state))
            }
        }

        // One partition over the actual evidence boundaries, shared by both
        // streams. Uncovered or overlapping motion is an explicit gap, never
        // a baseline or a connector between independently observed points.
        var boundaries = [frame.timeRange.lowerBound, frame.timeRange.upperBound]
        boundaries += candidates.flatMap { [$0.startTime, $0.endTime] }
        boundaries += invalidMotion.flatMap { [$0.lowerBound, $0.upperBound] }
        boundaries += fader.flatMap { [$0.range.lowerBound, $0.range.upperBound] }
        boundaries = Array(Set(boundaries.filter { frame.timeRange.contains($0) })).sorted()
        var motion: [MotionSegment] = []
        var missing: [ClosedRange<Double>] = []
        var rails: [CanonicalFaderInterval] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let midpoint = start + (end - start) / 2
            let coveringFader = fader.filter { $0.range.lowerBound <= midpoint && midpoint < $0.range.upperBound }
            let state = coveringFader.count == 1 ? coveringFader[0].state : nil
            if let last = rails.last, last.state == state, last.range.upperBound == start {
                rails[rails.count - 1] = .init(range: last.range.lowerBound...end, state: state)
            } else { rails.append(.init(range: start...end, state: state)) }

            let coveringMotion = candidates.filter { $0.startTime <= midpoint && midpoint < $0.endTime }
            guard coveringMotion.count == 1,
                  !invalidMotion.contains(where: { $0.lowerBound <= midpoint && midpoint < $0.upperBound }) else {
                if let last = missing.last, last.upperBound == start {
                    missing[missing.count - 1] = last.lowerBound...end
                } else { missing.append(start...end) }
                continue
            }
            let segment = coveringMotion[0]
            func position(_ time: Double) -> CGFloat {
                segment.startPosition + (segment.endPosition - segment.startPosition)
                    * CGFloat((time - segment.startTime) / (segment.endTime - segment.startTime))
            }
            let evidenceStyle: MotionSegment.EvidenceStyle
            switch state {
            case .open: evidenceStyle = .open
            case .closed: evidenceStyle = .closed
            case nil: evidenceStyle = .unknownFader
            }
            motion.append(MotionSegment(kind: segment.kind, startTime: start, endTime: end,
                startPosition: position(start), endPosition: position(end), speed: .medium,
                isGhost: false, evidenceStyle: evidenceStyle))
        }
        // Explicit fader observations alone mint glyphs. No pairing threshold,
        // no hold-derived click and no synthetic transition across a data gap.
        let groupedEdges = Dictionary(grouping: edges, by: \.time)
        let uniqueEdges = groupedEdges.keys.sorted().compactMap { time -> CanonicalFaderEdge? in
            guard frame.timeRange.contains(time), let atTime = groupedEdges[time],
                  let first = atTime.first else { return nil }
            guard atTime.allSatisfy({ $0.state == first.state }) else { unplaced = true; return nil }
            return first
        }
        return CanonicalGeometry(motion: MotionPath(segments: motion, timeRange: frame.timeRange),
            missingMotion: missing, fader: rails, faderEdges: uniqueEdges,
            hasUnplacedEvidence: unplaced)
    }
}
