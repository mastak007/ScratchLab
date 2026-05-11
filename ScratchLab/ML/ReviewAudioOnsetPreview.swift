//
//  ReviewAudioOnsetPreview.swift
//  ScratchLab
//
//  Slice P: Review-only, diagnostic-only summary of the audio-onset
//  pipeline's current candidate set, bundled with the display rules the
//  Review surface needs to render the preview WITHOUT modifying any
//  captured / exported notation.
//
//  Hard product rules this file enforces:
//    * Captured notation is the source of truth — when it has events,
//      this preview is supplemental at most. We never recommend the UI
//      replace captured rendering with preview rendering.
//    * Low classifier confidence MUST NOT delete preview candidates.
//      `NotationCandidateBuilder` downgrades unidentified evidence to
//      `.uncertain`; this summary's `timingCandidateCount` includes
//      `.uncertain` and `.onset` rows so the user always sees that a
//      stroke happened, even when its identity is unknown. The
//      `preservesUnclassifiedCandidates` flag is a public assertion of
//      that invariant — tests use it to fail loudly if anyone ever
//      filters uncertain candidates out of the preview.
//    * Silence gaps are tracked but DO NOT count toward the visible
//      "timing candidates" number — they're not strokes, they're the
//      absence of strokes. Reporting them as "candidates" would mislead
//      the reviewer.
//

import Foundation

public struct ReviewAudioOnsetPreview: Equatable, Sendable {

    /// What the Review surface should render given the combination of a
    /// captured snapshot and the live audio-onset summary.
    public enum DisplayMode: String, Codable, Equatable, Sendable {
        /// Captured notation has events; preview is supplemental.
        /// UI should keep showing captured as primary and add preview
        /// as a secondary, clearly-uncertain card.
        case capturedWithSupplementalPreview

        /// Captured notation is empty but audio onsets exist. Preview
        /// is the only signal currently — render it instead of (not in
        /// place of) the "No captured notation yet" empty pane, with
        /// clear "Preview / Uncertain" language.
        case previewWhenCapturedEmpty

        /// Captured notation has events; audio preview has nothing.
        /// Hide the preview card entirely — captured speaks for itself.
        case capturedOnly

        /// Both empty. The existing empty-state pane stays; preview
        /// hides.
        case empty
    }

    public let mode: DisplayMode

    /// User-facing count of stroke-like candidates (onset + stroke +
    /// uncertain + cut). Silence gaps are deliberately excluded.
    public let timingCandidateCount: Int

    /// Detail breakdown — useful for tests and richer UI later.
    public let onsetCount: Int
    public let strokeCount: Int
    public let uncertainCount: Int
    public let cutCount: Int
    public let silenceGapCount: Int

    public let firstTimestamp: TimeInterval?
    public let lastTimestamp: TimeInterval?

    public let isClassified: Bool
    public let identityLabel: String
    public let headerText: String
    public let subtitleText: String
    public let footerDisclaimer: String

    /// Slice S — which input pipeline produced the numbers in this
    /// preview. Drives the user-facing "Source: …" label so reviewers
    /// can tell whether they're looking at the selected take's saved
    /// audio events, live diagnostics, or no source at all.
    public let source: ReviewAudioOnsetSource

    /// Convenience for SwiftUI — `true` when the Review surface should
    /// render the preview card at all.
    public var shouldRender: Bool {
        switch mode {
        case .empty, .capturedOnly: return false
        case .capturedWithSupplementalPreview, .previewWhenCapturedEmpty: return true
        }
    }

    /// Asserted invariant — the preview surface includes uncertain
    /// candidates (i.e. `NotationCandidate.kind == .uncertain` rows
    /// produced by `NotationCandidateBuilder` when classifier confidence
    /// fell below the labelling threshold). If a future change ever
    /// filters those out of `timingCandidateCount`, this flag must
    /// flip to false and the unit tests will fail.
    public var preservesUnclassifiedCandidates: Bool {
        // True by construction: timingCandidateCount sums onset, stroke,
        // uncertain, and cut. Uncertain rows always contribute.
        true
    }

