import Foundation

// MARK: - GridPosition

/// A musical position on a `TimingGrid`.
///
/// The four-field representation is lossless: `subdivisionPhase` carries
/// the fractional remainder inside the addressed subdivision, so
/// `TimingGrid.time(of: TimingGrid.position(at: t))` round-trips to `t`
/// within floating-point precision.
///
/// `bar` may be negative for times that fall before the grid's `origin`.
/// `beat` is always in `0 ..< beatsPerBar`. `subdivision` is always in
/// `0 ..< subdivisionsPerBeat`. `subdivisionPhase` is always in `[0, 1)`.
///
/// **Motion-grammar-agnostic.** `GridPosition` carries no reference to
/// any `NotationPrimitive`. Layer 3's sidecar annotation, when it
/// arrives, will pair primitives with positions externally.
struct GridPosition: Equatable, Sendable, Codable {
    let bar: Int
    let beat: Int
    let subdivision: Int
    let subdivisionPhase: Double

    init(bar: Int, beat: Int, subdivision: Int, subdivisionPhase: Double) {
        self.bar = bar
        self.beat = beat
        self.subdivision = subdivision
        self.subdivisionPhase = subdivisionPhase
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case bar, beat, subdivision, subdivisionPhase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bar = try container.decode(Int.self, forKey: .bar)
        let beat = try container.decode(Int.self, forKey: .beat)
        let subdivision = try container.decode(Int.self, forKey: .subdivision)
        let subdivisionPhase = try container.decode(Double.self, forKey: .subdivisionPhase)

        guard beat >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .beat,
                in: container,
                debugDescription: "beat must be ≥ 0, got \(beat)"
            )
        }
        guard subdivision >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .subdivision,
                in: container,
                debugDescription: "subdivision must be ≥ 0, got \(subdivision)"
            )
        }
        guard subdivisionPhase.isFinite,
              subdivisionPhase >= 0.0,
              subdivisionPhase < 1.0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .subdivisionPhase,
                in: container,
                debugDescription: "subdivisionPhase must be in [0, 1), got \(subdivisionPhase)"
            )
        }

        self.bar = bar
        self.beat = beat
        self.subdivision = subdivision
        self.subdivisionPhase = subdivisionPhase
    }
}

// MARK: - TimingGrid

/// BPM-aware projection of absolute `TimeInterval`s onto a musical
/// `(bar, beat, subdivision, phase)` lattice.
///
/// The grid is a pure value type: no clock, no playback state, no
/// mutability. Querying `position(at:)` is a referentially-transparent
/// function of `(grid, time)`. Construction validates that all numeric
/// fields are finite and strictly positive where required; invalid
/// inputs return `nil` from the failable initialiser and throw from
/// the Codable decoder.
///
/// **BPM-agnostic layers stay BPM-agnostic.** Motion-grammar primitives
/// from Section 1 carry absolute seconds and never depend on this type.
/// `TimingGrid` is an optional, separate layer that callers wanting
/// musical positioning opt into. Section 1 code is unchanged by this
/// slice.
///
/// **Origin is explicit.** `origin` is the absolute time of
/// `GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)`.
/// Times before `origin` map to negative `bar` indices using
/// floor-style integer division — no nil, no special cases.
///
/// **Round-trip is lossless within float precision.** For any
/// well-formed grid and finite time `t`:
///
///     grid.time(of: grid.position(at: t))  ≈  t   (within float ε)
///
/// Tests assert this with a `1e-9` tolerance across a long sweep of `t`.
struct TimingGrid: Equatable, Sendable, Codable {
    let beatsPerMinute: Double
    let beatsPerBar: Int
    let subdivisionsPerBeat: Int
    let origin: TimeInterval

    // MARK: Failable initialiser

