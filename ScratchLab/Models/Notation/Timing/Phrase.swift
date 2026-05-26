import Foundation

// MARK: - Phrase

/// A bar-bounded span on a `TimingGrid`, identified by its starting bar
/// and length in whole bars.
///
/// The phrase model is intentionally minimal:
///
/// - **Bar-only granularity.** `startBar` and `barCount` together
///   address a half-open bar range `[startBar, startBar + barCount)`.
///   Beat and subdivision granularity belong to `GridPosition`, not
///   here. `contains(_:)` checks only the `bar` field of the queried
///   `GridPosition`; beat / subdivision / phase are ignored.
///
/// - **No primitive coupling.** A `Phrase` does not own primitives and
///   does not carry annotation references. Sidecar layers that pair
///   primitives with phrases live above this type and are out of
///   scope for this slice.
///
/// - **Origin is the grid's responsibility.** `startTime(using:)` and
///   `endTime(using:)` defer entirely to `TimingGrid.time(of:)`. A
///   phrase is grid-agnostic in storage and grid-aware only in
///   conversion.
///
/// - **No timing tolerance, no scoring.** Drift evaluation, snapping,
///   and any "did the user land inside this phrase" semantics belong
///   to `TimingWindowEvaluator` and future slices, not here.
struct Phrase: Equatable, Sendable, Codable {
    let startBar: Int
    let barCount: Int

    init?(startBar: Int, barCount: Int) {
        guard barCount > 0 else { return nil }
        self.startBar = startBar
        self.barCount = barCount
    }

    /// First bar index **not** included in this phrase.
    /// `endBarExclusive == startBar + barCount`.
    var endBarExclusive: Int {
        startBar + barCount
    }

    /// Bar-only containment: `startBar <= position.bar < endBarExclusive`.
    /// `beat`, `subdivision`, and `subdivisionPhase` on the queried
    /// position are ignored.
    func contains(_ position: GridPosition) -> Bool {
        position.bar >= startBar && position.bar < endBarExclusive
    }

    /// Absolute time at the downbeat of `startBar` (beat 0, sub 0,
    /// phase 0), projected through the supplied grid.
    func startTime(using grid: TimingGrid) -> TimeInterval {
        grid.time(of: GridPosition(bar: startBar,
                                    beat: 0,
                                    subdivision: 0,
                                    subdivisionPhase: 0))
    }

    /// Absolute time at the downbeat of `endBarExclusive` (i.e. the
    /// first instant **after** the phrase ends).
    func endTime(using grid: TimingGrid) -> TimeInterval {
        grid.time(of: GridPosition(bar: endBarExclusive,
                                    beat: 0,
                                    subdivision: 0,
                                    subdivisionPhase: 0))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case startBar, barCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startBar = try container.decode(Int.self, forKey: .startBar)
        let barCount = try container.decode(Int.self, forKey: .barCount)
        guard barCount > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .barCount,
                in: container,
                debugDescription: "barCount must be > 0, got \(barCount)"
            )
        }
        self.startBar = startBar
        self.barCount = barCount
    }
}

// MARK: - PhraseBoundary

/// A grid-projected boundary record for a phrase: the `start` and
/// `endExclusive` `GridPosition`s that bracket it on a `TimingGrid`,
/// along with the phrase's index in the originating phrase array.
///
/// Both positions sit on a bar downbeat (`beat == 0, subdivision == 0,
/// subdivisionPhase == 0`). The grammar primitives layer does not
/// appear here — `PhraseBoundary` is a sidecar for the phrase model
/// alone.
struct PhraseBoundary: Equatable, Sendable, Codable {
    let phraseIndex: Int
    let start: GridPosition
    let endExclusive: GridPosition

    init(phraseIndex: Int, start: GridPosition, endExclusive: GridPosition) {
        self.phraseIndex = phraseIndex
        self.start = start
        self.endExclusive = endExclusive
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case phraseIndex, start, endExclusive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phraseIndex = try container.decode(Int.self, forKey: .phraseIndex)
        guard phraseIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .phraseIndex,
                in: container,
                debugDescription: "phraseIndex must be ≥ 0, got \(phraseIndex)"
            )
        }
        // GridPosition's own decoder enforces its invariants
        // (beat ≥ 0, subdivision ≥ 0, subdivisionPhase ∈ [0, 1)).
        let start = try container.decode(GridPosition.self, forKey: .start)
        let endExclusive = try container.decode(GridPosition.self, forKey: .endExclusive)
        self.phraseIndex = phraseIndex
        self.start = start
        self.endExclusive = endExclusive
    }
}

// MARK: - PhraseBoundaryMapper

/// Pure, deterministic projection of a phrase list onto a
/// `TimingGrid`, producing one `PhraseBoundary` per phrase in input
/// order with `phraseIndex` matching the input position.
///
/// Same input + same grid → byte-identical output across calls.
/// The mapper does not inspect or modify primitives, capture, or
/// playback state — it operates purely on bar arithmetic.
enum PhraseBoundaryMapper {

    /// `grid` is part of the signature for symmetry with other Section
    /// 2 mappers and for future grid-aware boundary metadata; this
    /// slice's boundaries are pure bar projections so the parameter is
    /// not consulted in the body.
    static func boundaries(
        phrases: [Phrase],
        using grid: TimingGrid
    ) -> [PhraseBoundary] {
        _ = grid
        var output: [PhraseBoundary] = []
        output.reserveCapacity(phrases.count)
        for (index, phrase) in phrases.enumerated() {
            let start = GridPosition(bar: phrase.startBar,
                                      beat: 0,
                                      subdivision: 0,
                                      subdivisionPhase: 0)
            let endExclusive = GridPosition(bar: phrase.endBarExclusive,
                                             beat: 0,
                                             subdivision: 0,
                                             subdivisionPhase: 0)
            output.append(
                PhraseBoundary(phraseIndex: index,
                                start: start,
                                endExclusive: endExclusive)
            )
        }
        return output
    }
}
