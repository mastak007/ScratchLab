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

    /// Preserves every supplied curve point and hold position. No speed bucket,
    /// ratio template, release assumption, click threshold or curve fallback.
    /// Piecewise linear clipping at stream boundaries preserves the local slope.
    static func canonicalGeometry(
        records: [ScratchNotation.GestureRecord], layer: CanonicalLayer,
        frame: CanonicalFrame
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
                            && normalized(a.position).isFinite && normalized(b.position).isFinite
                            && (a.time * scale).isFinite && (b.time * scale).isFinite
                    }) else { invalidMotion.append(range); continue }
                    for (a, b) in pairs {
                        candidates.append(MotionSegment(kind: .stroke(record.direction),
                            startTime: a.time * scale, endTime: b.time * scale,
                            startPosition: normalized(a.position), endPosition: normalized(b.position),
                            speed: .medium, isGhost: false, evidenceStyle: .unknownFader))
                    }
                }
                for hold in record.internalHolds {
                    guard let range = bounded(hold.span, scale: scale) else {
                        invalidMotion.append(recordRange); unplaced = true; continue
                    }
                    guard let position = hold.position, normalized(position).isFinite else {
                        invalidMotion.append(range); continue
                    }
                    candidates.append(MotionSegment(kind: .hold,
                        startTime: range.lowerBound, endTime: range.upperBound,
                        startPosition: normalized(position), endPosition: normalized(position),
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
