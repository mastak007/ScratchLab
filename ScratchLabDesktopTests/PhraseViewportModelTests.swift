import CoreGraphics
import Testing
@testable import ScratchLab

// Pure unit tests for the live practice-notation viewport geometry. The model
// has no SwiftUI or scroll state, so these construct strokes, call `resolve`,
// and assert — no simulator, no view host.

// MARK: - Fixtures

/// Two phrases (1.0–3.5 s and 10.0–11.5 s) split by a 6.5 s silent gap — the
/// same shape as the bundled Baby Scratch routine, which is several phrases
/// separated by multi-second rests.
private func twoPhraseStrokes() -> [StrokeSpan] {
    [
        StrokeSpan(startTime: 1.0, endTime: 1.5),
        StrokeSpan(startTime: 2.0, endTime: 2.5),
        StrokeSpan(startTime: 3.0, endTime: 3.5),
        StrokeSpan(startTime: 10.0, endTime: 10.5),
        StrokeSpan(startTime: 11.0, endTime: 11.5),
    ]
}

private func twoPhraseModel() -> NotationViewportModel {
    NotationViewportModel(strokes: twoPhraseStrokes())
}

/// Width chosen so phrase 0's padded window (0.4–4.1 s, span 3.7 s) resolves
/// to a round 100 points/second.
private let phrase0Width: CGFloat = 370

// MARK: - Tests

@Suite("NotationViewportModel")
struct PhraseViewportModelTests {

    // MARK: Phrase derivation

    @Test("Strokes split into phrases on the long silent gap")
    func derivesTwoPhrases() {
        let model = twoPhraseModel()
        #expect(model.phrases.count == 2)
        #expect(model.phrases[0].strokeIndices == 0..<3)
        #expect(model.phrases[1].strokeIndices == 3..<5)
        #expect(abs(model.phrases[0].startTime - 1.0) < 1e-6)
        #expect(abs(model.phrases[0].endTime - 3.5) < 1e-6)
        #expect(abs(model.phrases[1].startTime - 10.0) < 1e-6)
        #expect(abs(model.phrases[1].endTime - 11.5) < 1e-6)
    }

    @Test("Within-phrase gaps below the threshold stay one phrase")
    func tightStrokesStayOnePhrase() {
        let model = NotationViewportModel(strokes: [
            StrokeSpan(startTime: 0.0, endTime: 0.4),
            StrokeSpan(startTime: 0.6, endTime: 1.0),
            StrokeSpan(startTime: 1.2, endTime: 1.6),
        ])
        #expect(model.phrases.count == 1)
        #expect(model.phrases[0].strokeIndices == 0..<3)
    }

    // MARK: Active-phrase selection

    @Test("currentTime inside a phrase selects that phrase")
    func selectsContainingPhrase() {
        let model = twoPhraseModel()
        #expect(model.resolve(currentTime: 2.0, visibleWidth: 320).activePhraseIndex == 0)
        #expect(model.resolve(currentTime: 10.7, visibleWidth: 320).activePhraseIndex == 1)
    }

    @Test("Silence gap holds the previous phrase until the next one starts")
    func gapHoldsPreviousPhrase() {
        let model = twoPhraseModel()
        // 6.0 s sits in the 3.5–10.0 s rest: phrase 0 is held, not phrase 1.
        #expect(model.resolve(currentTime: 6.0, visibleWidth: 320).activePhraseIndex == 0)
        // Held right up to the instant the next phrase begins.
        #expect(model.resolve(currentTime: 9.999, visibleWidth: 320).activePhraseIndex == 0)
        #expect(model.resolve(currentTime: 10.0, visibleWidth: 320).activePhraseIndex == 1)
    }

    @Test("Before the first phrase the viewport holds phrase 0")
    func beforeFirstPhraseHoldsPhraseZero() {
        let viewport = twoPhraseModel().resolve(currentTime: 0.0, visibleWidth: 320)
        #expect(viewport.activePhraseIndex == 0)
    }

    // MARK: Visible window

    @Test("Visible window is the phrase plus pre/post-roll padding")
    func visibleWindowFramesActivePhrase() {
        let viewport = twoPhraseModel().resolve(currentTime: 2.0, visibleWidth: phrase0Width)
        #expect(abs(viewport.visibleTimeRange.lowerBound - 0.4) < 1e-6)
        #expect(abs(viewport.visibleTimeRange.upperBound - 4.1) < 1e-6)
    }

    @Test("A short phrase is widened to the minimum visible duration")
    func shortPhraseHonoursMinimumWindow() {
        // One 0.2 s stroke ⇒ padded span 1.4 s, below the 2.5 s floor.
        let model = NotationViewportModel(strokes: [StrokeSpan(startTime: 5.0, endTime: 5.2)])
        let viewport = model.resolve(currentTime: 5.1, visibleWidth: 250)
        let span = viewport.visibleTimeRange.upperBound - viewport.visibleTimeRange.lowerBound
        #expect(abs(span - 2.5) < 1e-6)
    }

