import CryptoKit
import XCTest
@testable import ScratchLab

final class ScratchExampleLibraryTests: XCTestCase {
    func testBundledCatalogueContainsCompleteUnapprovedExamplesAndVerifiedAssets() async throws {
        let library = try await ScratchExampleLibrary.loadBundled()
        let examples = library.manifest.examples
        XCTAssertFalse(examples.isEmpty)
        XCTAssertEqual(examples.count, 24)
        XCTAssertEqual(examples.filter { $0.classLabel == "tears" }.count, 2)
        XCTAssertEqual(examples.filter { $0.classLabel != "tears" }.count, 22)
        XCTAssertEqual(examples.compactMap(\.sequence).count, 24)
        XCTAssertEqual(examples.filter { $0.sequence?.audioRolesConfirmed == false }.count, 9)
        XCTAssertEqual(Set(examples.map(\.classLabel)), Set(ScratchClassLabel.allCases.map(\.rawValue)))
        XCTAssertTrue(examples.allSatisfy { !$0.canonicalApproval && $0.labelStatus == "sourceLabelUnreviewed" })
        XCTAssertEqual(Set(library.manifest.models.map(\.modality)), Set(["audio", "motion"]))
        XCTAssertTrue(library.manifest.models.allSatisfy(\.advisoryOnly))
        for asset in library.manifest.assets {
            let url = try await library.verifiedURL(assetID: asset.id)
            XCTAssertTrue(url.isFileURL, asset.id)
        }
    }

    func testLoadsProvenanceWithoutPromotingSourceLabelsAndVerifiesSelectedMedia() async throws {
        let fixture = try makeFixture()
        let library = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        XCTAssertEqual(library.manifest.sourceManifestSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(library.manifest.limitations, ["Source labels and synchronization remain unverified."])
        XCTAssertEqual(library.manifest.examples.first?.classLabel, "baby")
        XCTAssertEqual(library.manifest.examples.first?.canonicalApproval, false)
        XCTAssertNil(library.manifest.examples.first?.angles.first?.handCacheAssetID)
        XCTAssertEqual(library.manifest.assets.first?.originalRelativePath, "video/baby/source.mp4")
        XCTAssertEqual(library.manifest.models.first?.advisoryOnly, true)
        let url = try await library.verifiedURL(assetID: "video")
        XCTAssertEqual(url, fixture.root.appendingPathComponent("assets/video.mp4").resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: url), Fixture.videoBytes)
    }

