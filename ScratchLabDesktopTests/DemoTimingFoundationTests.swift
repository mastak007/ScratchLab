import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import ScratchLab

// Unit tests for the call-and-response Demo timing & reel feature:
//
//   • the `PracticeReelTimeline` manifest model + loader + validator, and the
//     derived copy-window ghost strokes;
//   • the `DemoAudioClock` smoothing/latency clock and its player wiring;
//   • source-string regression checks for the unified `TimingLaneView` and
//     its wiring in `PracticeModeView`. The view layer is iOS-only and not
//     importable into this test target, so it is asserted by file content —
//     the same source-string pattern the wider regression suites use.
//
// The model types are pure (no simulator, no view host); the source-string
// suites read files from disk.

// MARK: - Shared helpers

/// Repo root, derived from this test file's path — the same pattern the
/// source-string regression suites use.
private func reelTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// Reads a project source file as text. The reel view layer is iOS-only and
/// not importable into this test target, so it is asserted by file content.
private func reelSource(_ relativePath: String) throws -> String {
    try String(contentsOf: reelTestsRepoRoot().appendingPathComponent(relativePath),
               encoding: .utf8)
}

/// The substring of `source` from the first occurrence of `start` up to the
/// next occurrence of `end` — lets a source-string check target one function
/// or layout block instead of the whole file.
private func sliceBetween(_ source: String, from start: String, to end: String) throws -> String {
    let head = try #require(source.range(of: start), "source marker not found: \(start)")
    let rest = source[head.lowerBound...]
    let tail = try #require(rest.range(of: end), "source marker not found after start: \(end)")
    return String(rest[..<tail.lowerBound])
}

/// A flexible valid-manifest builder; each test overrides only what it probes.
private func makeManifest(
    version: Int = PracticeReelTimeline.supportedVersion,
    audioDuration: TimeInterval = 10.0,
    segments: [ReelSegment] = [
        ReelSegment(kind: .demo, startTime: 0.0, endTime: 4.0, label: "Demo 1"),
        ReelSegment(kind: .copy, startTime: 4.0, endTime: 8.0, label: "Your turn"),
    ],
    strokes: [ReelStroke] = [
        ReelStroke(startTime: 1.0, endTime: 1.5,
                   direction: .backward, speedClassification: .slow, faderState: .open),
        ReelStroke(startTime: 2.0, endTime: 2.4,
                   direction: .forward, speedClassification: .fast, faderState: .closed),
    ]
) -> PracticeReelTimeline {
    PracticeReelTimeline(
        version: version,
        timelineID: "test_reel",
        scratchID: "baby",
        audioFile: "x.wav",
        audioDuration: audioDuration,
        bpm: nil,
        segments: segments,
        strokes: strokes
    )
}

// MARK: - PracticeReelTimeline

@Suite("PracticeReelTimeline")
struct PracticeReelTimelineTests {

    @Test("Decodes a call-and-response manifest from JSON")
    func decodesFromJSON() throws {
        let json = """
        {
          "version": 1,
          "timelineID": "t1",
          "scratchID": "baby",
          "audioFile": "x.wav",
          "audioDuration": 10.0,
          "segments": [
            { "kind": "demo", "startTime": 0, "endTime": 4, "label": "Demo 1" },
            { "kind": "copy", "startTime": 4, "endTime": 8 }
          ],
          "strokes": [
            { "startTime": 1, "endTime": 1.5, "direction": "backward",
              "speedClassification": "slow", "faderState": "open" }
          ]
        }
        """
        let reel = try PracticeReelTimeline.decoded(from: Data(json.utf8))
        #expect(reel.version == 1)
        #expect(reel.audioFile == "x.wav")
        #expect(reel.bpm == nil)                       // omitted optional decodes to nil
        #expect(reel.segments.count == 2)
        #expect(reel.segments[0].kind == .demo)
        #expect(reel.segments[1].kind == .copy)
        #expect(reel.segments[1].label == nil)         // omitted label decodes to nil
        #expect(reel.strokes.count == 1)
        #expect(reel.strokes[0].direction == .backward)
    }

