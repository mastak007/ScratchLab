#if DEBUG
import SwiftUI

// MARK: - Preview Data Factory

/// Synthesizes in-memory `ScratchNotation` fixtures for `ScratchNotationPanel`
/// previews. `faderCutDemo` and `holdRestDemo` are SYNTHETIC demo data used
/// only to exercise the existing binary fader rail and hold/rest geometry
/// visually — they are not canonical technique definitions (no
/// `ScratchLibrary`-matching `scratchID`, no `BeatPattern` entry) and must
/// never be read as authored technique truth.
private enum ScratchNotationPanelPreviewFactory {

    /// The one real canonical target: the bundled Baby Scratch reference.
    static var babyScratch: ScratchNotation {
        ScratchNotation.babyScratch
            ?? ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch")?.materialized(bpm: 90)
            ?? fallback
    }

    private static var fallback: ScratchNotation {
        ScratchNotation(version: 1, scratchID: "preview_fallback",
                         demoStart: 0, demoEnd: 1, phraseStart: 0, phraseEnd: 1,
                         timingBasis: "seconds", strokes: [])
    }

    /// SYNTHETIC — not a canonical technique. Two closed-fader strokes
    /// bracketed by open strokes, for visually verifying the OPEN/CLOSED
    /// binary rail and its transition markers.
    static var faderCutDemo: ScratchNotation {
        ScratchNotation(
            version: 1, scratchID: "preview_fader_cut_demo",
            demoStart: 0, demoEnd: 2.0, phraseStart: 0, phraseEnd: 2.0,
            timingBasis: "seconds",
            strokes: [
                .init(startTime: 0.0, endTime: 0.5, direction: .forward, speedClassification: .medium, faderState: .open),
                .init(startTime: 0.5, endTime: 1.0, direction: .backward, speedClassification: .medium, faderState: .closed),
                .init(startTime: 1.0, endTime: 1.5, direction: .forward, speedClassification: .medium, faderState: .closed),
                .init(startTime: 1.5, endTime: 2.0, direction: .backward, speedClassification: .medium, faderState: .open)
            ],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.5, state: .closed),
                .init(time: 1.5, state: .open)
            ]
        )
    }

    /// SYNTHETIC — not a canonical technique. A one-second hold/rest gap
    /// between two strokes, for visually verifying that silence still
    /// occupies musical time rather than collapsing the domain.
    static var holdRestDemo: ScratchNotation {
        ScratchNotation(
            version: 1, scratchID: "preview_hold_rest_demo",
            demoStart: 0, demoEnd: 2.0, phraseStart: 0, phraseEnd: 2.0,
            timingBasis: "seconds",
            strokes: [
                .init(startTime: 0.0, endTime: 0.5, direction: .forward, speedClassification: .medium, faderState: .open),
                .init(startTime: 1.5, endTime: 2.0, direction: .backward, speedClassification: .medium, faderState: .open)
            ]
        )
    }
}

// MARK: - Previews — the four approved Figma variants

#Preview("Target — Standard") {
    ScratchNotationPanel(
        lane: .target,
        presentation: .standard,
        source: .target(ScratchNotationPanelPreviewFactory.babyScratch),
        bpm: 90
    )
    .padding()
    .frame(width: 560)
}

#Preview("Performance — Standard") {
    ScratchNotationPanel(
        lane: .performance,
        presentation: .standard,
        source: .target(ScratchNotationPanelPreviewFactory.babyScratch),
        bpm: 90
    )
    .padding()
    .frame(width: 560)
}

#Preview("Target — Compact") {
    ScratchNotationPanel(
        lane: .target,
        presentation: .compact,
        source: .target(ScratchNotationPanelPreviewFactory.babyScratch),
        bpm: 90
    )
    .padding()
    .frame(width: 340)
}

#Preview("Performance — Compact") {
    ScratchNotationPanel(
        lane: .performance,
        presentation: .compact,
        source: .target(ScratchNotationPanelPreviewFactory.babyScratch),
        bpm: 90
    )
    .padding()
    .frame(width: 340)
}

// MARK: - Previews — regression/visual-verification examples

#Preview("Fader cut (synthetic demo)") {
    ScratchNotationPanel(
        lane: .target,
        presentation: .standard,
        source: .target(ScratchNotationPanelPreviewFactory.faderCutDemo),
        bpm: 90
    )
    .padding()
    .frame(width: 560)
}

#Preview("Hold / rest (synthetic demo)") {
    ScratchNotationPanel(
        lane: .target,
        presentation: .standard,
        source: .target(ScratchNotationPanelPreviewFactory.holdRestDemo),
        bpm: 90
    )
    .padding()
    .frame(width: 560)
}

#Preview("Stacked Target / Performance — shared domain") {
    let target = ScratchNotationPanelPreviewFactory.babyScratch
    let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: target.timelineDuration)
    return VStack(spacing: 12) {
        ScratchNotationPanel(
            lane: .target,
            presentation: .standard,
            source: .target(target),
            bpm: 90,
            domain: domain
        )
        ScratchNotationPanel(
            lane: .performance,
            presentation: .standard,
            source: .performedPlatter([]),
            bpm: 90,
            domain: domain
        )
    }
    .padding()
    .frame(width: 560)
}

#endif