    /// Slice R1 / S — whether the Review preview card should render a
    /// visual timing-mark strip alongside the numeric rows.
    ///
    /// Live-diagnostics rule (R1): the strip renders only in the
    /// `.previewWhenCapturedEmpty` mode, and only when at least one mark
    /// exists. When captured notation has events, the strip is
    /// suppressed even though numeric rows still appear — captured
    /// notation is the source of truth and lives in its own rendering,
    /// and overlaying a parallel uncertain-strip in the same glance
    /// invites the reviewer to read live diagnostics as an alternative
    /// truth.
    ///
    /// Selected-take rule (S): when the strip is visualising the
    /// selected take's saved audio events (not live), it is no longer a
    /// parallel signal — it IS a view of saved data. The strip is
    /// allowed in supplemental mode too, since there's no risk of
    /// confusion with a different "truth."
    ///
    /// Unavailable: always hidden.
    public func shouldRenderTimelineStrip(marksCount: Int) -> Bool {
        guard marksCount > 0 else { return false }
        switch source {
        case .liveDiagnostics:
            return mode == .previewWhenCapturedEmpty
        case .selectedTakeSavedEvents:
            return mode == .previewWhenCapturedEmpty
                || mode == .capturedWithSupplementalPreview
        case .unavailable:
            return false
        }
    }

    /// Compute the preview state from a live diagnostics summary. Pure
    /// function; no state.
    ///
    /// - Parameters:
    ///   - capturedHasEvents: result of `DetectedNotationSnapshot
    ///     .hasDetectedEvents` on the current captured snapshot, or
    ///     `false` when no snapshot exists.
    ///   - summary: latest `NotationCandidateDiagnosticsSummary` from
    ///     `ScratchLabRuntimeDiagnostics.audioOnsetReviewSummary`.
    ///   - source: which pipeline produced this summary. Defaults to
    ///     `.liveDiagnostics`; callers that build preview shells from a
    ///     selected take but happen to pass an empty `summary` (i.e. an
    ///     "unavailable" state) should pass `.unavailable`.
    public static func compute(
        capturedHasEvents: Bool,
        summary: NotationCandidateDiagnosticsSummary,
        source: ReviewAudioOnsetSource = .liveDiagnostics
    ) -> ReviewAudioOnsetPreview {
        let strokeLike =
            summary.onsetCount
            + summary.strokeCount
            + summary.uncertainCount
            + summary.cutCount

        return buildPreview(
            capturedHasEvents: capturedHasEvents,
            timingCandidateCount: strokeLike,
            onsetCount: summary.onsetCount,
            strokeCount: summary.strokeCount,
            uncertainCount: summary.uncertainCount,
            cutCount: summary.cutCount,
            silenceGapCount: summary.silenceGapCount,
            firstTimestamp: summary.firstTimestamp,
            lastTimestamp: summary.lastTimestamp,
            isClassified: summary.isClassified,
            source: source
        )
    }

    /// Slice S — compute the preview state from a selected take's saved
    /// audio events. Pure function; no state. Source is fixed to
    /// `.selectedTakeSavedEvents`. The take summary already reflects any
    /// strength-based cap applied by `ReviewAudioOnsetMarksBuilder`, so
    /// `timingCandidateCount` here is the capped count, not the raw
    /// saved-event count.
    public static func compute(
        capturedHasEvents: Bool,
        takeSummary: ReviewAudioOnsetTakeSummary
    ) -> ReviewAudioOnsetPreview {
        return buildPreview(
            capturedHasEvents: capturedHasEvents,
            timingCandidateCount: takeSummary.timingCandidateCount,
            // Saved-event candidates are treated as plain onsets — there
            // is no per-event stroke/uncertain/cut breakdown at this
            // layer. Reviewers see one consolidated count.
            onsetCount: takeSummary.timingCandidateCount,
            strokeCount: 0,
            uncertainCount: 0,
            cutCount: 0,
            silenceGapCount: 0,
            firstTimestamp: takeSummary.firstTimestamp,
            lastTimestamp: takeSummary.lastTimestamp,
            // Saved audio events carry an `eventKind` string but we
            // deliberately don't promote that to a "classified" label —
            // the preview must not imply classifier truth.
            isClassified: false,
            source: .selectedTakeSavedEvents
        )
    }