    @Test("Malformed JSON throws rather than producing a partial manifest")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try PracticeReelTimeline.decoded(from: Data("not a manifest".utf8))
        }
    }

    @Test("A missing bundled manifest loads as nil, not a crash")
    func missingBundledManifestIsNil() {
        #expect(PracticeReelTimeline.loadBundled(named: "no_such_reel_manifest") == nil)
    }

    @Test("Partitions segments by kind and assigns strokes by time")
    func partitionsSegmentsAndStrokes() {
        let reel = makeManifest()
        #expect(reel.demoSegments.count == 1)
        #expect(reel.copySegments.count == 1)
        #expect(reel.strokes(in: reel.segments[0]).count == 2)   // both default strokes in demo
        #expect(reel.strokes(in: reel.segments[1]).isEmpty)      // none in the copy window
        #expect(reel.segment(at: 1.0)?.kind == .demo)
        #expect(reel.segment(at: 5.0)?.kind == .copy)
        #expect(reel.segment(at: 9.0) == nil)                    // past the last segment
    }

    @Test("A well-formed manifest validates with no issues")
    func wellFormedManifestIsValid() {
        let reel = makeManifest()
        #expect(reel.validate().isEmpty)
        #expect(reel.isValid)
    }

    @Test("Rejects an unsupported schema version")
    func rejectsUnsupportedVersion() {
        let reel = makeManifest(version: 99)
        #expect(reel.isValid == false)
    }

    @Test("Rejects overlapping segments")
    func rejectsOverlappingSegments() {
        let reel = makeManifest(segments: [
            ReelSegment(kind: .demo, startTime: 0.0, endTime: 5.0, label: "Demo 1"),
            ReelSegment(kind: .copy, startTime: 4.0, endTime: 8.0, label: "Your turn"),
        ])
        #expect(reel.isValid == false)
    }

    @Test("Rejects a segment that runs past the audio duration")
    func rejectsSegmentPastAudioDuration() {
        let reel = makeManifest(
            audioDuration: 10.0,
            segments: [ReelSegment(kind: .demo, startTime: 0.0, endTime: 12.0, label: "Demo 1")]
        )
        #expect(reel.isValid == false)
    }

    @Test("Rejects out-of-order and zero-length strokes")
    func rejectsBadStrokes() {
        let outOfOrder = makeManifest(strokes: [
            ReelStroke(startTime: 2.0, endTime: 2.4,
                       direction: .forward, speedClassification: .fast, faderState: .open),
            ReelStroke(startTime: 1.0, endTime: 1.5,
                       direction: .backward, speedClassification: .slow, faderState: .open),
        ])
        #expect(outOfOrder.isValid == false)

        let zeroLength = makeManifest(strokes: [
            ReelStroke(startTime: 1.0, endTime: 1.0,
                       direction: .forward, speedClassification: .fast, faderState: .open),
        ])
        #expect(zeroLength.isValid == false)
    }

    @Test("Warns on authoring smells but still loads")
    func warnsButStillValid() {
        // A reel that opens with a copy window and has no demo-then-copy pairing.
        let copyFirst = makeManifest(segments: [
            ReelSegment(kind: .copy, startTime: 0.0, endTime: 4.0, label: "Your turn"),
            ReelSegment(kind: .demo, startTime: 4.0, endTime: 8.0, label: "Demo 1"),
        ])
        #expect(copyFirst.isValid)
        #expect(copyFirst.validate().contains { $0.severity == .warning })

        // A reel with no copy windows at all.
        let noCopy = makeManifest(segments: [
            ReelSegment(kind: .demo, startTime: 0.0, endTime: 8.0, label: "Demo 1"),
        ])
        #expect(noCopy.isValid)
        #expect(noCopy.validate().contains { $0.severity == .warning })
    }

    @Test("Cross-checks the declared duration against a measured one")
    func audioDurationCrossCheck() {
        let reel = makeManifest(audioDuration: 10.0)
        #expect(reel.audioDurationIssue(actualDuration: 10.0) == nil)
        #expect(reel.audioDurationIssue(actualDuration: 10.02) == nil)   // within tolerance
        #expect(reel.audioDurationIssue(actualDuration: 11.0) != nil)    // beyond tolerance
    }

    @Test("The bundled Baby Scratch reel manifest is valid and matches its audio")
    func bundledBabyReelIsValid() throws {
        let root = reelTestsRepoRoot()
        let manifestURL = root.appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_reel.json")
        let reel = try PracticeReelTimeline.decoded(from: Data(contentsOf: manifestURL))

        #expect(reel.isValid, "baby_reel.json must validate clean: \(reel.validationErrors)")
        #expect(reel.scratchID == "baby")
        #expect(reel.audioFile == "baby_noBeat.wav")
        #expect(reel.segments.count == 7)
        #expect(reel.demoSegments.count == 4)
        #expect(reel.copySegments.count == 3)
        #expect(reel.strokes.count == 40)
        #expect(reel.segments.first?.kind == .demo)

        // The declared audioDuration must match the real bundled audio file.
        let audioURL = root.appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
        let audioFile = try AVAudioFile(forReading: audioURL)
        let measured = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        #expect(reel.audioDurationIssue(actualDuration: measured) == nil,
                "manifest audioDuration \(reel.audioDuration)s vs measured \(measured)s")
    }
}

