// CrossfaderStateDeriver — turns a calibrated crossfader position stream into
// open / closed / transitioning states, then into named semantic events.
//
// Two things this fixes. Both were DIAGNOSED from a 2026-09-04 exported
// baby-scratch take (826 crossfader samples, raw range 0…52, 20 derived events
// of which 12 were `unknown`). That take is a defect report, not reference
// material: it is not a valid example of the technique, nothing here is tuned
// to make it pass, and no threshold below is derived from what it contains.
//
// 1. Normalization. That take's events were normalized as `raw / 127`, so a
//    complete centre-to-left cut read as a 0.41 excursion and sat under the
//    0.25 cut gate's duration companion. Here every position comes from
//    `CrossfaderCalibration.normalized(rawValue:)`, which spans the CALIBRATED
//    ACTIVE HALF, so the same gesture reads 0…1.
//
// 2. Vocabulary. `unknown` was the catch-all for any transition that was not
//    fast enough to be a cut — including a perfectly ordinary slow return to
//    open. Slow, deliberate movements are now `.opening` / `.closing`, and
//    `.unknown` is reserved for a transition that genuinely never resolves to
//    a stable state. The unknown RATIO is then a real quality signal, which is
//    what publishing gates on.
//
// Hysteresis: a single threshold turns MIDI jitter at the boundary into a
// burst of false cuts. Two thresholds with a dead band between them, plus a
// minimum dwell before a state is committed, remove that without smoothing
// away real gestures.
//
// Pure value transformation. Foundation only. Deterministic.

import Foundation

// MARK: - Gate state

/// The audible state of one deck through the crossfader.
enum CrossfaderGateState: String, Codable, Equatable, Sendable {
    /// Deck silent — position at or below the closed threshold.
    case closed
    /// Deck audible — position at or above the open threshold.
    case open
    /// Inside the dead band, or moving and not yet settled.
    case transitioning

    var displayName: String {
        switch self {
        case .closed: return "Closed"
        case .open: return "Open"
        case .transitioning: return "Moving"
        }
    }
}

/// Hysteresis and dwell parameters for state derivation.
///
/// Every value is a caller-supplied parameter with a documented default, not a
/// technique-specific constant baked into the deriver — the same convention
/// `ScratchPerformanceComparison` uses for its matching windows.
struct CrossfaderHysteresis: Equatable, Sendable {
    /// Normalized position at or below which the deck is CLOSED.
    let closedAtOrBelow: Double
    /// Normalized position at or above which the deck is OPEN.
    let openAtOrAbove: Double
    /// Minimum time a candidate state must hold before it is committed.
    /// Shorter excursions are absorbed into the surrounding state.
    let minimumDwellSeconds: Double

    /// PROVISIONAL defaults. Not measured from any recorded performance.
    ///
    /// No take recorded so far is valid reference material, so none of these
    /// numbers may be tuned against one. They are engineering starting points
    /// chosen so the bands do not overlap and a single MIDI step cannot flip a
    /// state, and they are exposed as parameters on every entry point here so
    /// an operator can override them. When CXL records real references on real
    /// hardware, these are re-derived from THAT evidence and this comment is
    /// replaced with the measurement.
    static let `default` = CrossfaderHysteresis(
        closedAtOrBelow: 0.12,
        openAtOrAbove: 0.62,
        minimumDwellSeconds: 0.008
    )

    init(closedAtOrBelow: Double, openAtOrAbove: Double, minimumDwellSeconds: Double) {
        self.closedAtOrBelow = closedAtOrBelow
        self.openAtOrAbove = openAtOrAbove
        self.minimumDwellSeconds = minimumDwellSeconds
    }

    /// `false` when the bands overlap or invert, which would make every sample
    /// simultaneously open and closed.
    var isUsable: Bool {
        closedAtOrBelow.isFinite
            && openAtOrAbove.isFinite
            && minimumDwellSeconds.isFinite
            && minimumDwellSeconds >= 0
            && closedAtOrBelow >= 0
            && openAtOrAbove <= 1
            && openAtOrAbove > closedAtOrBelow
    }

    /// Classify one position with no memory. `transitioning` is the dead band.
    func instantaneousState(forNormalizedPosition position: Double) -> CrossfaderGateState {
        if position <= closedAtOrBelow { return .closed }
        if position >= openAtOrAbove { return .open }
        return .transitioning
    }
}

