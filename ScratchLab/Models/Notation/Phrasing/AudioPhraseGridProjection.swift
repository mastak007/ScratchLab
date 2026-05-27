import Foundation

/// Musical-grid projection of a single `AudioPhraseSpan`. `phraseIndex`
/// matches the span's position in the source `AudioPhraseSummary.spans`
/// array so callers can pair projections back with the originating span
/// without a secondary lookup. `startPosition` / `endPosition` come straight
/// from `TimingGrid.position(at:)` and inherit its behaviour for
/// pre-origin times (negative `bar` indices, no clamping). `durationInBars`
/// is the raw `(endTime - startTime) / secondsPerBar` ratio — no rounding,
/// no snapping.
struct AudioPhraseGridProjection: Equatable, Sendable, Codable {
    let phraseIndex: Int
    let startPosition: GridPosition
    let endPosition: GridPosition
    let durationInBars: Double
}

/// Output of `AudioPhraseGridProjector.project(_:onto:)`. Carries one
/// `AudioPhraseGridProjection` per `AudioPhraseSpan` in the source
/// summary, in the same order.
struct AudioPhraseGridSummary: Equatable, Sendable, Codable {
    let projections: [AudioPhraseGridProjection]

    static let empty = AudioPhraseGridSummary(projections: [])
}

/// Pure, deterministic transform from `(AudioPhraseSummary, TimingGrid)`
/// to `AudioPhraseGridSummary`. No clock, no global state, no I/O. No
/// snapping or clamping — every projection is the literal grid mapping
/// of the span's start/end times.
enum AudioPhraseGridProjector {
    static func project(
        _ summary: AudioPhraseSummary,
        onto grid: TimingGrid
    ) -> AudioPhraseGridSummary {
        let secondsPerBar = grid.secondsPerBar
        var projections: [AudioPhraseGridProjection] = []
        projections.reserveCapacity(summary.spans.count)
        for (index, span) in summary.spans.enumerated() {
            projections.append(
                AudioPhraseGridProjection(
                    phraseIndex: index,
                    startPosition: grid.position(at: span.startTime),
                    endPosition: grid.position(at: span.endTime),
                    durationInBars: (span.endTime - span.startTime) / secondsPerBar
                )
            )
        }
        return AudioPhraseGridSummary(projections: projections)
    }
}