// MARK: - DemoAudioClock

@Suite("DemoAudioClock")
struct DemoAudioClockTests {

    @Test("Reports zero before it has received any sample")
    func zeroBeforeAnySample() {
        let clock = DemoAudioClock()
        #expect(clock.hasSample == false)
        #expect(clock.currentTime(hostTime: 123.0) == 0)
    }

    @Test("Interpolates forward against the host clock while advancing")
    func interpolatesWhileAdvancing() {
        var clock = DemoAudioClock()
        clock.ingest(playerTime: 1.0, isPlaying: true, hostTime: 100.0)
        #expect(abs(clock.currentTime(hostTime: 100.5) - 1.5) < 1e-6)
        #expect(abs(clock.currentTime(hostTime: 101.0) - 2.0) < 1e-6)
    }

    @Test("A repeated raw value (a buffer plateau) does not freeze the clock")
    func bufferPlateauStaysSmooth() {
        var clock = DemoAudioClock()
        clock.ingest(playerTime: 1.0, isPlaying: true, hostTime: 100.0)
        clock.ingest(playerTime: 1.0, isPlaying: true, hostTime: 100.25)   // same raw value
        clock.ingest(playerTime: 1.0, isPlaying: true, hostTime: 100.50)   // same raw value
        // Still interpolating from the first anchor — not stuck at 1.0.
        #expect(abs(clock.currentTime(hostTime: 100.5) - 1.5) < 1e-6)
    }

    @Test("Subtracts output latency so the playhead matches what is heard")
    func compensatesOutputLatency() {
        var clock = DemoAudioClock(outputLatency: 0.030)
        clock.ingest(playerTime: 2.0, isPlaying: true, hostTime: 50.0)
        #expect(abs(clock.currentTime(hostTime: 50.0) - 1.970) < 1e-6)
    }

    @Test("Never reports a negative time")
    func neverNegative() {
        var clock = DemoAudioClock(outputLatency: 1.0)
        clock.ingest(playerTime: 0.1, isPlaying: true, hostTime: 10.0)
        #expect(clock.currentTime(hostTime: 10.0) == 0)
    }

    @Test("In-threshold jitter does not snap the anchor")
    func smallJitterStaysSmooth() {
        var clock = DemoAudioClock(resyncThreshold: 0.12)
        clock.ingest(playerTime: 1.0, isPlaying: true, hostTime: 100.0)
        // A fresh raw value 40 ms behind the estimate (1.5) — within threshold.
        clock.ingest(playerTime: 1.46, isPlaying: true, hostTime: 100.5)
        // Anchor unchanged, so interpolation continues from (100.0, 1.0).
        #expect(abs(clock.currentTime(hostTime: 101.0) - 2.0) < 1e-6)
    }

    @Test("A large jump re-anchors (a seek, replay, or loop wrap)")
    func largeJumpResyncs() {
        var clock = DemoAudioClock(resyncThreshold: 0.12)
        clock.ingest(playerTime: 40.0, isPlaying: true, hostTime: 100.0)
        // Replay: the raw player time drops back near zero while still playing.
        clock.ingest(playerTime: 0.0, isPlaying: true, hostTime: 100.5)
        #expect(abs(clock.currentTime(hostTime: 100.5) - 0.0) < 1e-6)
        #expect(abs(clock.currentTime(hostTime: 101.0) - 0.5) < 1e-6)
    }

    @Test("Holds the anchor while paused")
    func holdsWhilePaused() {
        var clock = DemoAudioClock()
        clock.ingest(playerTime: 3.0, isPlaying: true, hostTime: 100.0)
        clock.ingest(playerTime: 3.2, isPlaying: false, hostTime: 100.2)   // pause
        // Host time keeps moving, but a paused clock does not.
        #expect(abs(clock.currentTime(hostTime: 105.0) - 3.2) < 1e-6)
    }