    init?(beatsPerMinute: Double,
          beatsPerBar: Int,
          subdivisionsPerBeat: Int,
          origin: TimeInterval) {
        guard beatsPerMinute.isFinite, beatsPerMinute > 0 else { return nil }
        guard beatsPerBar > 0 else { return nil }
        guard subdivisionsPerBeat > 0 else { return nil }
        guard origin.isFinite else { return nil }
        self.beatsPerMinute = beatsPerMinute
        self.beatsPerBar = beatsPerBar
        self.subdivisionsPerBeat = subdivisionsPerBeat
        self.origin = origin
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case beatsPerMinute, beatsPerBar, subdivisionsPerBeat, origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try container.decode(Double.self, forKey: .beatsPerMinute)
        let bpb = try container.decode(Int.self, forKey: .beatsPerBar)
        let spb = try container.decode(Int.self, forKey: .subdivisionsPerBeat)
        let origin = try container.decode(TimeInterval.self, forKey: .origin)
        guard bpm.isFinite, bpm > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .beatsPerMinute,
                in: container,
                debugDescription: "beatsPerMinute must be finite and > 0, got \(bpm)"
            )
        }
        guard bpb > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .beatsPerBar,
                in: container,
                debugDescription: "beatsPerBar must be > 0, got \(bpb)"
            )
        }
        guard spb > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .subdivisionsPerBeat,
                in: container,
                debugDescription: "subdivisionsPerBeat must be > 0, got \(spb)"
            )
        }
        guard origin.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .origin,
                in: container,
                debugDescription: "origin must be finite, got \(origin)"
            )
        }
        self.beatsPerMinute = bpm
        self.beatsPerBar = bpb
        self.subdivisionsPerBeat = spb
        self.origin = origin
    }

    // MARK: Derived helpers

    var secondsPerBeat: Double {
        60.0 / beatsPerMinute
    }

    var secondsPerBar: Double {
        secondsPerBeat * Double(beatsPerBar)
    }

    var secondsPerSubdivision: Double {
        secondsPerBeat / Double(subdivisionsPerBeat)
    }

    // MARK: Mapping

    /// Project an absolute time onto the grid lattice. Times before
    /// `origin` produce negative `bar` indices via floor-style integer
    /// division, so the mapping is total over all finite inputs.
    func position(at time: TimeInterval) -> GridPosition {
        let subSec = secondsPerSubdivision
        let relative = time - origin
        let exactSubdivisionIndex = relative / subSec
        // Floor-style integer index — `Int(floor(x))` rather than the
        // C-style truncation produced by `Int(x)` for negative `x`.
        let flooredSubdivisionIndex = Int(floor(exactSubdivisionIndex))
        let subdivisionPhase = exactSubdivisionIndex - Double(flooredSubdivisionIndex)
        // Guard against the floating-point case where rounding gives
        // `subdivisionPhase == 1.0` exactly; collapse to the next
        // integer index with phase 0.
        let (subdivisionIndex, phase): (Int, Double)
        if subdivisionPhase >= 1.0 {
            subdivisionIndex = flooredSubdivisionIndex + 1
            phase = 0.0
        } else if subdivisionPhase < 0.0 {
            // Defensive: floor(x) ≤ x by definition, so this branch
            // should never fire. Kept as a guardrail against future
            // changes that compute `phase` differently.
            subdivisionIndex = flooredSubdivisionIndex - 1
            phase = subdivisionPhase + 1.0
        } else {
            subdivisionIndex = flooredSubdivisionIndex
            phase = subdivisionPhase
        }

        let subsPerBar = beatsPerBar * subdivisionsPerBeat
        let bar = TimingGrid.flooredDiv(subdivisionIndex, subsPerBar)
        let withinBar = TimingGrid.flooredMod(subdivisionIndex, subsPerBar)
        let beat = withinBar / subdivisionsPerBeat
        let subdivision = withinBar % subdivisionsPerBeat

        return GridPosition(bar: bar,
                            beat: beat,
                            subdivision: subdivision,
                            subdivisionPhase: phase)
    }

    /// Inverse of `position(at:)`. For any well-formed grid `g` and
    /// finite time `t`, `g.time(of: g.position(at: t))` returns `t`
    /// within floating-point precision.
    func time(of position: GridPosition) -> TimeInterval {
        let subsPerBar = beatsPerBar * subdivisionsPerBeat
        let subdivisionIndex = position.bar * subsPerBar
            + position.beat * subdivisionsPerBeat
            + position.subdivision
        let exactSubdivisions = Double(subdivisionIndex) + position.subdivisionPhase
        return origin + exactSubdivisions * secondsPerSubdivision
    }

    // MARK: Floor-style integer arithmetic

    /// Floor-style integer division: `flooredDiv(-1, 4) == -1`, not `0`.
    /// Swift's `/` truncates toward zero, which would give wrong bar
    /// indices for times before the grid origin.
    private static func flooredDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// Floor-style integer modulo: result always has the same sign as
    /// the divisor (here always positive), regardless of dividend sign.
    private static func flooredMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}
