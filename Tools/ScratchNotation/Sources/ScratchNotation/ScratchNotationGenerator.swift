//
//  ScratchNotationGenerator.swift
//  ScratchNotation
//
//  Fuses audio + visual evidence (with optional beat grid) into an inferred
//  per-take notation timeline. Missing or low-confidence evidence becomes
//  `unknown` events — the generator never invents a label it can't justify.
//
//  Algorithm:
//    1. Take the union of all event start/end times to form a set of breakpoints.
//    2. Walk the timeline left-to-right, one segment per breakpoint pair.
//    3. For each segment, summarise the audio evidence (onset / silence / none)
//       and the dominant visual motion (forward / back / still / unknown).
//    4. Map (audio, visual) -> (type, direction, source, confidence) per the
//       table in `resolve(audio:visual:)`.
//    5. Merge adjacent segments that share `(type, direction, source)` to
//       reduce fragmentation while preserving boundaries.
//

import Foundation

public struct ScratchNotationGenerator: Sendable {

    public init() {}

    public func generate(
        takeID: String,
        scratchType: String,
        beatMode: DatasetNotationBeatMode,
        duration: TimeInterval,
        bpm: Int? = nil,
        audioOnsets: [AudioOnsetEvent] = [],
        audioSilences: [AudioSilenceEvent] = [],
        visualMotion: [VisualMotionEvent] = [],
        beatGrid: BeatGrid? = nil
    ) -> DatasetNotationTimeline {
        guard duration > 0 else {
            return DatasetNotationTimeline(
                takeID: takeID,
                scratchType: scratchType,
                bpm: bpm,
                beatMode: beatMode,
                duration: 0,
                events: [],
                approvalState: .inferred
            )
        }

        let breakpoints = makeBreakpoints(
            duration: duration,
            onsets: audioOnsets,
            silences: audioSilences,
            visual: visualMotion
        )

        var raw: [DatasetNotationEvent] = []
        for i in 0..<(breakpoints.count - 1) {
            let s = breakpoints[i]
            let e = breakpoints[i + 1]
            if e - s < Constants.minSegment { continue }

            let audio = audioSummary(start: s, end: e, onsets: audioOnsets, silences: audioSilences)
            let visual = visualSummary(start: s, end: e, motion: visualMotion)
            let resolved = resolve(audio: audio, visual: visual)

            raw.append(DatasetNotationEvent(
                type: resolved.type,
                direction: resolved.direction,
                startTime: s,
                endTime: e,
                beatPosition: beatGrid?.beatPosition(at: s),
                source: resolved.source,
                confidence: resolved.confidence,
                approved: false
            ))
        }

        let merged = mergeAdjacent(raw)

        return DatasetNotationTimeline(
            takeID: takeID,
            scratchType: scratchType,
            bpm: bpm,
            beatMode: beatMode,
            duration: duration,
            events: merged,
            approvalState: .inferred
        )
    }

    // MARK: - Internals

    private enum Constants {
        static let minSegment: TimeInterval = 0.001
        static let visionOnlyConfidenceScale = 0.5
        static let unknownConfidence: Double = 0.0
    }

    private struct AudioSummary {
        enum Kind { case onset, silence, none }
        var kind: Kind
        var confidence: Double
    }

    private struct VisualSummary {
        var direction: DatasetNotationDirection  // forward | back | none | unknown
        var confidence: Double
    }

    private struct Resolved {
        var type: DatasetNotationEventType
        var direction: DatasetNotationDirection
        var source: DatasetNotationSource
        var confidence: Double
    }

    private func makeBreakpoints(
        duration: TimeInterval,
        onsets: [AudioOnsetEvent],
        silences: [AudioSilenceEvent],
        visual: [VisualMotionEvent]
    ) -> [TimeInterval] {
        var pts: Set<TimeInterval> = [0, duration]
        for o in onsets {
            pts.insert(clamp(o.startTime, to: duration))
            pts.insert(clamp(o.endTime, to: duration))
        }
        for s in silences {
            pts.insert(clamp(s.startTime, to: duration))
            pts.insert(clamp(s.endTime, to: duration))
        }
        for v in visual {
            pts.insert(clamp(v.startTime, to: duration))
            pts.insert(clamp(v.endTime, to: duration))
        }
        return pts.sorted()
    }

    private func clamp(_ t: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        return max(0, min(duration, t))
    }

    /// Audio activity dominating the segment [start, end].
    /// Onsets win over silences if both overlap (a stroke can sit inside a
    /// nominal silence detector window if thresholds disagree).
    private func audioSummary(
        start: TimeInterval,
        end: TimeInterval,
        onsets: [AudioOnsetEvent],
        silences: [AudioSilenceEvent]
    ) -> AudioSummary {
        var onsetOverlap: TimeInterval = 0
        var onsetConfWeighted: Double = 0
        for o in onsets {
            let dur = overlap(start, end, o.startTime, o.endTime)
            if dur > 0 {
                onsetOverlap += dur
                onsetConfWeighted += o.confidence * dur
            }
        }
        if onsetOverlap > 0 {
            return AudioSummary(kind: .onset, confidence: onsetConfWeighted / onsetOverlap)
        }

        var silenceOverlap: TimeInterval = 0
        var silenceConfWeighted: Double = 0
        for s in silences {
            let dur = overlap(start, end, s.startTime, s.endTime)
            if dur > 0 {
                silenceOverlap += dur
                silenceConfWeighted += s.confidence * dur
            }
        }
        if silenceOverlap > 0 {
            return AudioSummary(kind: .silence, confidence: silenceConfWeighted / silenceOverlap)
        }

        return AudioSummary(kind: .none, confidence: 0)
    }