    @Test("reset() clears all state")
    func resetClearsState() {
        var clock = DemoAudioClock()
        clock.ingest(playerTime: 5.0, isPlaying: true, hostTime: 100.0)
        clock.reset()
        #expect(clock.hasSample == false)
        #expect(clock.currentTime(hostTime: 100.0) == 0)
    }
}

// MARK: - Demo-audio clock wiring

/// Minimal `ScratchCoachDemoPlayable` stub: a directly controllable position
/// and play state, with no real `AVAudioPlayer`.
private final class StubDemoPlayable: ScratchCoachDemoPlayable {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    func prepareToPlay() {}
    @discardableResult func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
}

@Suite("Demo-audio clock wiring")
struct DemoAudioClockWiringTests {

    @MainActor
    @Test("sampledPlaybackTime() interpolates between coarse player samples")
    func sampledPlaybackTimeIsSmoothed() {
        let stub = StubDemoPlayable()
        var hostTime: TimeInterval = 100.0
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in URL(fileURLWithPath: "/tmp/demo.m4a") },
            playerFactory: { _ in stub },
            hostTimeProvider: { hostTime }
        )
        player.configure(withAudioFileNamed: "demo.m4a")
        stub.currentTime = 1.0
        player.play()

        let first = player.sampledPlaybackTime()    // anchors at (host 100.0, player 1.0)
        hostTime = 100.5                             // half a second of host time later …
        let second = player.sampledPlaybackTime()    // … with the raw player time still frozen

        // The playhead must keep advancing between coarse raw samples. The
        // delta is output-latency independent (it cancels), so this holds on
        // every host platform.
        #expect(abs((second - first) - 0.5) < 0.01)
    }
}

// MARK: - Copy-window ghost strokes

@Suite("Copy-window ghost strokes")
struct CopyGhostStrokeTests {

    @Test("Echoes the preceding demo's strokes into a copy window, time-shifted")
    func echoesPrecedingDemo() {
        // makeManifest: demo 0–4 (strokes at 1.0 and 2.0), copy 4–8 (none).
        let reel = makeManifest()
        let ghosts = reel.derivedCopyGhostStrokes()
        #expect(ghosts.count == 2)
        // Copy window starts at 4.0, demo at 0.0 — every stroke shifts +4.0.
        #expect(abs(ghosts[0].startTime - 5.0) < 1e-6)
        #expect(abs(ghosts[1].startTime - 6.0) < 1e-6)
        // Direction is carried across unchanged.
        #expect(ghosts[0].direction == .backward)
        #expect(ghosts[1].direction == .forward)
    }

    @Test("Every ghost lands inside a copy window, never a demo segment")
    func ghostsLandInCopyWindows() {
        let reel = makeManifest()
        for ghost in reel.derivedCopyGhostStrokes() {
            #expect(reel.segment(at: ghost.startTime)?.kind == .copy)
        }
    }

    @Test("A copy window with no preceding demo yields no ghosts")
    func noPrecedingDemoYieldsNoGhosts() {
        let reel = makeManifest(segments: [
            ReelSegment(kind: .copy, startTime: 0.0, endTime: 4.0, label: "Your turn"),
            ReelSegment(kind: .demo, startTime: 4.0, endTime: 8.0, label: "Demo 1"),
        ])
        #expect(reel.derivedCopyGhostStrokes().isEmpty)
    }

    @Test("Ghosts that overrun a short copy window are clipped out")
    func ghostsClippedToCopyWindow() {
        // Demo 0–5 carries two strokes; the copy window 5–8 is shorter than it.
        let reel = makeManifest(
            audioDuration: 10.0,
            segments: [
                ReelSegment(kind: .demo, startTime: 0.0, endTime: 5.0, label: "Demo 1"),
                ReelSegment(kind: .copy, startTime: 5.0, endTime: 8.0, label: "Your turn"),
            ],
            strokes: [
                ReelStroke(startTime: 1.0, endTime: 1.5,
                           direction: .backward, speedClassification: .slow, faderState: .open),
                ReelStroke(startTime: 4.5, endTime: 4.9,
                           direction: .forward, speedClassification: .fast, faderState: .open),
            ])
        // Shift +5: the first ghost 6.0–6.5 fits [5,8]; the second 9.5–9.9 does not.
        let ghosts = reel.derivedCopyGhostStrokes()
        #expect(ghosts.count == 1)
        #expect(abs(ghosts[0].startTime - 6.0) < 1e-6)
    }

