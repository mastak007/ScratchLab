import XCTest
@testable import ScratchLab

/// Desktop scratch bank pad audio player tests.
/// Verifies sample ID → WAV URL mapping, bundled file availability,
/// and that the player handles missing files without crashing.
final class ScratchBankPadAudioPlayerTests: XCTestCase {

    // MARK: - 1–4: Known sample IDs resolve to bundled WAVs in the app bundle

    func testAhhhWAVExistsInAppBundle() throws {
        let root = try XCTUnwrap(ScratchLabDesktopTestResourceResolver.appResourcesURL,
                                  "App Resources must be available")
        let player = ScratchBankPadAudioPlayer(resourceRoot: root)
        let url = try XCTUnwrap(player.wavURL(for: "ahhh"), "ahhh.wav must exist in app Resources")
        XCTAssertEqual(url.lastPathComponent, "ahhh.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFreshWAVExistsInAppBundle() throws {
        let root = try XCTUnwrap(ScratchLabDesktopTestResourceResolver.appResourcesURL,
                                  "App Resources must be available")
        let player = ScratchBankPadAudioPlayer(resourceRoot: root)
        let url = try XCTUnwrap(player.wavURL(for: "fresh"), "fresh.wav must exist in app Resources")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAhYeahWAVExistsInAppBundle() throws {
        let root = try XCTUnwrap(ScratchLabDesktopTestResourceResolver.appResourcesURL,
                                  "App Resources must be available")
        let player = ScratchBankPadAudioPlayer(resourceRoot: root)
        let url = try XCTUnwrap(player.wavURL(for: "ah_yeah"), "ah_yeah.wav must exist in app Resources")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCheckItOutWAVExistsInAppBundle() throws {
        let root = try XCTUnwrap(ScratchLabDesktopTestResourceResolver.appResourcesURL,
                                  "App Resources must be available")
        let player = ScratchBankPadAudioPlayer(resourceRoot: root)
        let url = try XCTUnwrap(player.wavURL(for: "check_it_out"), "check_it_out.wav must exist in app Resources")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 5. Unknown sample ID returns nil

    func testUnknownSampleIDReturnsNil() {
        let player = ScratchBankPadAudioPlayer(
            resourceRoot: ScratchLabDesktopTestResourceResolver.appResourcesURL
        )
        XCTAssertNil(player.wavURL(for: "nonexistent"))
        XCTAssertNil(player.wavURL(for: ""))
        // "wickid" is not in the 4-pad set.
        XCTAssertNil(player.wavURL(for: "wickid"))
    }

    // MARK: - 6. Nil resource root returns nil gracefully

    func testNilResourceRootReturnsNil() {
        let player = ScratchBankPadAudioPlayer(resourceRoot: nil)
        XCTAssertNil(player.wavURL(for: "ahhh"))
    }

    // MARK: - 7. Empty / missing resource directory returns nil

    func testEmptyResourceDirectoryReturnsNil() {
        let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let player = ScratchBankPadAudioPlayer(resourceRoot: emptyDir)
        XCTAssertNil(player.wavURL(for: "ahhh"))
    }

    // MARK: - 8. Known sample IDs set

    func testKnownSampleIDsContainsFourEntries() {
        let ids = ScratchBankPadAudioPlayer.knownSampleIDs
        XCTAssertEqual(ids.count, 4)
        XCTAssertTrue(ids.contains("ahhh"))
        XCTAssertTrue(ids.contains("fresh"))
        XCTAssertTrue(ids.contains("ah_yeah"))
        XCTAssertTrue(ids.contains("check_it_out"))
    }

    // MARK: - 9. Play does not crash on missing sample

    func testPlayDoesNotCrashOnMissingSample() {
        let player = ScratchBankPadAudioPlayer(resourceRoot: nil)
        player.play(sampleID: "nonexistent")
        player.play(sampleID: "ahhh")
        XCTAssertTrue(true, "play() handled missing sample without crashing")
    }

    // MARK: - 10. Play does not crash on valid bundled samples

    func testPlayDoesNotCrashOnBundledSamples() throws {
        let root = try XCTUnwrap(ScratchLabDesktopTestResourceResolver.appResourcesURL,
                                  "App Resources must be available")
        let player = ScratchBankPadAudioPlayer(resourceRoot: root)
        for id in ScratchBankPadAudioPlayer.knownSampleIDs {
            player.play(sampleID: id)
        }
        XCTAssertTrue(true, "play() on bundled samples did not crash")
    }

    // MARK: - 11. Stop does not crash when nothing is playing

    func testStopDoesNotCrashWhenIdle() {
        let player = ScratchBankPadAudioPlayer(resourceRoot: nil)
        player.stop()
        XCTAssertTrue(true, "stop() when idle did not crash")
    }

    // MARK: - 12. No MIDI / scoring / routing API

    func testPlayerHasNoMIDIOrScoringAPI() {
        let mirror = Mirror(reflecting: ScratchBankPadAudioPlayer(resourceRoot: nil))
        let labels = mirror.children.compactMap { $0.label }
        let forbidden = labels.filter {
            $0.lowercased().contains("midi") ||
            $0.lowercased().contains("scor") ||
            $0.lowercased().contains("rout")
        }
        XCTAssertTrue(forbidden.isEmpty,
            "ScratchBankPadAudioPlayer must not expose MIDI/scoring/routing; found: \(forbidden)")
    }

    // MARK: - 13. Player is not an ObservableObject (no UI binding)

    func testPlayerIsNotObservableObject() {
        let player = ScratchBankPadAudioPlayer(resourceRoot: nil)
        XCTAssertFalse(player is ObservableObject,
            "ScratchBankPadAudioPlayer must not be an ObservableObject")
    }
}
