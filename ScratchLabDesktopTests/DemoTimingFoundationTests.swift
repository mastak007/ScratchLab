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
//   • source-string regression checks for `ScratchMotionLane` and its wiring
//     in `PracticeModeView`. The view layer is iOS-only and not
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

// MARK: - ScratchMotionLane (source-string regression)

@Suite("Scratch motion lane source")
struct ScratchMotionLaneSourceTests {

    private func laneSource() throws -> String {
        try reelSource("ScratchLab/Views/ScratchMotionLane.swift")
    }

    @Test("The motion lane exists as a SwiftUI View")
    func viewExists() throws {
        let source = try laneSource()
        #expect(source.contains("struct ScratchMotionLane: View"))
    }

    @Test("The lane is axis-parametric and driven by content plus a clock")
    func axisParametricAndClockDriven() throws {
        let source = try laneSource()
        #expect(source.contains("let content: LaneContent"))
        #expect(source.contains("let clock: LaneClock"))
        #expect(source.contains("let axis: LaneAxis"))
        // Geometry flows clock -> LaneViewport -> positions; no scroll view,
        // so lane position can never feed back into timing.
        #expect(source.contains("LaneViewport"))
        #expect(!source.contains("ScrollView"))
    }

    @Test("Strokes render as a continuous motion curve, not block arrows")
    func rendersMotionCurve() throws {
        let source = try laneSource()
        #expect(source.contains("drawRegionBands"))
        #expect(source.contains("drawBeatGrid"))
        #expect(source.contains("drawActionLine"))
        // The motion-graph renderer replaces the old bar / chevron drawing.
        #expect(source.contains("drawMotionPath"))
        #expect(source.contains("ScratchMotionRenderer"))
        #expect(source.contains("ScratchStrokeGeometry.motionPath"))
        #expect(!source.contains("drawChevron"))
    }

    @Test("A looping pattern wraps; a finished demo parks")
    func loopWrapAndCompletion() throws {
        let source = try laneSource()
        #expect(source.contains("content.loops"))
        #expect(source.contains("shifted(by:"))
        #expect(source.contains("Demo complete"))
    }