    @Test("The bundled Baby reel derives ghosts for all three copy windows")
    func bundledBabyReelGhosts() throws {
        let manifestURL = reelTestsRepoRoot().appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_reel.json")
        let reel = try PracticeReelTimeline.decoded(from: Data(contentsOf: manifestURL))
        let ghosts = reel.derivedCopyGhostStrokes()
        // Each of the 3 copy windows answers a 10-stroke demo segment.
        #expect(ghosts.count == 30)
        #expect(ghosts.allSatisfy { reel.segment(at: $0.startTime)?.kind == .copy })
        #expect(ghosts.allSatisfy { $0.endTime <= reel.audioDuration })
    }
}

// MARK: - TimingLaneView (source-string regression)

@Suite("Timing-lane view source")
struct TimingLaneViewSourceTests {

    private func laneViewSource() throws -> String {
        try reelSource("ScratchLab/Views/TimingLaneView.swift")
    }

    @Test("The unified timing-lane view exists as a SwiftUI View")
    func viewExists() throws {
        let source = try laneViewSource()
        #expect(source.contains("struct TimingLaneView: View"))
    }

    @Test("The lane is axis-parametric and driven by content plus a clock")
    func axisParametricAndClockDriven() throws {
        let source = try laneViewSource()
        #expect(source.contains("let content: LaneContent"))
        #expect(source.contains("let clock: LaneClock"))
        #expect(source.contains("let axis: LaneAxis"))
        // Geometry flows clock -> LaneViewport -> positions; no scroll view,
        // so lane position can never feed back into timing.
        #expect(source.contains("LaneViewport"))
        #expect(!source.contains("ScrollView"))
    }

    @Test("The lane renders bands, beat grid, strokes and the action line")
    func rendersLaneContent() throws {
        let source = try laneViewSource()
        #expect(source.contains("drawRegionBands"))
        #expect(source.contains("drawBeatGrid"))
        #expect(source.contains("drawStrokes"))
        #expect(source.contains("drawActionLine"))
    }

    @Test("A looping pattern wraps; a finished demo parks")
    func loopWrapAndCompletion() throws {
        let source = try laneViewSource()
        #expect(source.contains("visibleInstances"))
        #expect(source.contains("content.loops"))
        #expect(source.contains("Demo complete"))
    }

    @Test("The lane runs no scoring, capture or live-mic work")
    func noScoringOrCapture() throws {
        let source = try laneViewSource()
        #expect(!source.contains("audioEngine"))
        #expect(!source.contains("startAnalyzing"))
        #expect(!source.contains("ScratchAnalysisResult"))
        #expect(!source.contains("currentScore"))
    }
}

// MARK: - Unified lane wiring (source-string regression)

@Suite("Timing-lane wiring")
struct LaneWiringTests {

    private func practiceSource() throws -> String {
        try reelSource("ScratchLab/Views/PracticeModeView.swift")
    }

    @Test("One lane renderer, its axis chosen by orientation")
    func bothOrientationsUseOneLane() throws {
        let source = try practiceSource()
        // A single notationLanePanel call; the axis is derived from orientation.
        #expect(source.contains("notationLanePanel(axis: axis)"))
        #expect(source.contains("verticalSizeClass == .compact ? .horizontal : .vertical"))
        #expect(source.contains("TimingLaneView(content:"))
    }

    @Test("The layout is notation-first — the lane dominates, the cards are gone")
    func notationFirstLayout() throws {
        let source = try practiceSource()
        // The lane fills the feedback area, framed only by thin HUD chip rows.
        #expect(source.contains("practiceTopHUD"))
        #expect(source.contains("practiceBottomHUD"))
        // The giant diagnostic cards and the landscape side column are gone.
        #expect(!source.contains("audioStatusCard"))
        #expect(!source.contains("comboProgressCard"))
        #expect(!source.contains("guidedDrillCueCard"))
        #expect(!source.contains("portraitFeedbackLayout"))
        #expect(!source.contains("landscapeFeedbackLayout"))
        #expect(!source.contains(".frame(width: 256)"))
    }

    @Test("The two old renderers are retired — one engine, not two")
    func oldRenderersRetired() throws {
        let source = try practiceSource()
        #expect(!source.contains("AutoCutTargetChart"))
        #expect(!source.contains("VerticalNotationReelView"))
        #expect(!source.contains("NotationPlayheadClock"))
    }