    private static func buildPreview(
        capturedHasEvents: Bool,
        timingCandidateCount: Int,
        onsetCount: Int,
        strokeCount: Int,
        uncertainCount: Int,
        cutCount: Int,
        silenceGapCount: Int,
        firstTimestamp: TimeInterval?,
        lastTimestamp: TimeInterval?,
        isClassified: Bool,
        source: ReviewAudioOnsetSource
    ) -> ReviewAudioOnsetPreview {
        let mode: DisplayMode
        if capturedHasEvents && timingCandidateCount > 0 {
            mode = .capturedWithSupplementalPreview
        } else if capturedHasEvents {
            mode = .capturedOnly
        } else if timingCandidateCount > 0 {
            mode = .previewWhenCapturedEmpty
        } else {
            mode = .empty
        }

        let identity = isClassified ? "classified" : "not classified"
        let header: String
        let subtitle: String
        switch mode {
        case .capturedWithSupplementalPreview:
            header = "Audio Onset Preview"
            subtitle = "Supplemental — captured notation is the source of truth."
        case .previewWhenCapturedEmpty:
            header = "Audio Onset Preview · Uncertain"
            subtitle = "Captured notation is empty. Audio onsets suggest activity here; identity is not yet confirmed."
        case .capturedOnly:
            header = "Audio Onset Preview"
            subtitle = "No audio-onset preview available."
        case .empty:
            header = "Audio Onset Preview"
            subtitle = "Preview unavailable — no audio activity detected yet."
        }

        let disclaimer = "Diagnostics-only preview. Not part of saved or exported notation."

        return ReviewAudioOnsetPreview(
            mode: mode,
            timingCandidateCount: timingCandidateCount,
            onsetCount: onsetCount,
            strokeCount: strokeCount,
            uncertainCount: uncertainCount,
            cutCount: cutCount,
            silenceGapCount: silenceGapCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            isClassified: isClassified,
            identityLabel: identity,
            headerText: header,
            subtitleText: subtitle,
            footerDisclaimer: disclaimer,
            source: source
        )
    }

    /// Empty / no-input default. Equivalent to `compute(capturedHasEvents:
    /// false, summary: .empty, source: .unavailable)` but spelled out
    /// for the SwiftUI initial state.
    public static let empty = ReviewAudioOnsetPreview.compute(
        capturedHasEvents: false,
        summary: .empty,
        source: .unavailable
    )
}

/// Slice S — which pipeline produced the numbers behind a Review audio-
/// onset preview. Drives the user-facing "Source: …" label and a few
/// behaviour switches (e.g. when the timeline strip is allowed to
/// render).
public enum ReviewAudioOnsetSource: String, Codable, Equatable, Sendable {
    /// The selected take's saved `audioEvents`. Take-scoped; the source
    /// of truth for the take's audio timing. Never live.
    case selectedTakeSavedEvents

    /// The live `ScratchLabRuntimeDiagnostics` audio-onset accumulator.
    /// Only used when there is no selected take to scope to — otherwise
    /// it leaks unrelated audio activity into Review.
    case liveDiagnostics

    /// No usable source. Either a take is selected but has no saved
    /// audio events, or no take is selected and live has no activity.
    /// The preview card hides.
    case unavailable

    /// User-facing label for the card's "Source:" row.
    public var label: String {
        switch self {
        case .selectedTakeSavedEvents:
            return "selected take audio"
        case .liveDiagnostics:
            return "live diagnostics"
        case .unavailable:
            return "no take audio available"
        }
    }
}

/// Slice S — a minimal, library-portable audio event for the Review
/// onset preview. Mirrors the fields of `CaptureCore
/// .DetectedNotationAudioEvent` that the preview needs (start time and
/// a strength proxy) without forcing the ML library to import
/// CaptureCore's snapshot types.
public struct ReviewAudioOnsetTakeEvent: Equatable, Sendable {
    public let startTime: TimeInterval
    public let peakLevel: Double

    public init(startTime: TimeInterval, peakLevel: Double) {
        self.startTime = startTime
        self.peakLevel = peakLevel
    }
}

/// Slice S — summary stats derived from a selected take's audio events
/// after capping. Matches the shape `ReviewAudioOnsetPreview.compute`
/// needs without leaking the underlying event list.
public struct ReviewAudioOnsetTakeSummary: Equatable, Sendable {
    /// Capped count — what the card's "Timing candidates" row shows.
    public let timingCandidateCount: Int
    /// Total saved-event count before the cap. Use this for the
    /// "Raw (saved)" disclosure row when it exceeds `timingCandidateCount`.
    public let rawEventCount: Int
    public let firstTimestamp: TimeInterval?
    public let lastTimestamp: TimeInterval?

    public init(
        timingCandidateCount: Int,
        rawEventCount: Int,
        firstTimestamp: TimeInterval?,
        lastTimestamp: TimeInterval?
    ) {
        self.timingCandidateCount = timingCandidateCount
        self.rawEventCount = rawEventCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
    }

    public static let empty = ReviewAudioOnsetTakeSummary(
        timingCandidateCount: 0,
        rawEventCount: 0,
        firstTimestamp: nil,
        lastTimestamp: nil
    )
}

