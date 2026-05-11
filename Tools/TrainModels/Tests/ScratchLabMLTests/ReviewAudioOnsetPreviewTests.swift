//
//  ReviewAudioOnsetPreviewTests.swift
//  ScratchLabMLTests — Slice P
//
//  Behavioural coverage required by the slice spec:
//    * onset preview candidates are produced from audio timing
//    * low classifier confidence does not remove preview candidates
//    * captured notation is treated as source of truth — preview never
//      claims to replace it
//    * silence gaps don't inflate the user-facing candidate count
//    * the preview hides itself when there's nothing useful to show
//    * `shouldRender` agrees with `mode` for every combination
//

import XCTest
@testable import ScratchLabML

final class ReviewAudioOnsetPreviewTests: XCTestCase {

    // MARK: Helpers

    private func summary(
        onset: Int = 0,
        stroke: Int = 0,
        uncertain: Int = 0,
        cut: Int = 0,
        silenceGap: Int = 0,
        first: TimeInterval? = nil,
        last: TimeInterval? = nil,
        isClassified: Bool = false
    ) -> NotationCandidateDiagnosticsSummary {
        NotationCandidateDiagnosticsSummary(
            candidateCount: onset + stroke + uncertain + cut + silenceGap,
            onsetCount: onset,
            strokeCount: stroke,
            uncertainCount: uncertain,
            silenceGapCount: silenceGap,
            cutCount: cut,
            firstTimestamp: first,
            lastTimestamp: last,
            meanStrength: stroke + uncertain > 0 ? 1.0 : 0.0,
            strongestStrength: stroke + uncertain > 0 ? 1.5 : 0.0,
            envelopeFrameCount: 1024,
            envelopeDurationSeconds: 10.0,
            isClassified: isClassified
        )
    }

    // MARK: Empty cases

    func testEmptyEverythingHidesThePreview() {
        let p = ReviewAudioOnsetPreview.compute(capturedHasEvents: false, summary: .empty)
        XCTAssertEqual(p.mode, .empty)
        XCTAssertFalse(p.shouldRender)
        XCTAssertEqual(p.timingCandidateCount, 0)
    }

