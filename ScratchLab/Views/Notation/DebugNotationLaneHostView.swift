#if DEBUG
import SwiftUI

// MARK: - DebugNotationLaneHostView

/// A DEBUG-only host surface that wraps `NotationLaneGeometryView`
/// with synthetic in-memory geometry for manual inspection.
///
/// **Purpose:** allow a developer to open the notation lane renderer
/// inside the running app and switch between empty, simple, dense,
/// and frame-stepped replay geometry presets without touching
/// production Practice/Review flows.
///
/// **No production impact:** the entire file is gated behind `#if DEBUG`
/// and the navigation entry point is gated the same way inside
/// `AdvancedHubView`.
struct DebugNotationLaneHostView: View {

    enum Preset: String, CaseIterable {
        case empty
        case simple
        case dense
        case replay
    }

    /// Source of the `NotationPresentationModel` fed to
    /// `NotationReplayDriver` while the host is in the `.replay`
    /// preset. DEBUG-only — never written to disk, never wired into
    /// Practice / Review / Capture / Coach.
    ///
    /// - `handBuilt`: the original hand-built
    ///   `replayPresentation` constant. Unchanged from earlier
    ///   slices; this is the default so existing manual workflows
    ///   look identical.
    /// - `scratchNotation`: `replayPresentation` rebuilt from
    ///   `scratchNotationFixture` via
    ///   `ScratchNotationPresentationAdapter`. Exercises the
    ///   adapter end-to-end against the geometry mappers.
    /// - `sessionReplay`: `replayPresentation` rebuilt from
    ///   `sessionReplayFixture` via
    ///   `SessionReplayPresentationAdapter`. Exercises the second
    ///   adapter against the same downstream stack.
    enum ReplaySource: String, CaseIterable {
        case handBuilt
        case scratchNotation
        case sessionReplay

        var displayName: String {
            switch self {
            case .handBuilt:       return "Hand-built"
            case .scratchNotation: return "Notation"
            case .sessionReplay:   return "Session"
            }
        }
    }

    @State private var preset: Preset = .simple
    @State private var replaySource: ReplaySource = .handBuilt
    @State private var frameIndex: Int = 0
    @State private var phraseOverlayEnabled: Bool = DebugNotationLaneHostView.phraseOverlayDefaultEnabled

    private static let laneWidth: Double = 400
    private static let laneHeight: Double = 200
    private static let phraseOverlayHeight: Double = 28

    /// Default state of the phrase overlay toggle. Opt-in — production
    /// flows never see this surface, and even the DEBUG host renders it
    /// only when the user explicitly switches it on. Exposed `static`
    /// so the DEBUG-only test target can lock the default.
    static let phraseOverlayDefaultEnabled: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Preset", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if preset == .replay {
                replaySourcePicker
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                replayStepper
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            phraseOverlayToggle
                .padding(.horizontal)
                .padding(.bottom, 6)

            NotationLaneGeometryView(
                geometry: geometry,
                gridlines: gridlines,
                playhead: playhead
            )
            .frame(height: Self.laneHeight)
            .padding(.horizontal)

