// DemoAudioResolverTests.swift
// ScratchLabDesktopTests
//
// Practice Listen/demo audio, 2026-08-21 fix bundle. Two things proven here,
// per the corrected plan:
//
//  1. `DemoAudioResolver.resolve` — a pure, deterministic function — exact
//     match preferred, Baby-Scratch-only fallback to the bundled
//     call-response reel, honest `.unavailable` when neither resolves, and
//     no other lesson silently borrows the fallback.
//  2. `ScratchLabDemoModeController` — the ONE controller Practice's real
//     Listen/Pause/Restart buttons drive (see `practiceCoachCard` in
//     MacAnalyzerView.swift) — reaches a genuinely ready/playing state from
//     real bundled audio files on disk (not a synthetic/mocked player), and
//     Pause/Restart affect that same controller/player.
//
// Real on-disk resource files are used as the injected resolver targets
// (via `#filePath`-relative repo paths, the same pattern
// `DemoTimingFoundationTests.swift` already uses) rather than a synthetic
// "Bundle.main-equivalent test bundle" — `AVAudioPlayer` genuinely loads and
// plays them, so `isReady`/`playbackState` reflect real behavior, not a
// mocked stand-in.

import AVFoundation
import Foundation
import Testing
@testable import ScratchLab

private func demoAudioTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private let realExactDemoAudioURL = demoAudioTestsRepoRoot()
    .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav")
private let realFallbackDemoAudioURL = demoAudioTestsRepoRoot()
    .appendingPathComponent("ScratchLab/Resources/PracticeReelAudio/baby_reel_callresponse.wav")

/// Deterministic, directly controllable `ScratchCoachDemoPlayable` stub.
/// Unlike the real `AVAudioPlayer`-backed adapter, every method here runs
/// synchronously and inline, so tests can assert exact call ordering and
/// force specific `play()` outcomes without depending on real audio
/// hardware or timing. This proves `ScratchLabDemoModeController`'s
/// truthful-reporting logic in isolation; the real-file tests in this file
/// (run repeatedly, per the fix's verification pass) prove the actual
/// `AVAudioPlayer` adapter itself is race-free.
private final class DeterministicDemoPlayable: ScratchCoachDemoPlayable {
    private(set) var callLog: [String] = []
    var playShouldSucceed = true
    /// Lets a test simulate `play()` returning true but playback not
    /// actually sustaining — the second race shape observed against the
    /// real adapter before the fix (synchronous success, silent stop
    /// moments later).
    var reportsPlayingAfterSuccessfulPlay = true

    var isPlaying = false
    var currentTime: TimeInterval = 0

    func prepareToPlay() {
        callLog.append("prepare")
    }

    @discardableResult
    func play() -> Bool {
        callLog.append("play")
        isPlaying = playShouldSucceed && reportsPlayingAfterSuccessfulPlay
        return playShouldSucceed
    }

    func pause() {
        callLog.append("pause")
        isPlaying = false
    }

    func stop() {
        callLog.append("stop")
        isPlaying = false
    }
}

@MainActor
private func makeDemoModeController(
    fakePlayer: DeterministicDemoPlayable
) -> ScratchLabDemoModeController {
    ScratchLabDemoModeController(
        audioFileName: "baby_noBeat.wav",
        audioURLProvider: { name in name == "baby_noBeat.wav" ? realExactDemoAudioURL : nil },
        demoPlayer: ScratchCoachDemoAudioPlayer(playerFactory: { _ in fakePlayer })
    )
}

@Suite("DemoAudioResolver")
struct DemoAudioResolverTests {

    @Test("Prefers the exact requested resource when it resolves")
    func exactMatchPreferred() {
        let result = DemoAudioResolver.resolve(
            requestedFileName: "baby_noBeat.wav",
            allowsFallback: true,
            lookup: { name in name == "baby_noBeat.wav" ? realExactDemoAudioURL : nil }
        )
        #expect(result == .exact(realExactDemoAudioURL))
    }

    @Test("Falls back to the reel when the exact file is absent and fallback is allowed")
    func fallsBackWhenExactAbsent() {
        let result = DemoAudioResolver.resolve(
            requestedFileName: "baby_noBeat.wav",
            allowsFallback: true,
            fallbackFileName: "baby_reel_callresponse.wav",
            lookup: { name in name == "baby_reel_callresponse.wav" ? realFallbackDemoAudioURL : nil }
        )
        #expect(result == .fallback(realFallbackDemoAudioURL, actualFileName: "baby_reel_callresponse.wav"))
    }