    func testCapturedHasEventsButNoAudioPreviewHidesPreview() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            summary: .empty
        )
        XCTAssertEqual(p.mode, .capturedOnly)
        XCTAssertFalse(p.shouldRender, "captured-only should hide the preview card entirely")
    }

    // MARK: Preview-when-empty (the headline Slice P case)

    func testCapturedEmptyAndAudioOnsetsPresentShowsPreview() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 12, first: 0.42, last: 8.91)
        )
        XCTAssertEqual(p.mode, .previewWhenCapturedEmpty)
        XCTAssertTrue(p.shouldRender)
        XCTAssertEqual(p.timingCandidateCount, 12)
        XCTAssertEqual(p.onsetCount, 12)
        XCTAssertEqual(p.firstTimestamp, 0.42)
        XCTAssertEqual(p.lastTimestamp, 8.91)
        XCTAssertFalse(p.isClassified)
        XCTAssertEqual(p.identityLabel, "not classified")
        XCTAssertTrue(p.headerText.contains("Uncertain"),
                      "fallback preview must clearly say Uncertain in the header")
    }

    // MARK: PRODUCT INVARIANT — low classifier confidence preserved

    /// `NotationCandidateBuilder` downgrades evidence with sub-threshold
    /// classifier confidence to `.uncertain` (instead of dropping it).
    /// Slice P must surface those rows in the user-facing candidate
    /// count, otherwise low-confidence audio onsets would be invisible
    /// to the reviewer — defeating the whole product invariant.
    func testLowClassifierConfidenceDoesNotRemovePreviewCandidates() {
        // 4 unidentified onsets, 3 downgraded-to-uncertain rows.
        // Imagine the classifier returned 0.20 for the 3 — the builder
        // turned them into .uncertain, summarize() reports them in
        // uncertainCount, and the preview should add them in.
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 4, uncertain: 3)
        )
        XCTAssertEqual(p.mode, .previewWhenCapturedEmpty)
        XCTAssertEqual(p.timingCandidateCount, 7,
                       "4 onsets + 3 uncertain must all count toward the visible total")
        XCTAssertEqual(p.uncertainCount, 3)
        XCTAssertTrue(p.preservesUnclassifiedCandidates,
                      "the public invariant flag must be true while the formula sums uncertain rows")
    }

    func testIdentityClassifiedFlagFlowsThroughUnchanged() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(stroke: 5, isClassified: true)
        )
        XCTAssertTrue(p.isClassified)
        XCTAssertEqual(p.identityLabel, "classified")
    }

    // MARK: Silence gap accounting

    func testSilenceGapsDoNotCountAsTimingCandidates() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(silenceGap: 4)
        )
        // No onsets / strokes / uncertain — only silence gaps. The
        // candidate count must be 0 even though `candidateCount` in
        // the underlying summary is 4.
        XCTAssertEqual(p.timingCandidateCount, 0)
        XCTAssertEqual(p.silenceGapCount, 4)
        XCTAssertEqual(p.mode, .empty)
        XCTAssertFalse(p.shouldRender, "silence gaps alone don't justify a preview card")
    }

    // MARK: Captured + supplemental

    func testCapturedWithEventsAndAudioPreviewIsSupplemental() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            summary: summary(onset: 6, uncertain: 2)
        )
        XCTAssertEqual(p.mode, .capturedWithSupplementalPreview)
        XCTAssertTrue(p.shouldRender)
        XCTAssertEqual(p.timingCandidateCount, 8)
        XCTAssertTrue(p.subtitleText.contains("Supplemental"),
                      "supplemental mode must say so in the subtitle so the reviewer knows captured is primary")
    }

    // MARK: Disclaimer

    func testDisclaimerIsAlwaysPresentAndDoesNotMentionExport() {
        let modes: [(Bool, NotationCandidateDiagnosticsSummary)] = [
            (false, .empty),
            (true,  .empty),
            (false, summary(onset: 3)),
            (true,  summary(onset: 3, uncertain: 1)),
        ]
        for (captured, s) in modes {
            let p = ReviewAudioOnsetPreview.compute(capturedHasEvents: captured, summary: s)
            XCTAssertFalse(p.footerDisclaimer.isEmpty)
            // The disclaimer must say "Not part of saved or exported notation"
            // so the reviewer can never confuse preview with truth.
            XCTAssertTrue(
                p.footerDisclaimer.localizedCaseInsensitiveContains("not part of saved")
                && p.footerDisclaimer.localizedCaseInsensitiveContains("export"),
                "disclaimer must explicitly say it's not part of saved/exported notation"
            )
        }
    }

    // MARK: Mode/shouldRender consistency

    func testShouldRenderAgreesWithModeForEveryCombination() {
        let table: [(ReviewAudioOnsetPreview.DisplayMode, Bool)] = [
            (.empty, false),
            (.capturedOnly, false),
            (.previewWhenCapturedEmpty, true),
            (.capturedWithSupplementalPreview, true),
        ]
        for (mode, expected) in table {
            // Construct directly to test invariant (compute paths covered above).
            let p = ReviewAudioOnsetPreview(
                mode: mode,
                timingCandidateCount: 0, onsetCount: 0, strokeCount: 0,
                uncertainCount: 0, cutCount: 0, silenceGapCount: 0,
                firstTimestamp: nil, lastTimestamp: nil,
                isClassified: false, identityLabel: "not classified",
                headerText: "", subtitleText: "", footerDisclaimer: "",
                source: .liveDiagnostics
            )
            XCTAssertEqual(p.shouldRender, expected, "mode \(mode) -> shouldRender \(expected)")
        }
    }

    // MARK: Snapshot schema isolation

    // MARK: Slice Q — empty-state copy

    func testEmptyStateCopyReferencesPreviewWhenPreviewWillRender() {
        let copy = ReviewCapturedEmptyStateCopy.compute(
            previewWillRender: true,
            defaultSubtitle: "Notation unavailable for this take."
        )
        XCTAssertEqual(copy.title, "No captured notation yet")
        XCTAssertTrue(copy.referencesPreview,
                      "when preview will render the subtitle must reference it")
        // Subtitle must explicitly say: (a) nothing was saved/created
        // for this take, (b) the preview is below, (c) it's diagnostics
        // / not exported.
        let lower = copy.subtitle.lowercased()
        XCTAssertTrue(lower.contains("no saved notation") || lower.contains("not saved"),
                      "subtitle must tell the user no saved notation was created")
        XCTAssertTrue(lower.contains("preview") && lower.contains("below"),
                      "subtitle must point at the preview below")
        XCTAssertTrue(lower.contains("not part of exported") || lower.contains("not exported"),
                      "subtitle must clarify the preview is not exported")
        XCTAssertTrue(lower.contains("diagnostic") || lower.contains("uncertain"),
                      "subtitle must convey the preview is uncertain / diagnostic")
    }

    func testEmptyStateCopyFallsBackToDefaultSubtitleWhenNoPreview() {
        let defaultMsg = "Notation unavailable for this take. ScratchLab will only show a preview when real captured movement events were saved."
        let copy = ReviewCapturedEmptyStateCopy.compute(
            previewWillRender: false,
            defaultSubtitle: defaultMsg
        )
        XCTAssertEqual(copy.title, "No captured notation yet",
                       "title is stable — only the subtitle ever changes")
        XCTAssertEqual(copy.subtitle, defaultMsg,
                       "no-preview branch must pass the existing default subtitle through unchanged")
        XCTAssertFalse(copy.referencesPreview)
    }

    func testEmptyStateCopyTitleIsStableAcrossBranches() {
        // The user is supposed to read the title and immediately know
        // "I have no captured take". The branching is purely in the
        // subtitle — title must not drift between modes.
        let a = ReviewCapturedEmptyStateCopy.compute(
            previewWillRender: true,
            defaultSubtitle: "A"
        )
        let b = ReviewCapturedEmptyStateCopy.compute(
            previewWillRender: false,
            defaultSubtitle: "B"
        )
        XCTAssertEqual(a.title, b.title)
    }

    /// Slice Q must not modify any other Review branch. We can't compile
    /// a SwiftUI tree from a SwiftPM test, but we CAN assert that the
    /// helper exposes only the strings it claims to expose — anyone
    /// extending it to start gating captured-present rendering would
    /// have to add a new field, which a brittle reflection test catches.
    func testEmptyStateCopyHasNoCapturedPresentSurface() {
        let copy = ReviewCapturedEmptyStateCopy.compute(
            previewWillRender: false,
            defaultSubtitle: "anything"
        )
        let m = Mirror(reflecting: copy)
        let names = Set(m.children.compactMap(\.label))
        XCTAssertEqual(names, ["title", "subtitle", "referencesPreview"],
                       "if a captured-present field shows up here, Slice Q has overreached")
    }

    func testPreviewDoesNotReferenceAnyDetectedNotationSnapshotShape() throws {
        // Slice P contract: this preview type must not depend on
        // `CaptureCore.DetectedNotationSnapshot` so that changing the
        // captured/exported schema can never break the preview, and
        // vice-versa. Lock that in by inspecting Mirror — there must
        // be no field whose type-name contains "DetectedNotation" or
        // "RawMixerMIDI" or any other captured-notation artefact.
        let p = ReviewAudioOnsetPreview.empty
        let m = Mirror(reflecting: p)
        for child in m.children {
            let typeName = String(describing: type(of: child.value))
            XCTAssertFalse(typeName.contains("DetectedNotation"),
                           "preview must not embed DetectedNotation-derived types — found \(typeName)")
            XCTAssertFalse(typeName.contains("RawMixer"),
                           "preview must not embed mixer-event types — found \(typeName)")
        }
    }

    // MARK: Slice R1 — timeline-strip render predicate

    func testTimelineStripHidesWhenNoMarksRegardlessOfMode() {
        // Empty mode.
        let empty = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false, summary: .empty
        )
        XCTAssertFalse(empty.shouldRenderTimelineStrip(marksCount: 0))

        // capturedOnly.
        let capturedOnly = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true, summary: .empty
        )
        XCTAssertFalse(capturedOnly.shouldRenderTimelineStrip(marksCount: 0))

        // capturedWithSupplementalPreview but zero marks (unreachable
        // in practice, but the guard still has to hold).
        let supplementalZero = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            summary: summary(onset: 4, first: 0.1, last: 1.0)
        )
        XCTAssertFalse(supplementalZero.shouldRenderTimelineStrip(marksCount: 0))

        // previewWhenCapturedEmpty + zero marks.
        let previewZero = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 4, first: 0.1, last: 1.0)
        )
        XCTAssertFalse(previewZero.shouldRenderTimelineStrip(marksCount: 0))
    }

    func testTimelineStripShowsOnlyWhenCapturedIsEmptyAndPreviewHasMarks() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 8, first: 0.20, last: 4.50)
        )
        XCTAssertEqual(p.mode, .previewWhenCapturedEmpty,
                       "sanity: this combination must produce the preview-when-empty mode")
        XCTAssertTrue(p.shouldRenderTimelineStrip(marksCount: 8))
        XCTAssertTrue(p.shouldRenderTimelineStrip(marksCount: 1))
    }

    func testTimelineStripHidesInSupplementalModeEvenWhenMarksExist() {
        // Captured exists AND onsets exist → supplemental mode. By
        // design, the visual strip stays hidden so reviewers don't read
        // it as an alternative truth alongside saved captured notation.
        // Numeric rows still render.
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            summary: summary(onset: 8, first: 0.20, last: 4.50)
        )
        XCTAssertEqual(p.mode, .capturedWithSupplementalPreview)
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 8),
                       "strip must not render when captured notation exists, even if preview has marks")
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 80))
    }

    func testTimelineStripHidesInCapturedOnlyMode() {
        // Captured exists, preview is empty — preview card already
        // hides; the strip must also be off (defence in depth).
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true, summary: .empty
        )
        XCTAssertEqual(p.mode, .capturedOnly)
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 8))
    }

    func testTimelineStripPredicateOnlyDependsOnModeAndMarksCount() {
        // The predicate signature takes only marksCount; verify that
        // changing other summary fields under a fixed mode (and same
        // source) doesn't change the answer.
        let modeA = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 3, first: 0.1, last: 1.0)
        )
        let modeB = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(uncertain: 3, first: 5.0, last: 9.0, isClassified: true)
        )
        XCTAssertEqual(modeA.mode, modeB.mode)
        XCTAssertEqual(modeA.source, modeB.source)
        XCTAssertEqual(modeA.shouldRenderTimelineStrip(marksCount: 3),
                       modeB.shouldRenderTimelineStrip(marksCount: 3))
        XCTAssertEqual(modeA.shouldRenderTimelineStrip(marksCount: 0),
                       modeB.shouldRenderTimelineStrip(marksCount: 0))
    }

    // MARK: Slice S — source field, take-events compute, source-aware strip

    private func takeSummary(
        timing: Int,
        raw: Int? = nil,
        first: TimeInterval? = nil,
        last: TimeInterval? = nil
    ) -> ReviewAudioOnsetTakeSummary {
        ReviewAudioOnsetTakeSummary(
            timingCandidateCount: timing,
            rawEventCount: raw ?? timing,
            firstTimestamp: first,
            lastTimestamp: last
        )
    }

    func testLiveSummaryComputeDefaultsToLiveDiagnosticsSource() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: summary(onset: 4, first: 0.2, last: 1.5)
        )
        XCTAssertEqual(p.source, .liveDiagnostics,
                       "legacy compute(capturedHasEvents:summary:) must default source to liveDiagnostics")
    }

    func testLiveSummaryComputeAcceptsExplicitUnavailableSource() {
        // Used by the SwiftUI shell when a take is selected but has no
        // saved events — caller still wants an empty preview surface.
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: .empty,
            source: .unavailable
        )
        XCTAssertEqual(p.source, .unavailable)
        XCTAssertEqual(p.mode, .empty)
        XCTAssertFalse(p.shouldRender)
    }

    func testTakeSummaryComputeUsesSelectedTakeSavedEventsSource() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            takeSummary: takeSummary(timing: 12, raw: 30, first: 0.20, last: 4.50)
        )
        XCTAssertEqual(p.source, .selectedTakeSavedEvents)
        XCTAssertEqual(p.timingCandidateCount, 12)
        XCTAssertEqual(p.firstTimestamp, 0.20)
        XCTAssertEqual(p.lastTimestamp, 4.50)
        XCTAssertEqual(p.mode, .previewWhenCapturedEmpty)
        XCTAssertTrue(p.shouldRender)
    }

    func testTakeSummaryComputeNeverPromotesEventsToClassified() {
        // Saved audio events carry an eventKind string. The preview
        // must NOT treat that as classifier truth — identity stays
        // "not classified".
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            takeSummary: takeSummary(timing: 5, first: 0.1, last: 1.0)
        )
        XCTAssertFalse(p.isClassified)
        XCTAssertEqual(p.identityLabel, "not classified")
    }

    func testTakeSummaryComputeAllZeroProducesEmptyMode() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            takeSummary: .empty
        )
        XCTAssertEqual(p.mode, .empty)
        XCTAssertFalse(p.shouldRender)
        XCTAssertEqual(p.source, .selectedTakeSavedEvents,
                       "source field is set by the constructor regardless of mode")
    }

    func testTakeSummaryComputeWithCapturedEventsIsSupplemental() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            takeSummary: takeSummary(timing: 5, first: 0.2, last: 1.0)
        )
        XCTAssertEqual(p.mode, .capturedWithSupplementalPreview)
        XCTAssertTrue(p.shouldRender)
    }

    func testTimelineStripAllowsSupplementalForSelectedTakeSource() {
        // Slice S relaxation: the strip can render in supplemental mode
        // when the source IS the saved take data (no risk of parallel-
        // truth confusion).
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            takeSummary: takeSummary(timing: 8, first: 0.2, last: 4.5)
        )
        XCTAssertEqual(p.mode, .capturedWithSupplementalPreview)
        XCTAssertEqual(p.source, .selectedTakeSavedEvents)
        XCTAssertTrue(p.shouldRenderTimelineStrip(marksCount: 8),
                      "strip must render for selected-take saved events even in supplemental mode")
    }

    func testTimelineStripStillHiddenInSupplementalForLiveSource() {
        // Slice R1 invariant is preserved for the live source.
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: true,
            summary: summary(onset: 8, first: 0.2, last: 4.5)
        )
        XCTAssertEqual(p.mode, .capturedWithSupplementalPreview)
        XCTAssertEqual(p.source, .liveDiagnostics)
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 8),
                       "Slice R1 rule must still apply to liveDiagnostics source")
    }

    func testTimelineStripIsAlwaysHiddenForUnavailableSource() {
        let p = ReviewAudioOnsetPreview.compute(
            capturedHasEvents: false,
            summary: .empty,
            source: .unavailable
        )
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 80))
        XCTAssertFalse(p.shouldRenderTimelineStrip(marksCount: 1))
    }

    func testSourceLabelStringsAreUserFacingAndDistinct() {
        // Cheap copy lock so a future relabel can't silently produce
        // duplicates or empty strings.
        let labels = [
            ReviewAudioOnsetSource.selectedTakeSavedEvents.label,
            ReviewAudioOnsetSource.liveDiagnostics.label,
            ReviewAudioOnsetSource.unavailable.label,
        ]
        XCTAssertEqual(
            labels,
            [
                "selected take audio",
                "live diagnostics",
                "no take audio available",
            ]
        )
        XCTAssertEqual(Set(labels).count, labels.count, "source labels must be distinct")
        for l in labels {
            XCTAssertFalse(l.isEmpty)
        }
    }

    func testEmptyConstantIsUnavailableSource() {
        XCTAssertEqual(ReviewAudioOnsetPreview.empty.source, .unavailable)
        XCTAssertEqual(ReviewAudioOnsetPreview.empty.mode, .empty)
    }
}
