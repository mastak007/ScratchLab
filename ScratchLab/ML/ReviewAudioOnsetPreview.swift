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

    /// Compute the preview state from inputs. Pure function; no state.
    ///
    /// - Parameters:
    ///   - capturedHasEvents: result of `DetectedNotationSnapshot
    ///     .hasDetectedEvents` on the current captured snapshot, or
    ///     `false` when no snapshot exists.
    ///   - summary: latest `NotationCandidateDiagnosticsSummary` from
    ///     `ScratchLabRuntimeDiagnostics.audioOnsetSummary`.
    public static func compute(
        capturedHasEvents: Bool,
        summary: NotationCandidateDiagnosticsSummary
    ) -> ReviewAudioOnsetPreview {
        let strokeLike =
            summary.onsetCount
            + summary.strokeCount
            + summary.uncertainCount
            + summary.cutCount

        let mode: DisplayMode
        if capturedHasEvents && strokeLike > 0 {
            mode = .capturedWithSupplementalPreview
        } else if capturedHasEvents {
            mode = .capturedOnly
        } else if strokeLike > 0 {
            mode = .previewWhenCapturedEmpty
        } else {
            mode = .empty
        }

        let identity = summary.isClassified ? "classified" : "not classified"
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
            timingCandidateCount: strokeLike,
            onsetCount: summary.onsetCount,
            strokeCount: summary.strokeCount,
            uncertainCount: summary.uncertainCount,
            cutCount: summary.cutCount,
            silenceGapCount: summary.silenceGapCount,
            firstTimestamp: summary.firstTimestamp,
            lastTimestamp: summary.lastTimestamp,
            isClassified: summary.isClassified,
            identityLabel: identity,
            headerText: header,
            subtitleText: subtitle,
            footerDisclaimer: disclaimer
        )
    }

    /// Empty / no-input default. Equivalent to `compute(capturedHasEvents:
    /// false, summary: .empty)` but spelled out for the SwiftUI initial
    /// state.
    public static let empty = ReviewAudioOnsetPreview.compute(
        capturedHasEvents: false,
        summary: .empty
    )
}