    @Test("The lane runs no scoring, capture or live-mic work")
    func noScoringOrCapture() throws {
        let source = try laneSource()
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
        #expect(source.contains("ScratchMotionLane(content:"))
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

    @Test("The notation status pill is shown once — in the lane header")
    func statusPillNotDuplicated() throws {
        let source = try practiceSource()
        // The status pill lives in the lane panel's "TARGET PATTERN" header…
        let lanePanel = try sliceBetween(source,
            from: "private func notationLanePanel(",
            to: "// Runtime status for the notation surface")
        #expect(lanePanel.contains("notationStatusChip"))
        // …and is not duplicated into the top HUD chip row above the lane.
        let topHUD = try sliceBetween(source,
            from: "private var practiceTopHUD",
            to: "private var practiceMetricsChip")
        #expect(!topHUD.contains("notationStatusChip"))
    }

    @Test("Every retired renderer is gone — one motion engine")
    func oldRenderersRetired() throws {
        let source = try practiceSource()
        #expect(!source.contains("AutoCutTargetChart"))
        #expect(!source.contains("VerticalNotationReelView"))
        #expect(!source.contains("NotationPlayheadClock"))
        #expect(!source.contains("TimingLaneView"))
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
        let source = try reelSource("ScratchLab/Views/ScratchMotionLane.swift")
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
        // The lane panel constructs ScratchMotionLane without a userEvents argument.
        #expect(!panel.contains("userEvents"))
        // The lane view itself still carries no scoring / capture / ML symbols.
        let lane = try reelSource("ScratchLab/Views/ScratchMotionLane.swift")
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

// MARK: - Scratch motion path

@Suite("Scratch motion path")
struct MotionPathTests {

    /// Lane content from `(direction, speed, start, end)` tuples — no segments,
    /// non-looping — for the geometry tests.
    private func laneContent(
        duration: TimeInterval,
        _ strokes: [(ScratchNotationDirection, ScratchNotationSpeedClassification,
                     TimeInterval, TimeInterval)]
    ) -> LaneContent {
        LaneContent(
            strokes: strokes.map {
                LaneStroke(startTime: $0.2, endTime: $0.3, direction: $0.0,
                           speed: $0.1, faderState: .open, isGhost: false)
            },
            segments: [], beatsPerMinute: nil, duration: duration, loops: false)
    }

    private func strokeSegments(_ path: MotionPath) -> [MotionSegment] {
        path.segments.filter { !$0.isHold }
    }

    @Test("A forward stroke produces rising motion")
    func forwardRises() throws {
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 4, [(.forward, .medium, 1, 2)]))
        let stroke = try #require(strokeSegments(path).first)
        #expect(stroke.endPosition > stroke.startPosition)
    }

    @Test("A backward stroke produces falling motion")
    func backwardFalls() throws {
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 4,
                             [(.forward, .medium, 1, 2), (.backward, .medium, 2, 3)]))
        let strokes = strokeSegments(path)
        // Each stroke becomes two sub-segments (out + return), so two input
        // strokes produce four stroke sub-segments.
        try #require(strokes.count == 4)
        // The forward stroke deflects above the centre at its peak.
        let forwardPeak = strokes
            .filter { if case .stroke(.forward) = $0.kind { return true }; return false }
            .flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        #expect(forwardPeak > 0.5)
        // The backward stroke deflects below the centre at its trough.
        let backwardTrough = strokes
            .filter { if case .stroke(.backward) = $0.kind { return true }; return false }
            .flatMap { [$0.startPosition, $0.endPosition] }.min() ?? 1
        #expect(backwardTrough < 0.5)
    }

    @Test("Gaps between strokes become flat hold segments")
    func gapsAreFlat() {
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 5,
                             [(.forward, .medium, 1, 2), (.backward, .medium, 3, 4)]))
        let holds = path.segments.filter { $0.isHold }
        // The 2–3 s gap is a hold, and every hold is flat.
        #expect(holds.contains { $0.startTime == 2 && $0.endTime == 3 })
        #expect(holds.allSatisfy { abs($0.endPosition - $0.startPosition) < 1e-9 })
    }

    @Test("Normalization keeps the whole path within 0...1 and fills the band")
    func normalizationBounds() throws {
        let manifestURL = reelTestsRepoRoot().appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_reel.json")
        let reel = try PracticeReelTimeline.decoded(from: Data(contentsOf: manifestURL))
        let path = ScratchStrokeGeometry.motionPath(for: LaneContent(reel: reel))

        for segment in path.segments {
            #expect(segment.startPosition >= -1e-9 && segment.startPosition <= 1 + 1e-9)
            #expect(segment.endPosition >= -1e-9 && segment.endPosition <= 1 + 1e-9)
        }
        let positions = path.segments.flatMap { [$0.startPosition, $0.endPosition] }
        #expect(abs((positions.min() ?? -1) - 0) < 1e-6)
        #expect(abs((positions.max() ?? -1) - 1) < 1e-6)
    }

    @Test("The path is continuous — segments share boundary time and position")
    func continuousBetweenStrokes() {
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 6,
                             [(.forward, .fast, 0.5, 1.0),
                              (.backward, .slow, 1.0, 2.0),
                              (.forward, .medium, 3.0, 3.5)]))
        for index in 1..<path.segments.count {
            #expect(abs(path.segments[index].startTime
                        - path.segments[index - 1].endTime) < 1e-9)
            #expect(abs(path.segments[index].startPosition
                        - path.segments[index - 1].endPosition) < 1e-9)
        }
    }

    @Test("Each push and pull deflects from centre to its rail and back")
    func strokesDeflectToRails() {
        // An alternating push/pull pattern with mixed speeds. The platter
        // rests at the centre between scratches, so every stroke shows as a
        // distinct bump aligned to its own time window — no flat runs from
        // consecutive same-direction strokes, no drift.
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 7,
                             [(.forward, .fast, 0.5, 1.0),
                              (.backward, .slow, 1.0, 1.8),
                              (.forward, .medium, 1.8, 2.3),
                              (.backward, .fast, 2.3, 2.7),
                              (.forward, .slow, 2.7, 3.6)]))

        // Forward strokes reach the high rail at their peak.
        let forwardPeak = path.segments
            .filter { if case .stroke(.forward) = $0.kind { return true }; return false }
            .flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        #expect(forwardPeak >= 0.98)

        // Backward strokes reach the low rail at their trough.
        let backwardTrough = path.segments
            .filter { if case .stroke(.backward) = $0.kind { return true }; return false }
            .flatMap { [$0.startPosition, $0.endPosition] }.min() ?? 1
        #expect(backwardTrough <= 0.02)

        // The path spans the whole 0...1 band — a meaningful range.
        let positions = path.segments.flatMap { [$0.startPosition, $0.endPosition] }
        #expect((positions.min() ?? 1) <= 0.02)
        #expect((positions.max() ?? 0) >= 0.98)

        // Every stroke segment either starts or ends at the centre — the
        // platter rests at the centre, the stroke deflects and returns.
        for segment in path.segments {
            guard case .stroke = segment.kind else { continue }
            let touchesCentre = abs(segment.startPosition - 0.5) < 1e-6
                             || abs(segment.endPosition - 0.5) < 1e-6
            #expect(touchesCentre)
        }

        // The lead-in hold rests at the centre — no edge-hugging.
        if let leadIn = path.segments.first, leadIn.isHold {
            #expect(abs(leadIn.startPosition - 0.5) < 1e-6)
            #expect(abs(leadIn.endPosition - 0.5) < 1e-6)
        }
    }

    @Test("A looping pattern closes the loop — tiles meet seamlessly at the wrap")
    func loopingPatternClosesSeam() {
        // A balanced alternating pattern with a trailing rest, set to loop.
        // Under the renderer's tile-and-shift, tile k's last position must
        // equal tile k+1's first position — otherwise the loop boundary
        // shows as a visible vertical step in the curve.
        let base = laneContent(duration: 4,
                               [(.forward, .medium, 0.0, 0.5),
                                (.backward, .medium, 0.5, 1.0),
                                (.forward, .medium, 1.0, 1.5),
                                (.backward, .medium, 1.5, 2.0)])
        let looping = LaneContent(strokes: base.strokes, segments: base.segments,
                                  beatsPerMinute: nil, duration: base.duration,
                                  loops: true)
        let path = ScratchStrokeGeometry.motionPath(for: looping)
        if let first = path.segments.first, let last = path.segments.last {
            #expect(abs(first.startPosition - last.endPosition) < 1e-9)
        }
    }

    @Test("Stroke times are preserved exactly — geometry never moves a stroke")
    func strokeTimesPreservedExactly() {
        let inputs: [(ScratchNotationDirection, ScratchNotationSpeedClassification,
                      TimeInterval, TimeInterval)] = [
            (.forward, .fast, 0.27, 0.778),
            (.backward, .slow, 1.07, 1.378),
            (.forward, .medium, 1.46, 1.763),
        ]
        let path = ScratchStrokeGeometry.motionPath(
            for: laneContent(duration: 5, inputs))
        for input in inputs {
            let (_, _, inStart, inEnd) = input
            // Every sub-segment within [inStart, inEnd] belongs to this
            // stroke; collectively they span exactly the input window.
            let covering = path.segments.filter {
                if case .stroke = $0.kind {
                    return $0.startTime >= inStart - 1e-9
                        && $0.endTime   <= inEnd   + 1e-9
                }
                return false
            }
            #expect(!covering.isEmpty)
            if let first = covering.first, let last = covering.last {
                #expect(abs(first.startTime - inStart) < 1e-9)
                #expect(abs(last.endTime - inEnd) < 1e-9)
            }
        }
    }

    @Test("Demo (non-looping) content opens at the centre rest position")
    func demoStartsAtCentreRestState() throws {
        let manifestURL = reelTestsRepoRoot().appendingPathComponent(
            "ScratchLab/Resources/CoachDemoAudio/baby_reel.json")
        let reel = try PracticeReelTimeline.decoded(from: Data(contentsOf: manifestURL))
        let demoContent = LaneContent(reel: reel)
        #expect(!demoContent.loops)
        let path = ScratchStrokeGeometry.motionPath(for: demoContent)
        // The Demo's first segment is the lead-in hold, resting at centre —
        // the platter rests at the middle of the lane before the demo starts.
        if let leadIn = path.segments.first {
            #expect(leadIn.isHold)
            #expect(abs(leadIn.startPosition - 0.5) < 1e-6)
            #expect(abs(leadIn.endPosition - 0.5) < 1e-6)
        }
    }

    @Test("Loop-seam handling does not shift any stroke time")
    func loopSeamDoesNotShiftStrokeTimes() {
        let pattern: [(ScratchNotationDirection, ScratchNotationSpeedClassification,
                       TimeInterval, TimeInterval)] = [
            (.forward, .medium, 0.0, 0.5),
            (.backward, .medium, 0.5, 1.0),
            (.forward, .medium, 1.0, 1.5),
            (.backward, .medium, 1.5, 2.0),
        ]
        let base = laneContent(duration: 4, pattern)
        let looping = LaneContent(strokes: base.strokes, segments: base.segments,
                                  beatsPerMinute: nil, duration: base.duration,
                                  loops: true)
        let nonLoopingPath = ScratchStrokeGeometry.motionPath(for: base)
        let loopingPath = ScratchStrokeGeometry.motionPath(for: looping)
        // Looping and non-looping share identical segment time boundaries —
        // the `loops` flag affects positions only, never time.
        #expect(nonLoopingPath.segments.count == loopingPath.segments.count)
        for (nonLooping, looping) in zip(nonLoopingPath.segments, loopingPath.segments) {
            #expect(abs(nonLooping.startTime - looping.startTime) < 1e-9)
            #expect(abs(nonLooping.endTime - looping.endTime) < 1e-9)
        }
    }
}