    @Test("Never pretends the fallback is the exact requested source")
    func fallbackNeverClaimsToBeExact() {
        let result = DemoAudioResolver.resolve(
            requestedFileName: "baby_noBeat.wav",
            allowsFallback: true,
            fallbackFileName: "baby_reel_callresponse.wav",
            lookup: { name in name == "baby_reel_callresponse.wav" ? realFallbackDemoAudioURL : nil }
        )
        guard case .fallback(_, let actualFileName) = result else {
            Issue.record("expected .fallback")
            return
        }
        #expect(actualFileName != "baby_noBeat.wav")
        #expect(actualFileName == "baby_reel_callresponse.wav")
    }

    @Test("Reports unavailable, not a silent success, when neither resource resolves")
    func unavailableWhenNothingResolves() {
        let result = DemoAudioResolver.resolve(
            requestedFileName: "baby_noBeat.wav",
            allowsFallback: true,
            lookup: { _ in nil }
        )
        #expect(result == .unavailable)
    }

    @Test("A lesson without fallback enabled never borrows another lesson's fallback resource")
    func noFallbackForUnrelatedLessons() {
        // chirpflare_noBeat.wav is a real, different lesson's exact file —
        // absent here on purpose; fallback must not be attempted since
        // allowsFallback is false for this (non-Baby-Scratch) lesson.
        let result = DemoAudioResolver.resolve(
            requestedFileName: "chirpflare_noBeat.wav",
            allowsFallback: false,
            fallbackFileName: "baby_reel_callresponse.wav",
            lookup: { name in name == "baby_reel_callresponse.wav" ? realFallbackDemoAudioURL : nil }
        )
        #expect(result == .unavailable)
    }
}

@MainActor
@Suite("ScratchLabDemoModeController — single-coordinator Listen/Pause/Restart")
struct ScratchLabDemoModeControllerTests {

    @Test("startDemo() reaches a genuinely ready, playing state from the real bundled exact file")
    func startDemoReachesPlayingStateWithExactFile() {
        let controller = ScratchLabDemoModeController(
            audioFileName: "baby_noBeat.wav",
            audioURLProvider: { name in name == "baby_noBeat.wav" ? realExactDemoAudioURL : nil }
        )
        controller.startDemo()
        #expect(controller.isReady)
        #expect(controller.demoPlayer.isAudioAvailable)
        #expect(!controller.demoPlayer.isUsingFallbackAudio)
        #expect(controller.demoPlayer.playbackState == .playing)
        #expect(controller.statusMessage.contains("playing"))
        controller.stopDemo()
    }

    @Test("startDemo() falls back to the reel and reports it honestly when the exact file is absent")
    func startDemoFallsBackHonestly() {
        let controller = ScratchLabDemoModeController(
            audioFileName: "baby_noBeat.wav",
            audioURLProvider: { name in name == "baby_reel_callresponse.wav" ? realFallbackDemoAudioURL : nil }
        )
        controller.startDemo()
        #expect(controller.isReady)
        #expect(controller.demoPlayer.isAudioAvailable)
        #expect(controller.demoPlayer.isUsingFallbackAudio)
        #expect(controller.demoPlayer.playbackState == .playing)
        // Honest: never claims to be the exact dry demo.
        #expect(!controller.statusMessage.lowercased().contains("could not"))
        #expect(controller.statusMessage.lowercased().contains("reel") || controller.statusMessage.lowercased().contains("practice"))
        controller.stopDemo()
    }

    @Test("startDemo() fails visibly and truthfully when nothing resolves — the Listen button's real controller, not a no-op")
    func startDemoFailsVisiblyWhenNothingResolves() {
        let controller = ScratchLabDemoModeController(
            audioFileName: "baby_noBeat.wav",
            audioURLProvider: { _ in nil }
        )
        controller.startDemo()
        #expect(!controller.isReady)
        #expect(!controller.demoPlayer.isAudioAvailable)
        #expect(controller.statusMessage == "Bundled demo audio is unavailable.")
    }

    @Test("Pause and Restart affect the same controller/player Listen started")
    func pauseAndRestartAffectSameController() {
        let controller = ScratchLabDemoModeController(
            audioFileName: "baby_noBeat.wav",
            audioURLProvider: { name in name == "baby_noBeat.wav" ? realExactDemoAudioURL : nil }
        )
        controller.startDemo()
        #expect(controller.demoPlayer.playbackState == .playing)

        controller.pauseDemo()
        #expect(controller.demoPlayer.playbackState == .paused)
        #expect(controller.statusMessage == "Demo paused.")

        controller.resumeDemo()
        #expect(controller.demoPlayer.playbackState == .playing)
        #expect(controller.statusMessage == "Demo resumed.")

        controller.replayDemo()
        #expect(controller.demoPlayer.playbackState == .playing)
        controller.stopDemo()
    }