    /// Dominant visual direction by overlap-weighted vote, plus the average
    /// confidence of the contributing visual events.
    private func visualSummary(
        start: TimeInterval,
        end: TimeInterval,
        motion: [VisualMotionEvent]
    ) -> VisualSummary {
        var totals: [DatasetNotationDirection: TimeInterval] = [:]
        var conf: [DatasetNotationDirection: Double] = [:]
        for v in motion {
            let dur = overlap(start, end, v.startTime, v.endTime)
            if dur > 0 {
                let mapped = mapVisual(v.direction)
                totals[mapped, default: 0] += dur
                conf[mapped, default: 0] += v.confidence * dur
            }
        }
        guard let winner = totals.max(by: { $0.value < $1.value })?.key else {
            return VisualSummary(direction: .unknown, confidence: 0)
        }
        let weight = totals[winner] ?? 0
        let avg = weight > 0 ? (conf[winner] ?? 0) / weight : 0
        return VisualSummary(direction: winner, confidence: avg)
    }

    private func mapVisual(_ kind: VisualMotionDirection) -> DatasetNotationDirection {
        switch kind {
        case .forward: return .forward
        case .back:    return .back
        case .still:   return .none
        }
    }

    /// (audio, visual) -> (type, direction, source, confidence) decision table.
    private func resolve(audio: AudioSummary, visual: VisualSummary) -> Resolved {
        switch (audio.kind, visual.direction) {

        // --- Audio onset present ---
        case (.onset, .forward), (.onset, .back):
            return Resolved(
                type: .stroke,
                direction: visual.direction,
                source: .fused,
                confidence: (audio.confidence + visual.confidence) / 2.0
            )
        case (.onset, .none):
            // Audio says stroke, vision says still — keep as a stroke but admit
            // we don't trust the direction. Source is audio-only because the
            // visual evidence contradicts a directional stroke.
            return Resolved(
                type: .stroke,
                direction: .unknown,
                source: .audio,
                confidence: audio.confidence
            )
        case (.onset, .unknown):
            return Resolved(
                type: .stroke,
                direction: .unknown,
                source: .audio,
                confidence: audio.confidence
            )

        // --- Audio silence present ---
        case (.silence, .forward), (.silence, .back):
            // Silent move (e.g. fader cut) — visual direction is meaningful but
            // audio carries no scratch sound, so confidence is discounted.
            return Resolved(
                type: .stroke,
                direction: visual.direction,
                source: .vision,
                confidence: visual.confidence * Constants.visionOnlyConfidenceScale
            )
        case (.silence, .none):
            return Resolved(
                type: .hold,
                direction: .none,
                source: .fused,
                confidence: (audio.confidence + visual.confidence) / 2.0
            )
        case (.silence, .unknown):
            return Resolved(
                type: .silence,
                direction: .none,
                source: .audio,
                confidence: audio.confidence
            )

        // --- No audio evidence at all ---
        case (.none, .forward), (.none, .back):
            return Resolved(
                type: .stroke,
                direction: visual.direction,
                source: .vision,
                confidence: visual.confidence * Constants.visionOnlyConfidenceScale
            )
        case (.none, .none):
            return Resolved(
                type: .hold,
                direction: .none,
                source: .vision,
                confidence: visual.confidence * Constants.visionOnlyConfidenceScale
            )
        case (.none, .unknown):
            return Resolved(
                type: .unknown,
                direction: .unknown,
                source: .audio,
                confidence: Constants.unknownConfidence
            )
        }
    }

    /// Collapse adjacent events that share type+direction+source into one,
    /// averaging their confidence weighted by duration.
    private func mergeAdjacent(_ events: [DatasetNotationEvent]) -> [DatasetNotationEvent] {
        var out: [DatasetNotationEvent] = []
        for ev in events {
            if let last = out.last,
               last.type == ev.type,
               last.direction == ev.direction,
               last.source == ev.source,
               abs(last.endTime - ev.startTime) < Constants.minSegment {
                let lastDur = max(0, last.endTime - last.startTime)
                let evDur = max(0, ev.endTime - ev.startTime)
                let totalDur = lastDur + evDur
                let weighted = totalDur > 0
                    ? (last.confidence * lastDur + ev.confidence * evDur) / totalDur
                    : (last.confidence + ev.confidence) / 2.0
                out[out.count - 1] = DatasetNotationEvent(
                    id: last.id,
                    type: last.type,
                    direction: last.direction,
                    startTime: last.startTime,
                    endTime: ev.endTime,
                    beatPosition: last.beatPosition,
                    source: last.source,
                    confidence: weighted,
                    approved: last.approved && ev.approved
                )
            } else {
                out.append(ev)
            }
        }
        return out
    }
}

private func overlap(_ a1: TimeInterval, _ a2: TimeInterval,
                     _ b1: TimeInterval, _ b2: TimeInterval) -> TimeInterval {
    return max(0, min(a2, b2) - max(a1, b1))
}