// MARK: - Motion renderer — angular notation, not a waveform

@Suite("Scratch motion renderer")
struct ScratchMotionRendererTests {

    private func rendererSource() throws -> String {
        try reelSource("ScratchLab/Models/ScratchMotionRenderer.swift")
    }

    @Test("Strokes draw as straight ramps — no easing, no waveform sampling")
    func strokesAreStraightRamps() throws {
        let source = try rendererSource()
        // A stroke is one straight line: no smooth-step easing and no
        // per-stroke multi-sampling — the angular shape itself is the notation.
        #expect(!source.contains("smoothStep"))
        #expect(!source.contains("samplesPerStroke"))
    }

    @Test("No area fill under the line — a stroke chart, not an audio waveform")
    func noWaveformFill() throws {
        let source = try rendererSource()
        #expect(!source.contains("fillsUnderCurve"))
        #expect(!source.contains("drawFill"))
    }

    @Test("Stroke boundaries are punctuated with node marks")
    func strokeBoundariesGetNodes() throws {
        let source = try rendererSource()
        #expect(source.contains("drawNode"))
        #expect(source.contains("showsNodes"))
    }

    @Test("The renderer keeps a safe cross-axis inset — the curve never clips")
    func rendererKeepsSafeInset() {
        // A real, non-trivial inset leaves room for the line, its boundary
        // nodes and its glow, while the motion still fills most of the lane.
        #expect(ScratchMotionRenderer.crossInsetFraction >= 0.10)
        #expect(ScratchMotionRenderer.crossInsetFraction <= 0.20)
    }