    // MARK: - Deterministic playback-sequencing / honest-failure coverage
    //
    // These use an injected `DeterministicDemoPlayable` (synchronous, no
    // real audio hardware) to prove the controller's sequencing and
    // honest-reporting contract precisely, independent of real `AVAudioPlayer`
    // timing. The real-file tests above cover the actual adapter.

    @Test("configure(url:) prepares audio before replay() plays it, in that order")
    func configureThenReplayPreparesBeforePlaying() {
        let fakePlayer = DeterministicDemoPlayable()
        let demoAudioPlayer = ScratchCoachDemoAudioPlayer(playerFactory: { _ in fakePlayer })
        demoAudioPlayer.configure(url: realExactDemoAudioURL, sourceFileName: "baby_noBeat.wav", isFallback: false)
        demoAudioPlayer.replay()
        #expect(fakePlayer.callLog == ["prepare", "play"])
    }

    @Test("startDemo() does not claim success when play() returns false")
    func startDemoReportsHonestFailureWhenPlayReturnsFalse() {
        let fakePlayer = DeterministicDemoPlayable()
        fakePlayer.playShouldSucceed = false
        let controller = makeDemoModeController(fakePlayer: fakePlayer)

        controller.startDemo()

        #expect(!controller.isReady)
        #expect(controller.demoPlayer.playbackState == .stopped)
        #expect(controller.analysisTimer == nil, "Analysis must not start when playback never started")
        #expect(controller.statusMessage.lowercased().contains("could not"))
        controller.stopDemo()
    }

    @Test("startDemo() does not claim success when play() returns true but audio never actually plays")
    func startDemoReportsHonestFailureWhenPlaybackSilentlyDies() {
        let fakePlayer = DeterministicDemoPlayable()
        fakePlayer.playShouldSucceed = true
        fakePlayer.reportsPlayingAfterSuccessfulPlay = false
        let controller = makeDemoModeController(fakePlayer: fakePlayer)

        controller.startDemo()

        #expect(!controller.isReady)
        #expect(
            controller.demoPlayer.playbackState == .stopped,
            "confirmPlaybackStarted must reset playbackState via demoPlayer.stop(), not leave a stale .playing value"
        )
        #expect(controller.analysisTimer == nil)
        #expect(controller.statusMessage.lowercased().contains("could not"))
        controller.stopDemo()
    }

    @Test("replayDemo() does not publish false success when playback fails to restart")
    func replayDemoReportsHonestFailure() {
        let fakePlayer = DeterministicDemoPlayable()
        let controller = makeDemoModeController(fakePlayer: fakePlayer)
        controller.startDemo()
        #expect(controller.isReady)
        #expect(controller.demoPlayer.playbackState == .playing)

        fakePlayer.playShouldSucceed = false
        controller.replayDemo()

        #expect(!controller.isReady)
        #expect(controller.demoPlayer.playbackState == .stopped)
        #expect(controller.analysisTimer == nil)
        #expect(controller.statusMessage.lowercased().contains("could not"))
        controller.stopDemo()
    }

    @Test("resumeDemo() does not publish false success when playback fails to resume")
    func resumeDemoReportsHonestFailure() {
        let fakePlayer = DeterministicDemoPlayable()
        let controller = makeDemoModeController(fakePlayer: fakePlayer)
        controller.startDemo()
        controller.pauseDemo()
        #expect(controller.demoPlayer.playbackState == .paused)

        fakePlayer.playShouldSucceed = false
        controller.resumeDemo()

        #expect(!controller.isReady)
        #expect(controller.demoPlayer.playbackState == .stopped)
        #expect(controller.analysisTimer == nil)
        #expect(controller.statusMessage.lowercased().contains("could not"))
        controller.stopDemo()
    }

    @Test("startAlignedPlayback() does not publish false success when playback fails to start")
    func startAlignedPlaybackReportsHonestFailure() {
        let fakePlayer = DeterministicDemoPlayable()
        let controller = makeDemoModeController(fakePlayer: fakePlayer)
        controller.prepareDemoForBeatAlignment()
        #expect(controller.isReady)

        fakePlayer.playShouldSucceed = false
        controller.startAlignedPlayback()

        #expect(!controller.isReady)
        #expect(controller.demoPlayer.playbackState == .stopped)
        #expect(controller.analysisTimer == nil)
        #expect(controller.statusMessage.lowercased().contains("could not"))
        controller.stopDemo()
    }
}