            if phraseOverlayEnabled {
                phraseOverlayStrip
                    .frame(height: Self.phraseOverlayHeight)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .background(Color.black)
        .navigationTitle("Notation Lane")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: Replay source picker

    private var replaySourcePicker: some View {
        Picker("Replay source", selection: $replaySource) {
            ForEach(ReplaySource.allCases, id: \.self) { source in
                Text(source.displayName)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Replay stepper

    private var replayStepper: some View {
        let lastIndex = max(0, Self.replayState.frames.count - 1)
        let safeIndex = min(max(frameIndex, 0), lastIndex)
        let frameTime = Self.replayState.frames[safeIndex].time
        return HStack {
            Stepper(
                "Frame \(safeIndex) / \(lastIndex)",
                value: $frameIndex,
                in: 0...lastIndex
            )
            .foregroundStyle(.white)
            Spacer()
            Text(String(format: "t = %.2fs", frameTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    // MARK: Phrase overlay (DEBUG diagnostic)

    /// Opt-in toggle controlling whether the phrase-summary strip is
    /// drawn below the existing lane. The toggle ships off; flipping
    /// it on does not change any production rendering path, since the
    /// host view itself is gated behind `#if DEBUG`.
    private var phraseOverlayToggle: some View {
        Toggle("Phrase overlay (debug)", isOn: $phraseOverlayEnabled)
            .toggleStyle(.switch)
            .tint(.orange)
            .foregroundStyle(.white)
            .font(.caption)
    }

    /// Diagnostic strip that paints one translucent band per grouped
    /// phrase across a `[0, phraseTakeDurationSeconds]` horizontal
    /// scale. Pure presentation of the Slice-1/Slice-2 transforms —
    /// no clock, no animation, no Combine, no AVFoundation.
    private var phraseOverlayStrip: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let duration = Self.phraseTakeDurationSeconds
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.06)
                ForEach(Array(Self.phraseSummary.spans.enumerated()), id: \.offset) { entry in
                    let span = entry.element
                    let projection = Self.phraseGridSummary.projections[entry.offset]
                    let xStart = (span.startTime / duration) * width
                    let bandWidth = max(2.0, (span.duration / duration) * width)
                    Rectangle()
                        .fill(Color.orange.opacity(0.30))
                        .frame(width: bandWidth, height: height)
                        .overlay(alignment: .leading) {
                            Text(Self.phraseLabel(index: entry.offset, span: span, projection: projection))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .offset(x: xStart)
                }
            }
        }
    }

    /// Compact per-phrase label. Pure function of the span and its
    /// grid projection so the test target can lock the format.
    static func phraseLabel(
        index: Int,
        span: AudioPhraseSpan,
        projection: AudioPhraseGridProjection
    ) -> String {
        let bars = String(format: "%.2f", projection.durationInBars)
        return "P\(index) \(bars)b d:\(span.possibleDragCount) b:\(span.scratchBurstCount) c:\(span.possibleCutCount)"
    }

    // MARK: Geometry

    private var geometry: NotationLaneGeometryModel {
        switch preset {
        case .empty:  return Self.emptyStrokes
        case .simple: return Self.simpleStrokes
        case .dense:  return Self.denseStrokes
        case .replay: return replayProjection?.laneGeometry ?? Self.emptyStrokes
        }
    }

    private var gridlines: NotationGridlineGeometryModel {
        switch preset {
        case .empty:  return Self.emptyGridlines
        case .simple: return Self.simpleGridlines
        case .dense:  return Self.denseGridlines
        case .replay: return replayProjection?.gridlineGeometry ?? Self.emptyGridlines
        }
    }

    private var playhead: NotationPlayheadGeometry? {
        switch preset {
        case .empty:  return nil
        case .simple: return Self.simplePlayhead
        case .dense:  return Self.densePlayhead
        case .replay: return replayProjection?.playhead
        }
    }

    private var replayProjection: NotationReplayProjection? {
        let lastIndex = max(0, Self.replayState.frames.count - 1)
        let safeIndex = min(max(frameIndex, 0), lastIndex)
        guard !Self.replayState.frames.isEmpty else { return nil }
        let frame = Self.replayState.frames[safeIndex]
        return NotationReplayDriver.project(
            frame: frame,
            state: Self.replayState,
            presentationModel: currentReplayPresentation,
            timingGrid: Self.replayGrid,
            viewportRule: Self.replayRule,
            width: Self.laneWidth,
            height: Self.laneHeight
        )
    }

    /// Resolves the `NotationPresentationModel` for the active
    /// `replaySource`. Hand-built returns the original constant;
    /// the two adapter sources project synthetic fixtures through
    /// `ScratchNotationPresentationAdapter` and
    /// `SessionReplayPresentationAdapter`. DEBUG-only: never read
    /// outside `replayProjection`.
    private var currentReplayPresentation: NotationPresentationModel {
        switch replaySource {
        case .handBuilt:       return Self.replayPresentation
        case .scratchNotation: return Self.scratchNotationReplayPresentation
        case .sessionReplay:   return Self.sessionReplayPresentation
        }
    }

    // MARK: Preset data

    private static let emptyStrokes = NotationLaneGeometryModel(strokes: [])
    private static let emptyGridlines = NotationGridlineGeometryModel(gridlines: [])

    private static let simpleStrokes: NotationLaneGeometryModel = {
        let h = laneHeight
        let strokes: [NotationLaneStrokeGeometry] = [
            NotationLaneStrokeGeometry(
                primitiveIndex: 0, xStart: 20, xEnd: 80,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .baby, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 1, xStart: 100, xEnd: 160,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .chirp, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 2, xStart: 180, xEnd: 180,
                yStart: h * 0.5, yEnd: h * 0.5,
                family: nil, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 3, xStart: 220, xEnd: 300,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .flare, coachingKinds: [.lateReversal]
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 4, xStart: 340, xEnd: 310,
                yStart: h * 0.75, yEnd: h * 0.25,
                family: .tear, coachingKinds: []
            ),
        ]
        return NotationLaneGeometryModel(strokes: strokes)
    }()

    private static let simpleGridlines: NotationGridlineGeometryModel = {
        let lines: [NotationGridlineGeometry] = [
            NotationGridlineGeometry(kind: .bar, time: 0, x: 0),
            NotationGridlineGeometry(kind: .beat, time: 2.5, x: 100),
            NotationGridlineGeometry(kind: .subdivision, time: 3.75, x: 150),
            NotationGridlineGeometry(kind: .bar, time: 5, x: 200),
            NotationGridlineGeometry(kind: .beat, time: 7.5, x: 300),
        ]
        return NotationGridlineGeometryModel(gridlines: lines)
    }()

    private static let simplePlayhead = NotationPlayheadGeometry(
        time: 4, x: 160, yTop: 0, yBottom: laneHeight,
        isWithinViewport: true
    )

    private static let denseStrokes: NotationLaneGeometryModel = {
        let h = laneHeight
        var strokes: [NotationLaneStrokeGeometry] = []
        for i in 0..<30 {
            let xStart = Double(i) * 13 + 5
            let forward = i % 3 != 0
            let xEnd = forward ? xStart + Double(8 + (i % 15)) : xStart
            let yStart: Double
            let yEnd: Double
            if forward {
                yStart = h * 0.25
                yEnd = h * 0.75
            } else if i % 2 == 0 {
                yStart = h * 0.5
                yEnd = h * 0.5
            } else {
                yStart = h * 0.75
                yEnd = h * 0.25
            }
            let family: ScratchFamily? = i % 5 == 0 ? .baby : (i % 7 == 0 ? .chirp : nil)
            let kinds: [CoachingEventKind] = i % 4 == 0 ? [.unstableTiming] : []
            strokes.append(NotationLaneStrokeGeometry(
                primitiveIndex: i,
                xStart: xStart,
                xEnd: xEnd,
                yStart: yStart,
                yEnd: yEnd,
                family: family,
                coachingKinds: kinds
            ))
        }
        return NotationLaneGeometryModel(strokes: strokes)
    }()

    private static let denseGridlines: NotationGridlineGeometryModel = {
        let w = laneWidth
        var lines: [NotationGridlineGeometry] = []
        for i in 0..<40 {
            let time = Double(i) * 0.25
            let x = (time / 10.0) * w
            let kind: NotationGridlineKind
            if i % 16 == 0 {
                kind = .bar
            } else if i % 4 == 0 {
                kind = .beat
            } else {
                kind = .subdivision
            }
            lines.append(NotationGridlineGeometry(kind: kind, time: time, x: x))
        }
        return NotationGridlineGeometryModel(gridlines: lines)
    }()

    private static let densePlayhead = NotationPlayheadGeometry(
        time: 5, x: 200, yTop: 0, yBottom: laneHeight,
        isWithinViewport: true
    )

    // MARK: Replay preset data
    //
    // Internal (not private) so the DEBUG-only test target can verify
    // that the synthetic state is valid and projects deterministically
    // for every frame. Nothing outside the host depends on these.

    static let replayPresentation: NotationPresentationModel = {
        NotationPresentationModel(strokes: [
            NotationPresentationStroke(
                primitiveIndex: 0,
                startTime: 0.50, endTime: 1.00,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 1,
                startTime: 1.25, endTime: 1.25,
                startPosition: nil, endPosition: nil,
                family: nil, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 2,
                startTime: 2.00, endTime: 2.75,
                startPosition: nil, endPosition: nil,
                family: .chirp, coachingKinds: [.lateReversal]
            ),
            NotationPresentationStroke(
                primitiveIndex: 3,
                startTime: 3.50, endTime: 4.00,
                startPosition: nil, endPosition: nil,
                family: .flare, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 4,
                startTime: 5.50, endTime: 5.00,
                startPosition: nil, endPosition: nil,
                family: .tear, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 5,
                startTime: 6.00, endTime: 7.50,
                startPosition: nil, endPosition: nil,
                family: .scribble, coachingKinds: [.unstableTiming]
            ),
        ])
    }()

    static let replayGrid: TimingGrid = {
        // 120 BPM, 4/4, sixteenth-note subdivisions, origin at 0.
        // Force-unwrap is safe — all inputs are constant and valid.
        TimingGrid(
            beatsPerMinute: 120,
            beatsPerBar: 4,
            subdivisionsPerBeat: 4,
            origin: 0
        )!
    }()

    static let replayRule: NotationViewportWindowRule = {
        // 4 s window with 1 s of pre-roll behind the playhead.
        NotationViewportWindowRule(duration: 4, leadIn: 1)!
    }()

    // MARK: Adapter-backed replay fixtures
    //
    // DEBUG-only synthetic sources for `ScratchNotationPresentationAdapter`
    // and `SessionReplayPresentationAdapter`. Constructed in memory,
    // never persisted, never wired into Practice / Review / Capture /
    // Coach. Internal (not private) so the DEBUG-only test target can
    // assert determinism and adapter pass-through.

    static let scratchNotationFixture: ScratchNotation = {
        let strokes: [ScratchNotation.Stroke] = [
            ScratchNotation.Stroke(
                startTime: 0.50, endTime: 1.00,
                direction: .forward,  speedClassification: .medium, faderState: .open
            ),
            ScratchNotation.Stroke(
                startTime: 1.25, endTime: 1.50,
                direction: .backward, speedClassification: .slow,   faderState: .open
            ),
            ScratchNotation.Stroke(
                startTime: 2.00, endTime: 2.75,
                direction: .forward,  speedClassification: .fast,   faderState: .open
            ),
            ScratchNotation.Stroke(
                startTime: 3.50, endTime: 4.00,
                direction: .backward, speedClassification: .medium, faderState: .open
            ),
            ScratchNotation.Stroke(
                startTime: 5.00, endTime: 5.50,
                direction: .forward,  speedClassification: .slow,   faderState: .open
            ),
            ScratchNotation.Stroke(
                startTime: 6.00, endTime: 7.50,
                direction: .backward, speedClassification: .fast,   faderState: .open
            ),
        ]
        return ScratchNotation(
            version: 1,
            scratchID: "debug-host",
            demoStart: 0,
            demoEnd: 8,
            phraseStart: nil,
            phraseEnd: nil,
            timingBasis: "audio",
            strokes: strokes
        )
    }()

    static let scratchNotationReplayPresentation: NotationPresentationModel = {
        ScratchNotationPresentationAdapter.makeModel(from: scratchNotationFixture)
    }()

    static let sessionReplayFixture: SessionReplayTimeline = {
        let events: [SessionReplayEvent] = [
            SessionReplayEvent(
                startTime: 0.50, endTime: 1.00,
                kind: .audioOnset,     sourceIndex: 0, tag: "tap"
            ),
            SessionReplayEvent(
                startTime: 1.25, endTime: nil,
                kind: .mixerMidi,      sourceIndex: 0, tag: "midi_cc_07"
            ),
            SessionReplayEvent(
                startTime: 2.00, endTime: 2.75,
                kind: .recordMovement, sourceIndex: 0, tag: "forward"
            ),
            SessionReplayEvent(
                startTime: 3.50, endTime: 4.00,
                kind: .fader,          sourceIndex: 0, tag: "crossfader"
            ),
            SessionReplayEvent(
                startTime: 5.00, endTime: nil,
                kind: .mixerMidi,      sourceIndex: 1, tag: "midi_cc_11"
            ),
            SessionReplayEvent(
                startTime: 6.00, endTime: 7.50,
                kind: .audioOnset,     sourceIndex: 1, tag: "tap"
            ),
        ]
        return SessionReplayTimeline(
            takeDurationSeconds: 8,
            events: events
        )
    }()

    static let sessionReplayPresentation: NotationPresentationModel = {
        SessionReplayPresentationAdapter.makeModel(from: sessionReplayFixture)
    }()

    // MARK: Phrase overlay fixture
    //
    // DEBUG-only synthetic audio events used by the phrase overlay
    // toggle. Constructed in memory, never persisted, never wired into
    // Practice / Review / Capture / Coach. Internal (not private) so
    // the DEBUG-only test target can lock the grouping output.

    static let phraseTakeDurationSeconds: Double = 8.0

    static let phraseFixtureAudioEvents: [CaptureCore.DetectedNotationAudioEvent] = {
        func ev(
            _ start: Double,
            _ end: Double,
            _ kind: String,
            confidence: Double = 0.75
        ) -> CaptureCore.DetectedNotationAudioEvent {
            CaptureCore.DetectedNotationAudioEvent(
                startTime: start,
                endTime: end,
                duration: end - start,
                peakLevel: -12.0,
                rmsLevel: -18.0,
                confidence: confidence,
                eventKind: kind,
                source: "debug-phrase-fixture"
            )
        }
        return [
            ev(0.50, 0.80, "scratchBurst"),
            ev(0.90, 1.10, "possibleDrag"),
            // implicit > 2 s gap splits the next phrase
            ev(4.00, 4.20, "possibleDrag"),
            ev(4.30, 4.50, "scratchBurst"),
            ev(4.60, 4.80, "possibleCut"),
            // implicit > 2 s gap splits the next phrase
            ev(6.95, 7.95, "possibleDrag", confidence: 0.90),
        ]
    }()

    static let phraseSummary: AudioPhraseSummary = {
        AudioPhraseGrouper.summary(for: phraseFixtureAudioEvents)
    }()

    static let phraseGridSummary: AudioPhraseGridSummary = {
        AudioPhraseGridProjector.project(phraseSummary, onto: replayGrid)
    }()

    static let replayState: NotationReplayState = {
        // 17 frames at 0.5 s steps covering [0, 8] inside an 8 s take.
        // Indices are 0..16, strictly ascending — satisfies the
        // state's `frames` invariant trivially.
        var frames: [NotationReplayFrame] = []
        frames.reserveCapacity(17)
        for i in 0..<17 {
            let time = Double(i) * 0.5
            // Force-unwrap is safe — index ≥ 0 and time is finite.
            frames.append(NotationReplayFrame(index: i, time: time)!)
        }
        return NotationReplayState(
            contentStart: 0,
            contentEnd: 8,
            frames: frames
        )!
    }()
}

#endif
