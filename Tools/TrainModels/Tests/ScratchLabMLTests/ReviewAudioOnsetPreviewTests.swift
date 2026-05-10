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
                headerText: "", subtitleText: "", footerDisclaimer: ""
            )
            XCTAssertEqual(p.shouldRender, expected, "mode \(mode) -> shouldRender \(expected)")
        }
    }

    // MARK: Snapshot schema isolation

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
}
