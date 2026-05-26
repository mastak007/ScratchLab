import Foundation

// MARK: - Direction

/// Sign of platter motion in `PlatterPositionTimeline` space.
///
/// Strictly motion-only: this does not name a scratch family
/// (baby / chirp / flare / transform / etc). Family identity attaches
/// later via a separate symbolic-label sidecar.
enum Direction: String, Equatable, Sendable, Codable {
    case forward
    case reverse
}

// MARK: - ReversalKind

/// Shape of a direction reversal.
///
/// - `cusp`:  sharp sign flip with high speed magnitudes on both sides.
/// - `round`: slow turn-through-zero, either because at least one side's
///   peak speed is below the cusp threshold, or because the two
///   direction segments are bracketed by an `IdleHold`.
enum ReversalKind: String, Equatable, Sendable, Codable {
    case cusp
    case round
}

// MARK: - DirectionSegment

/// A maximal contiguous span over which platter velocity stays above
/// the idle epsilon and keeps a single sign.
///
/// `minimumConfidence` is the **minimum** confidence of any contributing
/// `PlatterPositionSample`. Never averaged upward, never boosted.
struct DirectionSegment: Equatable, Sendable, Codable {
    let direction: Direction
    let startTime: TimeInterval
    let endTime: TimeInterval
    let startPosition: Double
    let endPosition: Double
    let minimumConfidence: Double
}

// MARK: - Reversal

/// A point event marking a direction sign flip between two
/// `DirectionSegment`s.
///
/// For direct flips (no intervening `IdleHold`), `time` / `position` are
/// taken from the boundary sample. For round-through-idle reversals,
/// they are the midpoint of the bracketing `IdleHold`. `minimumConfidence`
/// is min across the closing segment's last sample, every sample in the
/// bracketing idle hold (if any), and the opening segment's first sample.
struct Reversal: Equatable, Sendable, Codable {
    let kind: ReversalKind
    let time: TimeInterval
    let position: Double
    let minimumConfidence: Double
}

// MARK: - IdleHold

/// A maximal contiguous span over which platter velocity stays at or
/// below the idle epsilon, lasting at least `minimumIdleDwell`.
///
/// `positionLow` / `positionHigh` describe the band the platter wandered
/// over during the hold. `minimumConfidence` is the minimum of all
/// contributing samples — sub-epsilon jitter is preserved in the band
/// width, not laundered into the surrounding direction segments.
struct IdleHold: Equatable, Sendable, Codable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let positionLow: Double
    let positionHigh: Double
    let minimumConfidence: Double
}

// MARK: - NotationPrimitive

/// Sum type over the three motion atoms.
///
/// Primitives describe **motion only**. They carry no scratch-family
/// label, no BPM/subdivision metadata, no phrase membership, no
/// coaching verdict. Those layers attach later via separate sidecar
/// types and never mutate primitives.
enum NotationPrimitive: Equatable, Sendable, Codable {
    case directionSegment(DirectionSegment)
    case reversal(Reversal)
    case idleHold(IdleHold)

    private enum Kind: String, Codable {
        case directionSegment
        case reversal
        case idleHold
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case directionSegment
        case reversal
        case idleHold
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directionSegment(let segment):
            try container.encode(Kind.directionSegment, forKey: .kind)
            try container.encode(segment, forKey: .directionSegment)
        case .reversal(let reversal):
            try container.encode(Kind.reversal, forKey: .kind)
            try container.encode(reversal, forKey: .reversal)
        case .idleHold(let hold):
            try container.encode(Kind.idleHold, forKey: .kind)
            try container.encode(hold, forKey: .idleHold)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .directionSegment:
            self = .directionSegment(
                try container.decode(DirectionSegment.self, forKey: .directionSegment)
            )
        case .reversal:
            self = .reversal(
                try container.decode(Reversal.self, forKey: .reversal)
            )
        case .idleHold:
            self = .idleHold(
                try container.decode(IdleHold.self, forKey: .idleHold)
            )
        }
    }
}