    @Test("Demo follows the demo-audio clock; scored modes loop or park")
    func clockPerMode() throws {
        let source = try practiceSource()
        let lane = try sliceBetween(source,
            from: "private var activeLane",
            to: "private func notationLanePanel")
        #expect(lane.contains("LaneContent(reel: reel)"))
        #expect(lane.contains("LaneContent(notation: notation)"))
        #expect(lane.contains(".audioTime { demoPlayer.sampledPlaybackTime() }"))
        #expect(lane.contains(".looping(start: notationClockStartDate"))
        #expect(lane.contains(".fixed(0)"))
    }

    @Test("Demo mode starts no scoring or live-mic analysis")
    func demoStartsNoAnalysis() throws {
        let source = try practiceSource()
        let startBody = try sliceBetween(source,
            from: "private func startSession()",
            to: "private func configureDemoPlayback")
        #expect(startBody.contains("configureDemoPlayback()"))
        #expect(startBody.contains("audioEngine.startAnalyzing(for: activeScratch)"))
        let demoBranch = try sliceBetween(startBody,
            from: "if practiceAssistMode == .demo {", to: "} else {")
        #expect(demoBranch.contains("demoPlayer.play()"))
        #expect(!demoBranch.contains("startAnalyzing"))
    }

    @Test("A missing or invalid reel manifest falls back gracefully")
    func fallbackPathExists() throws {
        let source = try practiceSource()
        #expect(source.contains("demoReel = demoPlayer.isAudioAvailable ? reel : nil"))
        #expect(source.contains("demoPlayer.configure(with: coachInstruction)"))
        // The demo fallback still drives a lane — from the demo audio.
        #expect(source.contains("// Reel manifest missing/invalid"))
    }

    @Test("Guided keeps its crossfader cue layer")
    func guidedKeepsCueLayer() throws {
        let source = try practiceSource()
        #expect(source.contains("GuidedCutCueLayer(notation: notation"))
    }

    @Test("Coach cards remain absent from practice setup")
    func coachCardsAbsent() throws {
        let source = try practiceSource()
        // The ScratchCoachCard view is kept defined but never instantiated.
        #expect(!source.contains("ScratchCoachCard("))
    }
}

// MARK: - User-attempt overlay scaffold

@Suite("User-attempt overlay scaffold")
struct UserAttemptScaffoldTests {

    @Test("LaneUserEvent exists as an inert scaffold type")
    func scaffoldTypeExists() throws {
        let source = try reelSource("ScratchLab/Models/TimingLane.swift")
        #expect(source.contains("struct LaneUserEvent"))
        // Clearly flagged as a non-functional scaffold.
        #expect(source.contains("SCAFFOLD"))
    }

    @Test("The lane takes userEvents defaulting to empty — the overlay is inert")
    func userEventsDefaultsEmpty() throws {
        let source = try reelSource("ScratchLab/Views/TimingLaneView.swift")
        #expect(source.contains("userEvents: [LaneUserEvent] = []"))
        // The renderer has a path for the overlay but draws nothing when empty.
        #expect(source.contains("drawUserEvents"))
    }

    @Test("The lane wiring passes no user events and adds no scoring or capture")
    func wiringStaysNonFunctional() throws {
        let practice = try reelSource("ScratchLab/Views/PracticeModeView.swift")
        let panel = try sliceBetween(practice,
            from: "private func notationLanePanel(",
            to: "// Runtime status for the notation surface")
        // The lane panel constructs TimingLaneView without a userEvents argument.
        #expect(!panel.contains("userEvents"))
        // The lane view itself still carries no scoring / capture / ML symbols.
        let lane = try reelSource("ScratchLab/Views/TimingLaneView.swift")
        #expect(!lane.contains("startAnalyzing"))
        #expect(!lane.contains("ScratchAnalysisResult"))
        #expect(!lane.contains("AudioEngine"))
    }
}

// MARK: - LaneContent adapters

@Suite("LaneContent adapters")
struct LaneContentTests {

