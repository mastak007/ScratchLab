// CallAndResponseSchedule — shared training playback scheduling for
// call-and-response practice.
//
// The learner hears the reference phrase, then gets an equal-length window to
// copy it. That silence is generated HERE, at playback time, and is never
// baked into the reference recording: a recording with a gap in it can only
// ever teach at one response length, and re-recording is the only way to
// change it.
//
// A schedule is a pure list of phases with absolute start times. It reads a
// clock from nobody — the caller supplies elapsed time and asks what phase is
// active. That is what makes it identical on iOS and macOS, testable without
// audio, and safe to drive from either a display link or an audio render
// callback.
//
// Foundation only. Pure value types.

import Foundation

// MARK: - Modes

/// How a training session uses the reference.
enum CallAndResponseMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// Play the reference once. No response window.
    case listenOnly
    /// Loop the reference continuously. No response window.
    case loopingReference
    /// One reference play, then one response window.
    case listenThenCopy
    /// `roundCount` repeats of reference-then-response.
    case repeatedRounds

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .listenOnly: return "Listen only"
        case .loopingReference: return "Loop reference"
        case .listenThenCopy: return "Listen, then copy"
        case .repeatedRounds: return "Repeated rounds"
        }
    }

    var opensResponseWindow: Bool {
        self == .listenThenCopy || self == .repeatedRounds
    }
}

/// What is happening at a given instant.
enum CallAndResponsePhaseKind: String, Codable, Equatable, Sendable {
    /// Count-in before the first reference play.
    case countIn
    /// The reference phrase is playing.
    case reference
    /// "YOUR TURN" — the learner plays, and is captured.
    case response
    /// Session finished.
    case complete

    var displayLabel: String {
        switch self {
        case .countIn: return "COUNT IN"
        case .reference: return "LISTEN"
        case .response: return "YOUR TURN"
        case .complete: return "DONE"
        }
    }

    /// Whether the learner's performance is captured during this phase.
    var capturesLearner: Bool { self == .response }
}

// MARK: - Phase

struct CallAndResponsePhase: Equatable, Sendable, Identifiable {
    let index: Int
    let kind: CallAndResponsePhaseKind
    /// Round this phase belongs to, 0-based. `nil` for the leading count-in.
    let round: Int?
    let startTime: Double
    let duration: Double

    var id: Int { index }
    var endTime: Double { startTime + duration }

    func contains(_ time: Double) -> Bool {
        time >= startTime && time < endTime
    }
}

// MARK: - Configuration

/// Everything needed to lay out a session.
struct CallAndResponseConfiguration: Equatable, Sendable {
    let mode: CallAndResponseMode
    /// Length of one reference phrase, in seconds.
    let phraseDurationSeconds: Double
    /// Length of the learner's window. Defaults to the phrase length; a
    /// caller may lengthen it for a beginner without re-recording anything.
    let responseDurationSeconds: Double
    /// Rounds for `.repeatedRounds`; loops for `.loopingReference`. Ignored
    /// by the other modes.
    let roundCount: Int
    /// Beats of count-in before the first reference play. `0` for none.
    let countInBeats: Int
    let bpm: Int
    /// Whether the click/beat keeps running through the response window.
    let clickRunsThroughResponse: Bool

    init(
        mode: CallAndResponseMode,
        phraseDurationSeconds: Double,
        responseDurationSeconds: Double? = nil,
        roundCount: Int = 4,
        countInBeats: Int = 4,
        bpm: Int,
        clickRunsThroughResponse: Bool = true
    ) {
        self.mode = mode
        self.phraseDurationSeconds = phraseDurationSeconds
        self.responseDurationSeconds = responseDurationSeconds ?? phraseDurationSeconds
        self.roundCount = max(1, roundCount)
        self.countInBeats = max(0, countInBeats)
        self.bpm = bpm
        self.clickRunsThroughResponse = clickRunsThroughResponse
    }

    var secondsPerBeat: Double { bpm > 0 ? 60.0 / Double(bpm) : 0 }
    var countInDurationSeconds: Double { Double(countInBeats) * secondsPerBeat }

    /// `false` when the configuration cannot produce a usable schedule.
    var isUsable: Bool {
        bpm > 0
            && phraseDurationSeconds.isFinite
            && phraseDurationSeconds > 0
            && responseDurationSeconds.isFinite
            && responseDurationSeconds >= 0
    }
}

// MARK: - Schedule

/// A laid-out session: an ordered, contiguous phase list.
struct CallAndResponseSchedule: Equatable, Sendable {
    let configuration: CallAndResponseConfiguration
    let phases: [CallAndResponsePhase]

