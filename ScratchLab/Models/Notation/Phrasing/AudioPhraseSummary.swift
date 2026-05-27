import Foundation

/// Bounds of a single grouped audio phrase plus the per-kind counters needed
/// by downstream phrase-aware logic. Index fields preserve the position of
/// the first and last contributing event in the original `audioEvents`
/// array so callers can map a span back to its source events without a
/// separate lookup. `terminalDragDuration` is only populated when the
/// phrase's final drag satisfies the dominance + min-length rule applied by
/// `AudioPhraseGrouper`; it is `nil` otherwise.
struct AudioPhraseSpan: Equatable, Hashable, Sendable {
    let startTime: Double
    let endTime: Double
    let firstEventIndex: Int
    let lastEventIndex: Int
    let activeEventCount: Int
    let possibleDragCount: Int
    let scratchBurstCount: Int
    let possibleCutCount: Int
    let highConfidenceDragCount: Int
    let terminalDragDuration: Double?

    var duration: Double { endTime - startTime }
}

/// Output of `AudioPhraseGrouper.summary(for:)`. Carries the grouped spans
/// together with the thresholds used to produce them so a consumer can tell
/// whether two summaries are directly comparable.
struct AudioPhraseSummary: Equatable, Hashable, Sendable {
    let spans: [AudioPhraseSpan]
    let gapThresholdSeconds: Double
    let highConfidenceThreshold: Double
    let releaseTailMinSeconds: Double

    static let empty = AudioPhraseSummary(
        spans: [],
        gapThresholdSeconds: AudioPhraseGrouper.defaultGapThresholdSeconds,
        highConfidenceThreshold: AudioPhraseGrouper.defaultHighConfidenceThreshold,
        releaseTailMinSeconds: AudioPhraseGrouper.defaultReleaseTailMinSeconds
    )
}

/// Pure, deterministic transform from a sequence of `DetectedNotationAudioEvent`
/// values to an `AudioPhraseSummary`. No clock, no global state, no I/O.
enum AudioPhraseGrouper {
    static let defaultGapThresholdSeconds: Double = 2.0
    static let defaultHighConfidenceThreshold: Double = 0.5
    static let defaultReleaseTailMinSeconds: Double = 1.0

    static let silenceGapKind = "silenceGap"
    static let possibleDragKind = "possibleDrag"
    static let scratchBurstKind = "scratchBurst"
    static let possibleCutKind = "possibleCut"

    static func summary(
        for audioEvents: [CaptureCore.DetectedNotationAudioEvent],
        gapThresholdSeconds: Double = defaultGapThresholdSeconds,
        highConfidenceThreshold: Double = defaultHighConfidenceThreshold,
        releaseTailMinSeconds: Double = defaultReleaseTailMinSeconds
    ) -> AudioPhraseSummary {
        var spans: [AudioPhraseSpan] = []
        var current: Working?

        for (index, event) in audioEvents.enumerated() {
            if event.eventKind == silenceGapKind { continue }

            if let working = current {
                let gap = event.startTime - working.endTime
                if gap > gapThresholdSeconds {
                    spans.append(working.finalize(releaseTailMinSeconds: releaseTailMinSeconds))
                    current = nil
                }
            }

            if current == nil {
                current = Working(
                    firstEventIndex: index,
                    lastEventIndex: index,
                    startTime: event.startTime,
                    endTime: event.endTime
                )
            }

            current?.absorb(
                event: event,
                index: index,
                highConfidenceThreshold: highConfidenceThreshold
            )
        }

        if let working = current {
            spans.append(working.finalize(releaseTailMinSeconds: releaseTailMinSeconds))
        }

        return AudioPhraseSummary(
            spans: spans,
            gapThresholdSeconds: gapThresholdSeconds,
            highConfidenceThreshold: highConfidenceThreshold,
            releaseTailMinSeconds: releaseTailMinSeconds
        )
    }

    private struct Working {
        var firstEventIndex: Int
        var lastEventIndex: Int
        var startTime: Double
        var endTime: Double
        var activeEventCount: Int = 0
        var possibleDragCount: Int = 0
        var scratchBurstCount: Int = 0
        var possibleCutCount: Int = 0
        var highConfidenceDragCount: Int = 0
        var trailingDragDuration: Double = 0
        var maxDragDuration: Double = 0

        mutating func absorb(
            event: CaptureCore.DetectedNotationAudioEvent,
            index: Int,
            highConfidenceThreshold: Double
        ) {
            lastEventIndex = index
            if event.endTime > endTime { endTime = event.endTime }
            activeEventCount += 1
            switch event.eventKind {
            case AudioPhraseGrouper.possibleDragKind:
                possibleDragCount += 1
                trailingDragDuration = event.duration
                if event.duration > maxDragDuration { maxDragDuration = event.duration }
                if event.confidence >= highConfidenceThreshold {
                    highConfidenceDragCount += 1
                }
            case AudioPhraseGrouper.scratchBurstKind:
                scratchBurstCount += 1
                trailingDragDuration = 0
            case AudioPhraseGrouper.possibleCutKind:
                possibleCutCount += 1
                trailingDragDuration = 0
            default:
                trailingDragDuration = 0
            }
        }

        func finalize(releaseTailMinSeconds: Double) -> AudioPhraseSpan {
            let terminal: Double?
            if trailingDragDuration > 0
                && trailingDragDuration >= releaseTailMinSeconds
                && trailingDragDuration >= maxDragDuration {
                terminal = trailingDragDuration
            } else {
                terminal = nil
            }
            return AudioPhraseSpan(
                startTime: startTime,
                endTime: endTime,
                firstEventIndex: firstEventIndex,
                lastEventIndex: lastEventIndex,
                activeEventCount: activeEventCount,
                possibleDragCount: possibleDragCount,
                scratchBurstCount: scratchBurstCount,
                possibleCutCount: possibleCutCount,
                highConfidenceDragCount: highConfidenceDragCount,
                terminalDragDuration: terminal
            )
        }
    }
}
