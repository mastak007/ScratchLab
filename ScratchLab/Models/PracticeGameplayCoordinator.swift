// PracticeGameplayCoordinator — the macOS WATCH → COPY → RESULT state
// machine for one canonical-cycle practice attempt.
//
// This coordinator owns ONLY discrete state transitions and attempt
// construction; it never talks to capture hardware, MIDI, or DVS directly.
// The host view is responsible for driving actual recording start/stop
// (reusing the existing routine-recording action verbatim) and for handing
// the coordinator the finished take's evidence snapshot once capture
// finalizes. This keeps the coordinator testable with synthetic evidence,
// with no SwiftUI/view/runtime dependency beyond `Combine`'s
// `ObservableObject` for state publishing.
//
// Scoring stays single-sourced: `completeAttempt` only ever calls
// `PracticeAttemptEvidenceResolver`/`PracticeAttemptBuilder`
// (`ScratchGameplayAttempt.swift`) — this file adds no second judgment of
// correctness.

import Foundation
import Combine

/// One WATCH/COPY/RESULT loop's discrete state. WATCH and its `.ready` gate
/// never carry a score — the only path to `.result` is through `.copying`.
enum PracticeGameplayState: Equatable {
    /// Nothing chosen/started yet, or the loop was reset.
    case idle
    /// Showing the target notation only — never scored.
    case watching
    /// Watch has been shown; the learner may start copying.
    case ready
    /// Exactly one canonical-cycle attempt window is open and capturing.
    case copying(PracticeAttemptSession)
    /// The just-finished attempt's immutable result.
    case result(PracticeAttemptResult)
}

/// The parameters and anchor of one in-flight (or most recently started)
/// attempt — enough for `retry()` to start a fresh one with the same
/// technique/tempo without the caller having to re-supply them.
struct PracticeAttemptSession: Equatable {
    let pattern: ScratchNotation.BeatPattern
    let bpm: Double
    let countInBeats: Int
    let window: GameplayAttemptWindow
    let startedAt: Date

    /// Wall-clock seconds from `startedAt` a host view should wait before
    /// closing the attempt: the count-in plus one full canonical cycle —
    /// matching the take-relative beat-zero anchor (`countInBeats * 60/bpm`)
    /// `PerformanceBeatClock`/`PracticeAttemptEvidenceResolver` already use.
    var closesAfterSeconds: TimeInterval {
        (Double(countInBeats) + window.endBeat) * 60.0 / bpm
    }
}

/// Drives one canonical-cycle attempt end to end. `@MainActor` because the
/// host view reads/mutates it directly on the main run loop, same as any
/// other `ObservableObject` in this app (e.g. `ProgressManager`).
@MainActor
final class PracticeGameplayCoordinator: ObservableObject {
    @Published private(set) var state: PracticeGameplayState = .idle
    private(set) var lastSession: PracticeAttemptSession?

    private let now: () -> Date

    /// `now` is injectable so tests get deterministic `startedAt` values
    /// without depending on wall-clock time.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private var isCopying: Bool {
        if case .copying = state { return true }
        return false
    }

    /// The result of the most recently *completed* attempt, or `nil` while
    /// idle/watching/copying.
    var currentResult: PracticeAttemptResult? {
        if case .result(let result) = state { return result }
        return nil
    }

    /// idle/ready/result → watching. A no-op while an attempt is open —
    /// watching never interrupts a live copy window.
    func beginWatch() {
        guard !isCopying else { return }
        state = .watching
    }

    /// watching → ready. No-op from any other state.
    func finishWatching() {
        guard state == .watching else { return }
        state = .ready
    }

    /// idle/watching/ready/result → copying, anchoring a fresh attempt
    /// window at `now()`. A no-op while already `.copying` — repeated start
    /// commands can never open a second, overlapping attempt window.
    func beginAttempt(pattern: ScratchNotation.BeatPattern, bpm: Double, countInBeats: Int) {
        guard !isCopying else { return }
        guard let window = GameplayAttemptWindow(
            cycleIndex: 0, cycleDurationBeats: pattern.durationBeats
        ) else { return }
        let session = PracticeAttemptSession(
            pattern: pattern, bpm: bpm, countInBeats: countInBeats,
            window: window, startedAt: now()
        )
        lastSession = session
        state = .copying(session)
    }

    /// copying → result. Builds the ONE `PracticeAttemptResult` for the
    /// active session from `snapshot` via `PracticeAttemptEvidenceResolver`
    /// — never re-judges the evidence independently. A no-op, returning
    /// `nil` without transitioning, when not currently `.copying` or when
    /// the snapshot is too thin to assess at all (mirrors
    /// `PracticeAttemptEvidenceResolver`'s own "never guess" contract) — a
    /// late/duplicate completion signal can neither fabricate nor overwrite
    /// a result. A missing stroke does NOT hit this path: it still yields a
    /// real (low) score, matched-and-scored by the comparison engine — only
    /// a snapshot with no usable evidence at all resolves to `nil`.
    @discardableResult
    func completeAttempt(snapshot: CaptureCore.DetectedNotationSnapshot) -> PracticeAttemptResult? {
        guard case .copying(let session) = state else { return nil }
        guard let result = PracticeAttemptEvidenceResolver.firstCycleAttempt(
            pattern: session.pattern, bpm: session.bpm,
            countInBeats: session.countInBeats, snapshot: snapshot
        ) else { return nil }
        state = .result(result)
        return result
    }

    /// result → copying, reusing the just-finished attempt's technique/
    /// tempo/count-in with a fresh window anchored at `now()`. A no-op from
    /// any state other than `.result` — there is nothing to retry before an
    /// attempt has completed. The just-displayed `PracticeAttemptResult` is
    /// a value type the caller may still hold a reference to; nothing here
    /// reaches back into it; `state` simply stops pointing at it once this
    /// returns. "Next Attempt" is the same operation as "Retry" today —
    /// there is no progression yet to advance to, so both host-view buttons
    /// should call this one method.
    func retry() {
        guard case .result = state, let session = lastSession else { return }
        guard let window = GameplayAttemptWindow(
            cycleIndex: 0, cycleDurationBeats: session.pattern.durationBeats
        ) else { return }
        let freshSession = PracticeAttemptSession(
            pattern: session.pattern, bpm: session.bpm, countInBeats: session.countInBeats,
            window: window, startedAt: now()
        )
        lastSession = freshSession
        state = .copying(freshSession)
    }

    /// copying → ready. Unconditionally leaves an open attempt window — the
    /// escape hatch for when the underlying evidence never arrives usable
    /// (e.g. `completeAttempt` kept returning `nil`, or the host view's
    /// manual stop finds capture already idle). Never fabricates or
    /// discards a `PracticeAttemptResult` — there isn't one yet. A no-op
    /// from any state other than `.copying`; in particular it never touches
    /// an already-produced `.result`.
    func abortAttempt() {
        guard isCopying else { return }
        state = .ready
    }
}
