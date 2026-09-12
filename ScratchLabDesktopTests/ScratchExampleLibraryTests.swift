import CryptoKit
import XCTest
@testable import ScratchLab

final class ScratchExampleLibraryTests: XCTestCase {
    func testBundledCatalogueContainsCompleteUnapprovedExamplesAndVerifiedAssets() async throws {
        let library = try await ScratchExampleLibrary.loadBundled()
        let examples = library.manifest.examples
        XCTAssertFalse(examples.isEmpty)
        XCTAssertEqual(Set(examples.map(\.classLabel)).count, examples.count)
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
            ("schema", { $0["schema"] = "scratchlab_reference_examples_v2" }),
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