// MARK: - Samples and edges

/// One calibrated crossfader position at one take-relative instant.
struct CrossfaderPositionSample: Equatable, Sendable {
    let takeRelativeTime: Double
    let rawValue: Int
    /// Position across the calibrated active half, 0…1.
    let normalizedPosition: Double

    init(takeRelativeTime: Double, rawValue: Int, normalizedPosition: Double) {
        self.takeRelativeTime = takeRelativeTime
        self.rawValue = rawValue
        self.normalizedPosition = normalizedPosition
    }
}

/// A committed state, with the span over which it held.
struct CrossfaderStateInterval: Equatable, Sendable {
    let state: CrossfaderGateState
    let startTime: Double
    let endTime: Double
    let startPosition: Double
    let endPosition: Double

    var duration: Double { max(0, endTime - startTime) }
}

// MARK: - Semantic events

/// What a transition between committed states means musically.
///
/// Deliberately NOT technique names. This layer describes fader mechanics; a
/// technique is a pattern over these plus platter motion, and lives in the
/// reference target, not here. Nothing in this enum is inferred from a
/// technique's display name.
enum CrossfaderSemanticEventKind: String, Codable, Equatable, Sendable {
    /// Open -> closed fast enough to be a deliberate cut.
    case cut
    /// Closed -> open fast enough to be a deliberate release.
    case release
    /// A closed-open-closed or open-closed-open pair inside the pulse window.
    case pulse
    /// Three or more alternating pulses inside the pulse window.
    case transformPulse
    /// A deliberate but unhurried move toward open.
    case opening
    /// A deliberate but unhurried move toward closed.
    case closing
    /// A transition that never committed to a stable state on either side.
    /// The ONLY case that counts toward the unknown ratio.
    case unknown

    var isUnknown: Bool { self == .unknown }
}

struct CrossfaderSemanticEvent: Equatable, Sendable {
    let kind: CrossfaderSemanticEventKind
    let startTime: Double
    let endTime: Double
    let fromPosition: Double
    let toPosition: Double

    var duration: Double { max(0, endTime - startTime) }
}

/// The derivation result, including the quality figure publishing gates on.
struct CrossfaderDerivation: Equatable, Sendable {
    let intervals: [CrossfaderStateInterval]
    let events: [CrossfaderSemanticEvent]

    var unknownEventCount: Int { events.filter(\.kind.isUnknown).count }

    /// Fraction of derived events this build could not name, 0…1.
    /// `0` when there are no events at all — an empty stream is a MISSING
    /// evidence failure, reported separately, never a quality failure.
    var unknownEventRatio: Double {
        guard !events.isEmpty else { return 0 }
        return Double(unknownEventCount) / Double(events.count)
    }

    /// `true` when the deck never left its open state — the Baby Scratch
    /// requirement.
    var stayedOpenThroughout: Bool {
        !intervals.isEmpty && intervals.allSatisfy { $0.state == .open }
    }

    var cutLikeEventCount: Int {
        events.filter { $0.kind == .cut || $0.kind == .pulse || $0.kind == .transformPulse }.count
    }
}

// MARK: - Deriver

enum CrossfaderStateDeriver {

    /// Transitions no longer than this are named as deliberate cuts/releases;
    /// longer ones are `opening`/`closing`.
    ///
    /// PROVISIONAL. Not derived from any recorded take — see the note on
    /// `CrossfaderHysteresis.default`. It is a caller-supplied parameter
    /// precisely so it can be replaced without touching this file.
    static let defaultMaximumCutDuration: Double = 0.28
    /// Maximum gap between alternating cuts for them to read as one pulse
    /// figure. PROVISIONAL, on the same terms.
    static let defaultMaximumPulseGap: Double = 0.20