    @Test("Push and pull strokes carry distinct colours — a direction-coded notation")
    func pushAndPullUseDistinctColours() throws {
        let source = try rendererSource()
        // The Style carries an explicit backward (pull) colour…
        #expect(source.contains("var backwardColor"))
        // …and the renderer routes each stroke through that colour.
        #expect(source.contains("strokeColor(for:"))
        #expect(source.contains("case .stroke(.backward):"))
        // The .target preset never overrides backwardColor, so its push (cyan)
        // and its pull (the default pink) are different — not one continuous wave.
        #expect(ScratchMotionRenderer.Style.target.color
                != ScratchMotionRenderer.Style.target.backwardColor)
    }

    @Test("Holds draw as a quiet solid centre-line rest — no dashing")
    func holdsDrawAsQuietSolidRest() throws {
        let source = try rendererSource()
        // The hold branch of `draw` strokes a thin, low-opacity, continuous
        // line — a rest the eye reads through, not a row of dashes that
        // ticks the empty span between strokes.
        let drawBody = try sliceBetween(source,
            from: "if item.segment.isHold {",
            to: "} else {")
        #expect(!drawBody.contains("dash:"))
        // Still rendered (a solid stroke), not omitted — the rest is felt,
        // just no longer competing with the strokes themselves.
        #expect(drawBody.contains("stroke"))
    }

    @Test("Apex nodes punctuate stroke peaks — not every centre transition")
    func nodesPunctuateApexes() throws {
        let source = try rendererSource()
        // The renderer asks each segment whether its endpoint sits on a rail
        // (apex) before drawing a node — keeping centre-line transitions
        // un-marked so the rest line stays uncluttered.
        #expect(source.contains("isAtRail("))
    }
}

// MARK: - Cross-platform notation parity (iOS / macOS share the renderer)

@Suite("Cross-platform notation parity")
struct CrossPlatformNotationParityTests {

    private func phraseChartSource() throws -> String {
        try reelSource("ScratchLabDesktop/Views/ScratchPhraseChartView.swift")
    }

    private func notationCanvasSource() throws -> String {
        try reelSource("ScratchLabDesktop/Views/ScratchNotationCanvasView.swift")
    }

    private func motionLaneSource() throws -> String {
        try reelSource("ScratchLab/Views/ScratchMotionLane.swift")
    }

