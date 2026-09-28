// Shipping media boundary: no archived audio/video is opened by these tests.
import Foundation
import Testing
@testable import ScratchLab

@Suite("Shipping media boundary")
@MainActor
struct ShippingMediaBoundaryTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Old scratch recordings never resolve, including a bundle-root fallback")
    func noArchiveAudioResolution() {
        for name in ["cxl_baby_target.wav", "baby_noBeat.wav", "chirpflare_noBeat.wav", "baby_reel_callresponse.wav"] {
            #expect(ScratchCoachDemoAudioPlayer.bundledDemoAudioURL(named: name) == nil)
        }
        #expect(PracticeReelTimeline.bundledManifestURL(named: "baby_reel") == nil)
    }

    @Test("Listen explicitly unavailable without approved original audio")
    func listenUnavailable() {
        let player = ScratchCoachDemoAudioPlayer()
        player.configure(withAudioFileNamed: "baby_noBeat.wav")
        player.play()
        #expect(!player.isAudioAvailable)
        #expect(!player.isPlaying)
        let controller = ScratchLabDemoModeController()
        controller.startDemo()
        #expect(!controller.isReady)
        #expect(controller.statusMessage.contains("Listen unavailable"))
    }

    @Test("Silent Watch starts, advances, clamps and completes by authored time")
    func silentWatchCompletes() {
        let epoch = Date(timeIntervalSince1970: 100)
        let owner = PracticeGameplayCoordinator(now: { epoch })
        owner.beginWatch(pattern: ScratchNotation.babyScratchCycle, bpm: 100)
        #expect(owner.state == .watching)
        #expect(owner.watchBPM == 100)
        #expect(owner.watchClock.now(at: epoch) == 0)
        #expect(abs(owner.watchClock.now(at: epoch.addingTimeInterval(0.25)) - 0.25) < 0.00001)
        owner.advanceWatch(at: epoch.addingTimeInterval(0.59))
        #expect(owner.state == .watching)
        owner.advanceWatch(at: epoch.addingTimeInterval(0.61))
        #expect(owner.state == .ready)
        #expect(abs(owner.watchClock.now(at: epoch.addingTimeInterval(10)) - 0.6) < 0.00001)
        #expect(owner.currentResult == nil)
        #expect(owner.lastSession == nil)
    }

    @Test("Baby remains authored forward/backward with fader open throughout")
    func babyTopology() throws {
        let pattern = ScratchNotation.babyScratchCycle
        let notation = try #require(pattern.materialized(bpm: 100))
        #expect(pattern.strokes.map(\.direction) == [.forward, .backward])
        #expect(pattern.strokes.allSatisfy { $0.faderState == .open })
        #expect(abs(notation.timelineDuration - 0.6) < 0.00001)
        #expect(notation.strokes.map(\.direction) == [.forward, .backward])
    }

    @Test("Late Watch ticks cannot terminate a Copy attempt")
    func watchCannotChangeCopy() {
        let epoch = Date(timeIntervalSince1970: 0)
        let owner = PracticeGameplayCoordinator(now: { epoch })
        owner.beginWatch(pattern: ScratchNotation.babyScratchCycle, bpm: 100)
        owner.beginAttempt(pattern: ScratchNotation.babyScratchCycle, bpm: 100, countInBeats: 4)
        let copyState = owner.state
        owner.advanceWatch(at: epoch.addingTimeInterval(60))
        #expect(owner.state == copyState)
    }

    @Test("Invalid tempo cannot start Watch")
    func invalidWatch() {
        for bpm in [0, -1, Double.nan, Double.infinity] {
            let owner = PracticeGameplayCoordinator()
            owner.beginWatch(pattern: ScratchNotation.babyScratchCycle, bpm: bpm)
            #expect(owner.state == .idle)
        }
    }

    @Test("Both learner hosts use the existing non-audio notation clock")
    func practiceWiring() throws {
        let mac = try source("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let ios = try source("ScratchLab/Views/PracticeModeView.swift")
        #expect(mac.contains("practiceCoordinator.advanceWatch(at: Date())"))
        #expect(mac.contains("practiceCanonicalPattern?.materialized(bpm: practiceTeachingBPM)"))
        #expect(ios.contains("watchClock.isComplete(at: date)"))
        #expect(ios.contains(".bounded(start: notationClockStartDate"))
        for host in [mac, ios] {
            #expect(!host.contains("sampledPlaybackTime()"))
            #expect(!host.contains("cxlBabyScratchAudioFileName"))
            #expect(!host.contains("PracticeReelTimeline.loadBundled"))
            #expect(!host.contains("readDerivedInspection"))
            #expect(!host.contains("ScratchExampleLibraryView"))
        }
    }

    @Test("Archive resources and Reference Examples UI are absent from shipping phases")
    func shippingResourceMembership() throws {
        let project = try source("ScratchLab.xcodeproj/project.pbxproj")
        for token in ["CoachDemoAudio in Resources", "CoachDemoMotion in Resources",
                      "PracticeReelAudio in Resources", "Notation in Resources",
                      "ReferenceExamples", "LocalReferenceLibrary",
                      "ScratchExampleLibraryView.swift in Sources"] {
            #expect(!project.contains(token))
        }
        for folder in ["CoachDemoAudio", "PracticeReelAudio", "ReferenceExamples", "CoachDemoMotion"] {
            let url = Bundle.main.resourceURL!.appendingPathComponent(folder)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Archival demo export and reference navigation are removed")
    func noArchiveEntryPoints() throws {
        for path in ["ScratchLab/Views/MainMenuView.swift",
                     "ScratchLabDesktop/Views/MacAnalyzerView.swift",
                     "ScratchLabDesktop/Views/ReferenceAuthoringView.swift"] {
            let text = try source(path)
            #expect(!text.contains("ScratchLabDemoSessionBuilder"))
            #expect(!text.contains("showingReferenceExamples"))
            #expect(!text.contains("ScratchExampleLibraryView"))
            #expect(!text.contains("LocalReferenceLibrary"))
        }
    }

    @Test("User-capture review and canonical authoring stay present")
    func userCaptureRemains() throws {
        let authoring = try source("ScratchLabDesktop/Views/ReferenceAuthoringView.swift")
        let mac = try source("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        #expect(authoring.contains("reviewSection"))
        #expect(authoring.contains("viewModel.mediaReview"))
        #expect(mac.contains("captureEngine.lastRoutineRecordingURL"))
        #expect(mac.contains("shareLastRoutineSession"))
        #expect(mac.contains("let recordingStarted = await waitForPracticeRecordingStart()"))
        #expect(mac.contains("guard captureEngine.ownsOrdinaryRoutineCapture(startRequest) else { return false }"))
        #expect(mac.contains("guard recordingStarted else"))
    }
}
