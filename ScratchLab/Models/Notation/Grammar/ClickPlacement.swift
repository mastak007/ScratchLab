import Foundation

// MARK: - ClickRole

/// Vocabulary tag for where a fader click sits inside its parent stroke.
///
/// The role is an educational label; `ClickPlacement.fraction` is the
/// validated source of truth for the actual position.
enum ClickRole: String, Equatable, Sendable, Codable {
    case low
    case middle
    case high
    case third
    case custom
}

// MARK: - ClickFeel

/// Rhythmic feel of a click or click group. This is a pure label and does
/// not project to time without an explicit stroke span.
enum ClickFeel: String, Equatable, Sendable, Codable {
    case even
    case burst
    case triplet
    case custom
}

// MARK: - ClickPlacement

/// A single fader click expressed as a fraction of stroke travel.
///
/// `fraction` is validated inline by this type. It must be finite and inside
/// the closed range `0...1`; invalid values are rejected instead of clamped.
struct ClickPlacement: Equatable, Sendable, Codable {
    let fraction: Double
    let role: ClickRole
    let feel: ClickFeel

    init?(fraction: Double, role: ClickRole, feel: ClickFeel) {
        guard Self.isValidFraction(fraction) else { return nil }
        self.fraction = fraction
        self.role = role
        self.feel = feel
    }

    func time(inSpan start: TimeInterval, end: TimeInterval) -> TimeInterval {
        start + fraction * (end - start)
    }

    private static func isValidFraction(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }

    private enum CodingKeys: String, CodingKey {
        case fraction
        case role
        case feel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fraction = try container.decode(Double.self, forKey: .fraction)
        guard Self.isValidFraction(fraction) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fraction,
                in: container,
                debugDescription: "fraction must be finite and inside 0...1"
            )
        }
        self.fraction = fraction
        self.role = try container.decode(ClickRole.self, forKey: .role)
        self.feel = try container.decode(ClickFeel.self, forKey: .feel)
    }
}

// MARK: - StrokeHalf

/// The stroke half a click group belongs to.
enum StrokeHalf: String, Equatable, Sendable, Codable {
    case forward
    case backward
}

// MARK: - ClickGroup

/// Ordered click placements for exactly one stroke half.
///
/// Ordering is preserved exactly as authored. No sorting or deduplication is
/// applied because TTM-style click patterns can use intentional asymmetric or
/// non-monotonic teaching order.
struct ClickGroup: Equatable, Sendable, Codable {
    let half: StrokeHalf
    let placements: [ClickPlacement]

    init(half: StrokeHalf, placements: [ClickPlacement] = []) {
        self.half = half
        self.placements = placements
    }

    var clickCount: Int { placements.count }
}

// MARK: - StrokeHalfPattern

/// Click groups for one forward/back stroke pair.
struct StrokeHalfPattern: Equatable, Sendable, Codable {
    let forward: ClickGroup?
    let backward: ClickGroup?

    private init(forward: ClickGroup?, backward: ClickGroup?) {
        self.forward = forward
        self.backward = backward
    }

    static func forwardOnly(_ placements: [ClickPlacement]) -> StrokeHalfPattern {
        StrokeHalfPattern(
            forward: ClickGroup(half: .forward, placements: placements),
            backward: nil
        )
    }

    static func orbit(
        forward forwardPlacements: [ClickPlacement],
        backward backwardPlacements: [ClickPlacement]
    ) -> StrokeHalfPattern {
        StrokeHalfPattern(
            forward: ClickGroup(half: .forward, placements: forwardPlacements),
            backward: ClickGroup(half: .backward, placements: backwardPlacements)
        )
    }

    var forwardClickCount: Int { forward?.clickCount ?? 0 }
    var backwardClickCount: Int { backward?.clickCount ?? 0 }
    var totalClickCount: Int { forwardClickCount + backwardClickCount }

    var isForwardOnly: Bool {
        forward != nil && backward == nil
    }

    var isSymmetricOrbit: Bool {
        forward != nil && backward != nil && forwardClickCount == backwardClickCount
    }
}