/// Slice S — picks which input pipeline the Review preview should pull
/// from. Pure function; the caller is expected to translate the
/// returned source into the appropriate `ReviewAudioOnsetPreview
/// .compute(…)` overload.
public struct ReviewAudioOnsetSourceResolver {
    /// - Parameters:
    ///   - hasSelectedTake: true when a take artifact is present (i.e.
    ///     the reviewer is inspecting a recorded take, not a fresh
    ///     diagnostic session).
    ///   - takeAudioEventCount: number of saved audio events on the
    ///     selected take. Zero when no take or no audio detection.
    ///   - liveTimingCandidateCount: stroke-like count from the live
    ///     accumulator (onset + stroke + uncertain + cut).
    public static func resolve(
        hasSelectedTake: Bool,
        takeAudioEventCount: Int,
        liveTimingCandidateCount: Int
    ) -> ReviewAudioOnsetSource {
        if hasSelectedTake {
            // Take-scoped: never reach for live, even if the take has
            // no saved audio events. Live diagnostics from a different
            // session would be misleading here.
            return takeAudioEventCount > 0
                ? .selectedTakeSavedEvents
                : .unavailable
        }
        // No take: live is the only signal that can populate the card.
        return liveTimingCandidateCount > 0 ? .liveDiagnostics : .unavailable
    }
}

/// Slice S — builds visual timing marks (and a matching summary) from a
/// selected take's saved audio events. Mirrors the live pipeline's
/// behaviour: cap by strength to `maxMarks`, then re-sort by timestamp
/// so first/last semantics hold.
public struct ReviewAudioOnsetMarksBuilder {
    /// Same default as `NotationCandidateAccumulator.currentReviewMarks`'
    /// cap so live and take-scoped previews can never disagree on what
    /// "Timing candidates" means at a glance.
    public static let defaultMaxMarks: Int = 80

    /// Returns mark timestamps in ascending order, after taking the
    /// `maxMarks` strongest events (by `peakLevel`). Returns `[]` for
    /// empty input or `maxMarks <= 0`.
    public static func buildFromTakeEvents(
        _ events: [ReviewAudioOnsetTakeEvent],
        maxMarks: Int = defaultMaxMarks
    ) -> [TimeInterval] {
        guard maxMarks > 0, !events.isEmpty else { return [] }
        if events.count <= maxMarks {
            return events.map(\.startTime).sorted()
        }
        let topN = events
            .sorted { $0.peakLevel > $1.peakLevel }
            .prefix(maxMarks)
        return topN.map(\.startTime).sorted()
    }

    /// Build the summary stats the preview card needs — capped count,
    /// raw count, first/last timestamps of the capped set.
    public static func summarizeTakeEvents(
        _ events: [ReviewAudioOnsetTakeEvent],
        maxMarks: Int = defaultMaxMarks
    ) -> ReviewAudioOnsetTakeSummary {
        let marks = buildFromTakeEvents(events, maxMarks: maxMarks)
        return ReviewAudioOnsetTakeSummary(
            timingCandidateCount: marks.count,
            rawEventCount: events.count,
            firstTimestamp: marks.first,
            lastTimestamp: marks.last
        )
    }
}

/// Slice Q — copy bundle for the Review "captured notation empty" pane.
/// Pure function over (`previewWillRender`, current default subtitle) so
/// the wording rule is unit-testable and the Review view stays
/// dumb-renderer code.
///
/// Behaviour matrix the wording must satisfy:
///   * captured empty + onset preview WILL render → subtitle must point
///     the user at the preview below AND say it's diagnostics-only and
///     not exported.
///   * captured empty + onset preview won't render → subtitle is the
///     existing copy the view already computes (no change).
///   * captured-present and preview-present cases never reach this
///     helper — those branches aren't the empty pane.
public struct ReviewCapturedEmptyStateCopy: Equatable, Sendable {
    public let title: String
    public let subtitle: String

    /// Set when `subtitle` was overridden to reference the audio-onset
    /// preview below. Lets tests assert the user is actually pointed at
    /// the preview without coupling to the exact wording.
    public let referencesPreview: Bool

    public static func compute(
        previewWillRender: Bool,
        defaultSubtitle: String
    ) -> ReviewCapturedEmptyStateCopy {
        if previewWillRender {
            return ReviewCapturedEmptyStateCopy(
                title: "No captured notation yet",
                subtitle: "No saved notation was created for this take. An audio timing preview is available below — diagnostics only, uncertain identity, not part of exported notation.",
                referencesPreview: true
            )
        }
        return ReviewCapturedEmptyStateCopy(
            title: "No captured notation yet",
            subtitle: defaultSubtitle,
            referencesPreview: false
        )
    }
}