    // MARK: Playhead position

    @Test("Playhead x maps currentTime through phrase start, middle, and end")
    func playheadXAcrossPhrase() {
        let model = twoPhraseModel()
        // Window 0.4–4.1 s over 370 pt ⇒ 100 pt/s. Phrase 0 spans 1.0–3.5 s.
        let atStart = model.resolve(currentTime: 1.0, visibleWidth: phrase0Width)
        let atMiddle = model.resolve(currentTime: 2.25, visibleWidth: phrase0Width)
        let atEnd = model.resolve(currentTime: 3.5, visibleWidth: phrase0Width)
        #expect(abs(atStart.playheadX - 60) < 0.05)    // (1.0 − 0.4) × 100
        #expect(abs(atMiddle.playheadX - 185) < 0.05)  // (2.25 − 0.4) × 100
        #expect(abs(atEnd.playheadX - 310) < 0.05)     // (3.5 − 0.4) × 100
        #expect(atStart.playheadX < atMiddle.playheadX)
        #expect(atMiddle.playheadX < atEnd.playheadX)
    }

    @Test("Playhead clamps to the phrase start before the phrase begins")
    func playheadClampsBeforePhrase() {
        // currentTime 0.0 is before phrase 0's first stroke (1.0 s).
        let viewport = twoPhraseModel().resolve(currentTime: 0.0, visibleWidth: phrase0Width)
        #expect(abs(viewport.clampedPlayheadTime - 1.0) < 1e-6)
        #expect(abs(viewport.playheadX - 60) < 0.05)   // parked at the phrase start
        #expect(viewport.playheadX >= 0)
    }

    @Test("Playhead clamps to the phrase end during the trailing gap")
    func playheadClampsAfterPhrase() {
        // currentTime 6.0 is in the rest after phrase 0 (ends 3.5 s).
        let viewport = twoPhraseModel().resolve(currentTime: 6.0, visibleWidth: phrase0Width)
        #expect(viewport.activePhraseIndex == 0)
        #expect(abs(viewport.clampedPlayheadTime - 3.5) < 1e-6)
        #expect(abs(viewport.playheadX - 310) < 0.05)  // parked on the last stroke
        #expect(viewport.playheadX <= phrase0Width)
    }

    // MARK: Stroke positions

    @Test("Visible strokes are the active phrase's strokes, positioned in points")
    func visibleStrokesPositioned() {
        let viewport = twoPhraseModel().resolve(currentTime: 2.0, visibleWidth: phrase0Width)
        #expect(viewport.visibleStrokes.count == 3)
        #expect(viewport.visibleStrokes.map(\.strokeIndex) == [0, 1, 2])
        // Stroke 0 spans 1.0–1.5 s ⇒ (1.0 − 0.4)×100 … (1.5 − 0.4)×100.
        #expect(abs(viewport.visibleStrokes[0].startX - 60) < 0.05)
        #expect(abs(viewport.visibleStrokes[0].endX - 110) < 0.05)
        // Every visible stroke stays within the viewport bounds.
        for stroke in viewport.visibleStrokes {
            #expect(stroke.startX >= 0)
            #expect(stroke.endX <= phrase0Width + 0.05)
        }
    }

    // MARK: Degenerate inputs

    @Test("Zero width produces no division-by-zero and a zero-scale viewport")
    func zeroWidthIsSafe() {
        let viewport = twoPhraseModel().resolve(currentTime: 2.0, visibleWidth: 0)
        #expect(viewport.pointsPerSecond == 0)
        #expect(viewport.playheadX == 0)
        #expect(viewport.playheadX.isFinite)
        for stroke in viewport.visibleStrokes {
            #expect(stroke.startX == 0)
            #expect(stroke.endX == 0)
        }
    }

    @Test("A tiny width still yields finite geometry")
    func tinyWidthIsSafe() {
        let viewport = twoPhraseModel().resolve(currentTime: 2.0, visibleWidth: 0.001)
        #expect(viewport.pointsPerSecond.isFinite)
        #expect(viewport.playheadX.isFinite)
        #expect(viewport.playheadX >= 0)
        #expect(viewport.playheadX <= 0.001)
    }

    @Test("An empty notation resolves to a safe, empty viewport")
    func emptyNotationIsSafe() {
        let viewport = NotationViewportModel(strokes: [])
            .resolve(currentTime: 5.0, visibleWidth: 300)
        #expect(viewport.activePhraseIndex == 0)
        #expect(viewport.visibleStrokes.isEmpty)
        #expect(viewport.playheadX == 0)
        #expect(viewport.pointsPerSecond.isFinite)
    }
}
