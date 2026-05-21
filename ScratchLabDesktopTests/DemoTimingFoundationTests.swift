import AVFoundation
import Foundation
import Testing
@testable import ScratchLab

// Unit tests for the call-and-response Demo timing foundation (Slices 0 & 1):
// the `PracticeReelTimeline` manifest model + loader + validator, and the
// `DemoAudioClock` smoothing/latency clock. Both types are pure, so these
// construct inputs and assert — no simulator, no view host.

// MARK: - Shared helpers

/// Repo root, derived from this test file's path — the same pattern the
/// source-string regression suites use.
private func reelTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
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