    @Test("A Demo reel adapts to non-looping content with demo/copy bands")
    func reelAdapter() throws {
        let manifestURL = reelTestsRepoRoot().appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_reel.json")
        let reel = try PracticeReelTimeline.decoded(from: Data(contentsOf: manifestURL))
        let content = LaneContent(reel: reel)

        #expect(content.loops == false)                       // Demo plays once through
        #expect(content.segments.count == reel.segments.count)
        #expect(content.beatsPerMinute == reel.bpm)
        #expect(abs(content.duration - reel.audioDuration) < 1e-6)
        // Solid reference strokes plus the derived copy-window ghosts.
        #expect(content.strokes.filter { !$0.isGhost }.count == reel.strokes.count)
        #expect(content.strokes.contains { $0.isGhost })
    }

    @Test("A scored notation adapts to looping content with no segments")
    func notationAdapter() {
        let notation = ScratchNotation(
            version: 1, scratchID: "test", demoStart: 0, demoEnd: 2.0,
            phraseStart: nil, phraseEnd: nil, timingBasis: "beat",
            strokes: [
                ScratchNotation.Stroke(startTime: 0.1, endTime: 0.4,
                    direction: .backward, speedClassification: .slow, faderState: .open),
                ScratchNotation.Stroke(startTime: 0.5, endTime: 0.8,
                    direction: .forward, speedClassification: .fast, faderState: .open),
            ])
        let content = LaneContent(notation: notation)

        #expect(content.loops == true)                        // scored modes loop
        #expect(content.segments.isEmpty)                     // no demo/copy bands
        #expect(content.strokes.count == 2)
        #expect(content.strokes.allSatisfy { !$0.isGhost })
        #expect(abs(content.duration - 2.0) < 1e-6)
    }
}

// MARK: - LaneViewport geometry

@Suite("LaneViewport geometry")
struct LaneViewportTests {

    @Test("Vertical: now sits on the action line; the future is above it")
    func verticalMapping() {
        let viewport = LaneViewport(
            size: CGSize(width: 100, height: 200), now: 10,
            axis: .vertical, actionLineFraction: 0.7, secondsAhead: 5)
        #expect(viewport.scrollLength == 200)
        #expect(viewport.crossLength == 100)
        #expect(abs(viewport.actionLinePos - 140) < 1e-6)
        #expect(abs(viewport.pos(for: 10) - 140) < 1e-6)      // now → action line
        #expect(viewport.pos(for: 11) < viewport.actionLinePos)   // future above
        #expect(viewport.pos(for: 9) > viewport.actionLinePos)    // past below
    }

    @Test("Horizontal: the future is to the right of the action line")
    func horizontalMapping() {
        let viewport = LaneViewport(
            size: CGSize(width: 200, height: 100), now: 10,
            axis: .horizontal, actionLineFraction: 0.3, secondsAhead: 5)
        #expect(viewport.scrollLength == 200)
        #expect(viewport.crossLength == 100)
        #expect(abs(viewport.pos(for: 10) - 60) < 1e-6)       // now → action line
        #expect(viewport.pos(for: 11) > viewport.actionLinePos)   // future to the right
        #expect(viewport.pos(for: 9) < viewport.actionLinePos)    // past to the left
    }

    @Test("rect and point map scroll/cross coordinates onto the active axis")
    func axisCoordinateMapping() {
        let vertical = LaneViewport(
            size: CGSize(width: 100, height: 200), now: 0,
            axis: .vertical, actionLineFraction: 0.7, secondsAhead: 5)
        #expect(vertical.rect(scroll0: 50, scroll1: 100, cross0: 10, cross1: 90)
                == CGRect(x: 10, y: 50, width: 80, height: 50))
        #expect(vertical.point(scroll: 30, cross: 40) == CGPoint(x: 40, y: 30))

        let horizontal = LaneViewport(
            size: CGSize(width: 200, height: 100), now: 0,
            axis: .horizontal, actionLineFraction: 0.3, secondsAhead: 5)
        #expect(horizontal.rect(scroll0: 50, scroll1: 100, cross0: 10, cross1: 90)
                == CGRect(x: 50, y: 10, width: 50, height: 80))
        #expect(horizontal.point(scroll: 30, cross: 40) == CGPoint(x: 30, y: 40))
    }

    @Test("time(atPos:) inverts pos(for:)")
    func inverseMapping() {
        let viewport = LaneViewport(
            size: CGSize(width: 120, height: 240), now: 7,
            axis: .vertical, actionLineFraction: 0.7, secondsAhead: 6)
        for time in stride(from: 0.0, through: 14.0, by: 2.0) {
            #expect(abs(viewport.time(atPos: viewport.pos(for: time)) - time) < 1e-6)
        }
    }
}
