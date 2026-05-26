import Foundation

// MARK: - TimingOriginSource

/// Provenance of a `TimingOriginMarker`. Strictly descriptive; the
/// notation layer does not branch on the source, but downstream
/// consumers may want to know whether the origin came from a user
/// gesture, an imported file, or a future detection step.
///
/// `detectedPlaceholder` is reserved for the eventual audio-onset
/// detection pathway. Slice 7 does not implement detection — the case
/// exists so the schema is forward-compatible when that slice lands.
enum TimingOriginSource: String, Equatable, Sendable, Codable {
    case manual
    case imported
    case detectedPlaceholder
}

// MARK: - TimingOriginMarker

/// An explicit, hand-supplied (or imported) origin point for a
/// `TimingGrid`. Carries the absolute `time` at which bar 0 / beat 0 /
/// subdivision 0 / phase 0 should sit, the marker's `source`, and an
/// optional free-form `label`.
///
/// Validation:
///
/// - `time` must be finite and `>= 0`.
/// - `label` may be `nil` or any `String`, including the empty string.
///   No trimming or normalisation is applied.
///
/// The marker carries no clock, no playback state, no audio data. It
/// is purely a value-typed handle to the origin point a caller has
/// already decided upon. Detection (audio onset, MIDI clock, etc.) is
/// a future slice and is not represented here beyond the
/// `.detectedPlaceholder` source case.
struct TimingOriginMarker: Equatable, Sendable, Codable {
    let time: TimeInterval
    let source: TimingOriginSource
    let label: String?

    init?(time: TimeInterval, source: TimingOriginSource, label: String?) {
        guard time.isFinite, time >= 0 else { return nil }
        self.time = time
        self.source = source
        self.label = label
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case time, source, label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let time = try container.decode(TimeInterval.self, forKey: .time)
        guard time.isFinite, time >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .time,
                in: container,
                debugDescription: "time must be finite and ≥ 0, got \(time)"
            )
        }
        let source = try container.decode(TimingOriginSource.self, forKey: .source)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        self.time = time
        self.source = source
        self.label = label
    }
}

// MARK: - TimingGridFactory

/// Pure constructor that wires a `TimingOriginMarker.time` into a
/// fresh `TimingGrid`'s `origin`. The rest of the grid parameters
/// pass through untouched; `TimingGrid`'s own failable initialiser
/// continues to validate them.
///
/// `grid(...)` returns `nil` exactly when `TimingGrid.init?` would
/// return `nil` — i.e. when the supplied `beatsPerMinute`,
/// `beatsPerBar`, or `subdivisionsPerBeat` violates its invariants.
/// The factory adds no new validation beyond what the marker already
/// enforced (finite, `>= 0` time).
enum TimingGridFactory {

    static func grid(
        beatsPerMinute: Double,
        beatsPerBar: Int,
        subdivisionsPerBeat: Int,
        originMarker: TimingOriginMarker
    ) -> TimingGrid? {
        TimingGrid(beatsPerMinute: beatsPerMinute,
                   beatsPerBar: beatsPerBar,
                   subdivisionsPerBeat: subdivisionsPerBeat,
                   origin: originMarker.time)
    }
}