    /// Build the schedule, or `nil` for an unusable configuration. Never
    /// produces a partial or zero-length session.
    init?(configuration: CallAndResponseConfiguration) {
        guard configuration.isUsable else { return nil }
        self.configuration = configuration
        self.phases = Self.makePhases(configuration)
    }

    var totalDuration: Double { phases.last?.endTime ?? 0 }

    var roundCount: Int {
        (phases.compactMap(\.round).max() ?? -1) + 1
    }

    /// The phase active at `time`, or `nil` past the end.
    func phase(at time: Double) -> CallAndResponsePhase? {
        guard time >= 0 else { return phases.first }
        return phases.first { $0.contains(time) }
    }

    /// Progress through the phase active at `time`, 0…1.
    func phaseProgress(at time: Double) -> Double {
        guard let phase = phase(at: time), phase.duration > 0 else { return 0 }
        return min(1, max(0, (time - phase.startTime) / phase.duration))
    }

    /// Whether the learner is being captured at `time`.
    func capturesLearner(at time: Double) -> Bool {
        phase(at: time)?.kind.capturesLearner ?? false
    }

    /// Whether the click should sound at `time`.
    ///
    /// The click always runs through the count-in and the reference. Through
    /// the response it runs only when configured to, which is the honest
    /// distinction between "keep the grid audible" and "let the learner hear
    /// themselves dry".
    func clickIsAudible(at time: Double) -> Bool {
        guard let phase = phase(at: time) else { return false }
        switch phase.kind {
        case .countIn, .reference:
            return true
        case .response:
            return configuration.clickRunsThroughResponse
        case .complete:
            return false
        }
    }

    /// Take-relative windows during which the learner is captured. One per
    /// round; empty for the listen-only and looping modes.
    var responseWindows: [(round: Int, startTime: Double, endTime: Double)] {
        phases
            .filter { $0.kind == .response }
            .map { ($0.round ?? 0, $0.startTime, $0.endTime) }
    }

    private static func makePhases(
        _ configuration: CallAndResponseConfiguration
    ) -> [CallAndResponsePhase] {
        var phases: [CallAndResponsePhase] = []
        var cursor: Double = 0
        var index = 0

        func append(_ kind: CallAndResponsePhaseKind, round: Int?, duration: Double) {
            guard duration > 0 else { return }
            phases.append(
                CallAndResponsePhase(
                    index: index,
                    kind: kind,
                    round: round,
                    startTime: cursor,
                    duration: duration
                )
            )
            index += 1
            cursor += duration
        }

        append(.countIn, round: nil, duration: configuration.countInDurationSeconds)

        switch configuration.mode {
        case .listenOnly:
            append(.reference, round: 0, duration: configuration.phraseDurationSeconds)
        case .loopingReference:
            for round in 0..<configuration.roundCount {
                append(.reference, round: round, duration: configuration.phraseDurationSeconds)
            }
        case .listenThenCopy:
            append(.reference, round: 0, duration: configuration.phraseDurationSeconds)
            append(.response, round: 0, duration: configuration.responseDurationSeconds)
        case .repeatedRounds:
            for round in 0..<configuration.roundCount {
                append(.reference, round: round, duration: configuration.phraseDurationSeconds)
                append(.response, round: round, duration: configuration.responseDurationSeconds)
            }
        }

        phases.append(
            CallAndResponsePhase(
                index: index,
                kind: .complete,
                round: nil,
                startTime: cursor,
                duration: 0
            )
        )
        return phases
    }
}

// MARK: - Comparison gate

/// Whether a learner's response may be SCORED against a target.
///
/// Playback and capture are always allowed; comparison is not. Scoring a
/// learner against a target ScratchLab has not verified would teach a guess as
/// if it were the technique, so the gate is the same one
/// `ScratchNotation.canonicalBeatPatterns` already draws.
enum CallAndResponseComparisonGate {

    enum Decision: Equatable, Sendable {
        case comparable(ScratchNotation.BeatPattern)
        case notComparable(reason: String)

        var isComparable: Bool {
            if case .comparable = self { return true }
            return false
        }
    }

    /// The target pattern for `technique`, or why there isn't one.
    static func decision(for technique: ReferenceTechnique) -> Decision {
        guard let pattern = ScratchNotation.canonicalBeatPattern(
            forScratchID: technique.scratchType.rawValue
        ) else {
            return .notComparable(
                reason: "\(technique.displayName) has no verified target notation yet, so ScratchLab can play the reference and record you, but will not score the comparison."
            )
        }
        return .comparable(pattern)
    }
}