    func testManifestTamperingFailsBeforeDecodingOrConsumption() async throws {
        let fixture = try makeFixture()
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifestURL)
        bytes.append(contentsOf: [10])
        try bytes.write(to: manifestURL)
        await assertLoadFails(fixture.root)
    }

    func testRehashedUnsupportedSchemaAndFalseTrustClaimsAreRejected() async throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schema"] = "scratchlab_reference_examples_v99" }),
            ("canonical approval", { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                examples[0]["canonicalApproval"] = true
                manifest["examples"] = examples
            }),
            ("unknown label", { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                examples[0]["classLabel"] = "unknown-technique"
                manifest["examples"] = examples
            }),
            ("validated model claim", { manifest in
                var models = manifest["models"] as! [[String: Any]]
                models[0]["advisoryOnly"] = false
                manifest["models"] = models
            }),
            ("missing source identity", { $0["sourceManifestSHA256"] = "" })
        ]
        for (name, mutate) in mutations {
            let fixture = try makeFixture()
            try fixture.rewrite(mutate)
            await assertLoadFails(fixture.root, message: name)
        }
    }

    func testDuplicateIdentitiesAndCrossRoleReferencesAreRejected() async throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("duplicate asset", { manifest in
                var assets = manifest["assets"] as! [[String: Any]]
                assets.append(assets[0])
                manifest["assets"] = assets
            }),
            ("duplicate performance", { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                examples.append(examples[0])
                manifest["examples"] = examples
            }),
            ("model used as video", { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                examples[0]["angles"] = [["id": "angle_1", "videoAssetID": "model"]]
                manifest["examples"] = examples
            }),
            ("unregistered video", { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                examples[0]["angles"] = [["id": "angle_1", "videoAssetID": "absent"]]
                manifest["examples"] = examples
            })
        ]
        for (name, mutate) in mutations {
            let fixture = try makeFixture()
            try fixture.rewrite(mutate)
            await assertLoadFails(fixture.root, message: name)
        }
    }

    func testSelectedFileIsReverifiedAfterLibraryLoadIncludingSameSizeTamper() async throws {
        let fixture = try makeFixture()
        let library = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        _ = try await library.verifiedURL(assetID: "video")
        let videoURL = fixture.root.appendingPathComponent("assets/video.mp4")
        try Data(repeating: 120, count: Fixture.videoBytes.count).write(to: videoURL)
        await assertAssetFails(library, assetID: "video")
        try Fixture.videoBytes.write(to: videoURL)
        _ = try await library.verifiedURL(assetID: "video")
        try Data([1]).write(to: videoURL)
        await assertAssetFails(library, assetID: "video")
        await assertAssetFails(library, assetID: "unlisted")
    }

    func testRehashedTraversalAndAbsolutePathsAreRejected() async throws {
        for unsafe in ["../outside.mp4", "/tmp/outside.mp4", "assets/../../outside.mp4", "assets\\outside.mp4"] {
            let fixture = try makeFixture()
            try fixture.rewrite { manifest in
                var assets = manifest["assets"] as! [[String: Any]]
                assets[0]["relativePath"] = unsafe
                manifest["assets"] = assets
            }
            await assertLoadFails(fixture.root, message: unsafe)
        }
    }

    func testEscapingSymlinkIsRejectedAtLoadAndAfterSelection() async throws {
        let fixture = try makeFixture()
        let library = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        try Fixture.videoBytes.write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let video = fixture.root.appendingPathComponent("assets/video.mp4")
        try FileManager.default.removeItem(at: video)
        try FileManager.default.createSymbolicLink(at: video, withDestinationURL: outside)
        await assertLoadFails(fixture.root)
        await assertAssetFails(library, assetID: "video")
    }

    func testManifestSymlinkCannotEscapeLibrary() async throws {
        let fixture = try makeFixture()
        let manifest = fixture.root.appendingPathComponent("manifest.json")
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.moveItem(at: manifest, to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        await assertLoadFails(fixture.root)
    }

    func testUnconfirmedSequenceAudioUsesSourceTrackChoicesAndPreservesWholeRange() async throws {
        let fixture = try makeSequenceFixture()
        let library = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        let example = try XCTUnwrap(library.manifest.examples.first)
        XCTAssertEqual(example.audioOptions.map(\.id), ["track0", "track1", "track2"])
        XCTAssertEqual(example.preferredAudioID, "track0")
        XCTAssertTrue(example.audioOptions.allSatisfy { $0.title.contains("unconfirmed") })
        XCTAssertEqual(example.sequence?.performanceID, "cxl-mkv:baby:79")
        XCTAssertEqual(example.sequence?.startSeconds, 35.035)
        XCTAssertEqual(example.sequence?.endSeconds, 59.2592)
        XCTAssertTrue(example.displayName.contains("Baby (Original Scratch)"))
        for id in example.audioAssetIDs.values { _ = try await library.verifiedURL(assetID: id) }
    }

    func testSequenceRejectsFalseAudioRolesOldCachesAndTimingClaims() async throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["audioRolesConfirmed"] = true },
            { $0["pairedSyncStatus"] = "verified" },
            { $0["performanceID"] = "a different performance" },
            { $0["endSeconds"] = 12 },
            { $0["sourcePass"] = 2 },
            { $0["lessonTitle"] = " " },
            { $0["warnings"] = [] }
        ]
        for mutate in mutations {
            let fixture = try makeSequenceFixture()
            try fixture.rewrite { manifest in
                var examples = manifest["examples"] as! [[String: Any]]
                var sequence = examples[0]["sequence"] as! [String: Any]
                mutate(&sequence)
                examples[0]["sequence"] = sequence
                manifest["examples"] = examples
            }
            await assertLoadFails(fixture.root)
        }
        let fixture = try makeSequenceFixture()
        try fixture.rewrite { manifest in
            var examples = manifest["examples"] as! [[String: Any]]
            examples[0]["angles"] = [["id": "angle_1", "videoAssetID": "video", "handCacheAssetID": "old-cache"]]
            manifest["examples"] = examples
        }
        await assertLoadFails(fixture.root)
    }

    func testSequenceProvenanceCannotBeChangedOrRemovedAfterItsManifestWasWritten() async throws {
        let fixture = try makeSequenceFixture()
        let provenance = fixture.root.appendingPathComponent("evidence/provenance.json")
        _ = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        try Data("altered source observation".utf8).write(to: provenance)
        await assertLoadFails(fixture.root)
        try FileManager.default.removeItem(at: provenance)
        await assertLoadFails(fixture.root)
    }

    func testUnresolvedSourceDifferenceRequiresBothPassesWithOnePerformanceIdentity() async throws {
        let fixture = try makeSequenceFixture()
        try fixture.rewrite { manifest in
            var examples = manifest["examples"] as! [[String: Any]]
            var sequence = examples[0]["sequence"] as! [String: Any]
            sequence["pairedSyncStatus"] = "unresolvedSourceDifference"
            examples[0]["sequence"] = sequence
            manifest["examples"] = examples
        }
        await assertLoadFails(fixture.root, message: "The other unresolved source pass is missing")
        try fixture.rewrite { manifest in
            var examples = manifest["examples"] as! [[String: Any]]
            var second = examples[0]
            var sequence = second["sequence"] as! [String: Any]
            second["take"] = "take02"
            second["id"] = "cxl-mkv-v2:baby:79:take02"
            sequence["sourcePass"] = 2
            sequence["startSeconds"] = 59.2592
            sequence["endSeconds"] = 83.450033
            second["sequence"] = sequence
            examples.append(second)
            manifest["examples"] = examples
        }
        let library = try await ScratchExampleLibrary.load(rootURL: fixture.root)
        XCTAssertEqual(Set(library.manifest.examples.compactMap { $0.sequence?.performanceID }).count, 1)
        XCTAssertTrue(library.manifest.examples[0].displayName.contains("Source pass 1"))
        XCTAssertTrue(library.manifest.examples[1].displayName.contains("Source pass 2"))
        try fixture.rewrite { manifest in
            var examples = manifest["examples"] as! [[String: Any]]
            var sequence = examples[1]["sequence"] as! [String: Any]
            sequence["startSeconds"] = 60.0
            examples[1]["sequence"] = sequence
            manifest["examples"] = examples
        }
        await assertLoadFails(fixture.root, message: "Do not lose a section between source passes")
    }

    private func makeSequenceFixture() throws -> Fixture {
        let fixture = try makeFixture()
        let provenance = Data("[]".utf8)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("evidence"), withIntermediateDirectories: true)
        try provenance.write(to: fixture.root.appendingPathComponent("evidence/provenance.json"))
        for id in ["audio2", "audio3"] {
            try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("assets/audio.wav"),
                                            to: fixture.root.appendingPathComponent("assets/\(id).wav"))
        }
        try fixture.rewrite { manifest in
            manifest["schema"] = "scratchlab_reference_examples_v2"
            manifest["sourceManifestSHA256"] = SHA256.hash(data: provenance).map { String(format: "%02x", $0) }.joined()
            var assets = manifest["assets"] as! [[String: Any]]
            let audio = assets.first { $0["id"] as? String == "audio" }!
            for id in ["audio2", "audio3"] {
                var copy = audio
                copy["id"] = id; copy["relativePath"] = "assets/\(id).wav"
                assets.append(copy)
            }
            manifest["assets"] = assets
            var example = (manifest["examples"] as! [[String: Any]])[0]
            example["id"] = "cxl-mkv-v2:baby:79:take01"
            example["audioAssetIDs"] = ["track0": "audio", "track1": "audio2", "track2": "audio3"]
            example["sequence"] = ["performanceID": "cxl-mkv:baby:79", "sourcePass": 1,
                                   "lessonTitle": "Baby (Original Scratch)",
                                   "startSeconds": 35.035, "endSeconds": 59.2592, "repeatOffsetFrames": 726,
                                   "audioRolesConfirmed": false, "pairedSyncStatus": "notEstablished",
                                   "warnings": ["Source roles unconfirmed."]]
            manifest["examples"] = [example]
        }
        return fixture
    }

    private func assertLoadFails(_ root: URL, message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ScratchExampleLibrary.load(rootURL: root)
            XCTFail("Accepted invalid catalogue: \(message)", file: file, line: line)
        } catch { }
    }

    private func assertAssetFails(_ library: ScratchExampleLibrary, assetID: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await library.verifiedURL(assetID: assetID)
            XCTFail("Accepted invalid asset: \(assetID)", file: file, line: line)
        } catch { }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchExamples-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(root: root)
        try fixture.write()
        return fixture
    }

    private struct Fixture {
        static let videoBytes = Data("video fixture".utf8)
        let root: URL

        func write() throws {
            let sources: [(String, String, String, Data)] = [
                ("video", "video.mp4", "video/baby/source.mp4", Self.videoBytes),
                ("audio", "audio.wav", "audio/noBeat/baby/source.wav", Data("audio fixture".utf8)),
                ("model", "model.mlmodel", "models/source.mlmodel", Data("model fixture".utf8))
            ]
            var assets: [[String: Any]] = []
            for (role, filename, original, data) in sources {
                try data.write(to: root.appendingPathComponent("assets/" + filename))
                assets.append(["id": role, "relativePath": "assets/" + filename,
                               "originalRelativePath": original, "role": role,
                               "sha256": Self.digest(data), "byteCount": data.count])
            }
            let manifest: [String: Any] = [
                "schema": "scratchlab_reference_examples_v1", "id": "test-library", "title": "Examples",
                "selection": "One original performance", "sourceManifestSHA256": String(repeating: "a", count: 64),
                "limitations": ["Source labels and synchronization remain unverified."], "assets": assets,
                "examples": [["id": "pro-dj-v1:baby:79:take01", "classLabel": "baby", "bpm": 79,
                              "take": "take01", "labelStatus": "sourceLabelUnreviewed", "canonicalApproval": false,
                              "angles": [["id": "angle_1", "videoAssetID": "video"]],
                              "audioAssetIDs": ["noBeat": "audio", "withBeat": "audio", "beatOnly": "audio"]]],
                "models": [["assetID": "model", "modality": "audio", "advisoryOnly": true,
                            "evaluationStatus": "unseenPerformanceAccuracyUnverified"]]
            ]
            try writeManifest(manifest)
        }

        func rewrite(_ mutate: (inout [String: Any]) -> Void) throws {
            let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            mutate(&manifest)
            try writeManifest(manifest)
        }

        private func writeManifest(_ manifest: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent("manifest.json"))
            try (Self.digest(data) + "\n").write(to: root.appendingPathComponent("manifest.sha256"), atomically: true, encoding: .utf8)
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