    // MARK: - Both macOS notation views call the shared angular renderer

    @Test("macOS static phrase chart routes .target through the shared renderer")
    func phraseChartUsesSharedRenderer() throws {
        let source = try phraseChartSource()
        // The shared model adapter and renderer are what the iOS lane uses;
        // the .target case must go through the SAME shared types so a Baby
        // Scratch reads identically on iOS Practice and macOS Review.
        #expect(source.contains("ScratchStrokeGeometry.motionPath("))
        #expect(source.contains("ScratchMotionRenderer.draw("))
        #expect(source.contains("LaneContent(notation:"))
        #expect(source.contains("LaneViewport("))
    }

    @Test("macOS animated visualizer routes its record lane through the shared renderer")
    func notationCanvasUsesSharedRenderer() throws {
        let source = try notationCanvasSource()
        #expect(source.contains("ScratchStrokeGeometry.motionPath("))
        #expect(source.contains("ScratchMotionRenderer.draw("))
        #expect(source.contains("LaneContent(notation:"))
        #expect(source.contains("LaneViewport("))
        // The looping pattern is tiled via the path's own shift, not by
        // hand-mapping per-stroke offsets — the geometry's deflect-and-return
        // ends both sides of the path at the centre, so tiles meet seamlessly.
        #expect(source.contains("motionPath.shifted(by:"))
    }

    @Test("iOS practice lane uses the same shared renderer + geometry")
    func iOSLaneUsesSharedRenderer() throws {
        let source = try motionLaneSource()
        #expect(source.contains("ScratchMotionRenderer.draw("))
        #expect(source.contains("ScratchStrokeGeometry.motionPath("))
    }

    // MARK: - The old per-platform stroke renderers are gone for target notation

    @Test("Static phrase chart no longer hand-rolls its own target strokes")
    func phraseChartDoesNotDrawStrokesItself() throws {
        let source = try phraseChartSource()
        // The hand-rolled single-diagonal stroke renderer (drawTargetStroke,
        // slopeHalfHeight) and the bespoke gap-hold renderer (drawHold)
        // belonged to the green/orange "FWD/BACK"-labelled chart — they are
        // retired now that the shared renderer draws the target's strokes.
        #expect(!source.contains("drawTargetStroke"))
        #expect(!source.contains("slopeHalfHeight"))
        #expect(!source.contains("drawTargetAxisLabels"))
    }

    @Test("Animated canvas no longer hand-rolls its own record-lane strokes")
    func notationCanvasDoesNotDrawStrokesItself() throws {
        let source = try notationCanvasSource()
        // The hand-rolled per-stroke / per-hold drawing for the record lane
        // and its `releaseNormalPlayback` dashed special case are gone —
        // the shared renderer now draws all record-lane strokes.
        #expect(!source.contains("private func drawStroke("))
        #expect(!source.contains("private func drawHold("))
        #expect(!source.contains("releaseNormalPlayback"))
    }

    // MARK: - The shared metrics are the single source of truth

    @Test("Shared renderer metrics are the single source of truth for both platforms")
    func sharedRendererMetricsAreCanonical() {
        // The cross-axis inset is a renderer-level constant; it applies to
        // every viewport that calls into ScratchMotionRenderer regardless of
        // the platform layout wrapping it.
        #expect(ScratchMotionRenderer.crossInsetFraction >= 0.10)
        #expect(ScratchMotionRenderer.crossInsetFraction <= 0.20)
        // The `.target` style — used by both the iOS lane and both macOS
        // notation views — carries distinct push (cyan) and pull colours so
        // direction is colour-coded across platforms, not just per-platform.
        #expect(ScratchMotionRenderer.Style.target.color
                != ScratchMotionRenderer.Style.target.backwardColor)
    }

    @Test("Loop seam stays closed for looping notation content on either platform")
    func loopSeamSurvivesParityRefactor() {
        // Baby Scratch wrapped as looping LaneContent — the same content the
        // macOS animated canvas tiles ±loopDuration. The geometry must close
        // the seam so adjacent tiles meet at the same position (no visible
        // step at the loop wrap).
        guard let notation = ScratchNotation.babyScratch else { return }
        let looping = LaneContent(notation: notation, beatsPerMinute: nil)
        #expect(looping.loops)
        let path = ScratchStrokeGeometry.motionPath(for: looping)
        if let first = path.segments.first, let last = path.segments.last {
            #expect(abs(first.startPosition - last.endPosition) < 1e-9)
        }
    }
}