    /// Project raw MIDI samples through a calibration.
    ///
    /// Returns `nil` when the calibration is unusable, so a caller can never
    /// fall back to a `raw / 127` assumption. Samples outside the MIDI range
    /// are dropped; samples outside the ACTIVE HALF are kept and clamp to the
    /// nearest end, because parking past the detent is a real, meaningful
    /// position for this deck.
    static func positionSamples(
        rawEvents: [(takeRelativeTime: Double, rawValue: Int)],
        calibration: CrossfaderCalibration
    ) -> [CrossfaderPositionSample]? {
        guard calibration.isUsable else { return nil }
        return rawEvents
            .compactMap { event -> CrossfaderPositionSample? in
                guard event.takeRelativeTime.isFinite,
                      let position = calibration.normalized(rawValue: event.rawValue) else {
                    return nil
                }
                return CrossfaderPositionSample(
                    takeRelativeTime: event.takeRelativeTime,
                    rawValue: event.rawValue,
                    normalizedPosition: position
                )
            }
            .sorted { $0.takeRelativeTime < $1.takeRelativeTime }
    }

    /// Commit a state stream with hysteresis and a minimum dwell.
    ///
    /// Returns `nil` for unusable hysteresis rather than deriving with
    /// overlapping bands.
    static func stateIntervals(
        samples: [CrossfaderPositionSample],
        hysteresis: CrossfaderHysteresis = .default
    ) -> [CrossfaderStateInterval]? {
        guard hysteresis.isUsable else { return nil }
        guard !samples.isEmpty else { return [] }

        // Pass 1: raw instantaneous classification, run-length encoded.
        var runs: [CrossfaderStateInterval] = []
        var runState = hysteresis.instantaneousState(forNormalizedPosition: samples[0].normalizedPosition)
        var runStartIndex = 0
        for index in 1..<samples.count {
            let state = hysteresis.instantaneousState(
                forNormalizedPosition: samples[index].normalizedPosition
            )
            guard state != runState else { continue }
            runs.append(
                CrossfaderStateInterval(
                    state: runState,
                    startTime: samples[runStartIndex].takeRelativeTime,
                    endTime: samples[index].takeRelativeTime,
                    startPosition: samples[runStartIndex].normalizedPosition,
                    endPosition: samples[index - 1].normalizedPosition
                )
            )
            runState = state
            runStartIndex = index
        }
        runs.append(
            CrossfaderStateInterval(
                state: runState,
                startTime: samples[runStartIndex].takeRelativeTime,
                endTime: samples[samples.count - 1].takeRelativeTime,
                startPosition: samples[runStartIndex].normalizedPosition,
                endPosition: samples[samples.count - 1].normalizedPosition
            )
        )

        // Pass 2: absorb runs shorter than the dwell into their neighbour.
        // This is what removes MIDI jitter at a threshold: a one-sample dip
        // across `closedAtOrBelow` cannot mint a cut. A short run is only
        // absorbed when it is flanked by the SAME state, so a genuine fast
        // cut (open -> closed -> open with real dwell at closed) survives.
        var committed: [CrossfaderStateInterval] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            let isShort = run.duration < hysteresis.minimumDwellSeconds
            let previous = committed.last
            let following = index + 1 < runs.count ? runs[index + 1] : nil
            if isShort, let previous, let following, previous.state == following.state {
                // Merge previous + short + following into one previous-state run.
                committed.removeLast()
                committed.append(
                    CrossfaderStateInterval(
                        state: previous.state,
                        startTime: previous.startTime,
                        endTime: following.endTime,
                        startPosition: previous.startPosition,
                        endPosition: following.endPosition
                    )
                )
                index += 2
                continue
            }
            if let previous, previous.state == run.state {
                committed.removeLast()
                committed.append(
                    CrossfaderStateInterval(
                        state: previous.state,
                        startTime: previous.startTime,
                        endTime: run.endTime,
                        startPosition: previous.startPosition,
                        endPosition: run.endPosition
                    )
                )
                index += 1
                continue
            }
            committed.append(run)
            index += 1
        }
        return committed
    }

    /// Name each transition between committed states.
    static func semanticEvents(
        intervals: [CrossfaderStateInterval],
        maximumCutDuration: Double = defaultMaximumCutDuration,
        maximumPulseGap: Double = defaultMaximumPulseGap
    ) -> [CrossfaderSemanticEvent] {
        guard intervals.count >= 2 else { return [] }

        // A transition is the `transitioning` interval between two settled
        // states, or a direct settled -> settled boundary when the stream was
        // sparse enough that no sample landed in the dead band.
        var transitions: [CrossfaderSemanticEvent] = []
        var index = 0
        while index < intervals.count - 1 {
            let current = intervals[index]
            guard current.state != .transitioning else { index += 1; continue }

            var lookahead = index + 1
            var crossedTransition = false
            while lookahead < intervals.count, intervals[lookahead].state == .transitioning {
                crossedTransition = true
                lookahead += 1
            }
            guard lookahead < intervals.count else {
                // The stream ends inside a transition: it never resolved.
                if crossedTransition {
                    let tail = intervals[intervals.count - 1]
                    transitions.append(
                        CrossfaderSemanticEvent(
                            kind: .unknown,
                            startTime: current.endTime,
                            endTime: tail.endTime,
                            fromPosition: current.endPosition,
                            toPosition: tail.endPosition
                        )
                    )
                }
                break
            }
            let destination = intervals[lookahead]
            let startTime = current.endTime
            let endTime = destination.startTime
            let duration = max(0, endTime - startTime)
            let kind: CrossfaderSemanticEventKind
            switch (current.state, destination.state) {
            case (.open, .closed):
                kind = duration <= maximumCutDuration ? .cut : .closing
            case (.closed, .open):
                kind = duration <= maximumCutDuration ? .release : .opening
            default:
                // Same settled state on both sides of a transition: the fader
                // moved into the dead band and came back without resolving.
                kind = .unknown
            }
            transitions.append(
                CrossfaderSemanticEvent(
                    kind: kind,
                    startTime: startTime,
                    endTime: endTime,
                    fromPosition: current.endPosition,
                    toPosition: destination.startPosition
                )
            )
            index = lookahead
        }

        return collapsePulses(
            transitions,
            maximumPulseGap: maximumPulseGap
        )
    }

    /// Collapse alternating cut/release runs into pulse figures.
    private static func collapsePulses(
        _ transitions: [CrossfaderSemanticEvent],
        maximumPulseGap: Double
    ) -> [CrossfaderSemanticEvent] {
        var output: [CrossfaderSemanticEvent] = []
        var index = 0
        while index < transitions.count {
            let start = transitions[index]
            guard start.kind == .cut || start.kind == .release else {
                output.append(start)
                index += 1
                continue
            }
            var end = index
            while end + 1 < transitions.count {
                let candidate = transitions[end + 1]
                let previous = transitions[end]
                let alternates = (previous.kind == .cut && candidate.kind == .release)
                    || (previous.kind == .release && candidate.kind == .cut)
                guard alternates,
                      candidate.startTime - previous.endTime <= maximumPulseGap else { break }
                end += 1
            }
            let runLength = end - index + 1
            if runLength >= 3 {
                output.append(
                    CrossfaderSemanticEvent(
                        kind: .transformPulse,
                        startTime: start.startTime,
                        endTime: transitions[end].endTime,
                        fromPosition: start.fromPosition,
                        toPosition: transitions[end].toPosition
                    )
                )
            } else if runLength == 2 {
                output.append(
                    CrossfaderSemanticEvent(
                        kind: .pulse,
                        startTime: start.startTime,
                        endTime: transitions[end].endTime,
                        fromPosition: start.fromPosition,
                        toPosition: transitions[end].toPosition
                    )
                )
            } else {
                output.append(start)
            }
            index = end + 1
        }
        return output
    }

    /// One-call derivation from raw MIDI to named events.
    ///
    /// Returns `nil` when the calibration or hysteresis is unusable — the
    /// caller must then report missing calibration, never derive anyway.
    static func derive(
        rawEvents: [(takeRelativeTime: Double, rawValue: Int)],
        calibration: CrossfaderCalibration,
        hysteresis: CrossfaderHysteresis = .default,
        maximumCutDuration: Double = defaultMaximumCutDuration,
        maximumPulseGap: Double = defaultMaximumPulseGap
    ) -> CrossfaderDerivation? {
        guard let samples = positionSamples(rawEvents: rawEvents, calibration: calibration),
              let intervals = stateIntervals(samples: samples, hysteresis: hysteresis) else {
            return nil
        }
        return CrossfaderDerivation(
            intervals: intervals,
            events: semanticEvents(
                intervals: intervals,
                maximumCutDuration: maximumCutDuration,
                maximumPulseGap: maximumPulseGap
            )
        )
    }
}
