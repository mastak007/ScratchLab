import CryptoKit
import Foundation

/// Source-labelled examples and advisory models, independent of approved references.
/// A valid catalogue proves file identity, never canonical approval or model accuracy.
struct ScratchExampleLibrary: Sendable {
    struct Manifest: Codable, Sendable {
        let schema: String
        let id: String
        let title: String
        let selection: String
        let sourceManifestSHA256: String
        let limitations: [String]
        let examples: [Example]
        let assets: [Asset]
        let models: [Model]
    }

    struct Example: Codable, Sendable, Identifiable {
        let id: String
        let classLabel: String
        let bpm: Int
        let take: String
        let labelStatus: String
        let canonicalApproval: Bool
        let angles: [Angle]
        let audioAssetIDs: [String: String]
    }

    struct Angle: Codable, Sendable, Identifiable {
        let id: String
        let videoAssetID: String
        let handCacheAssetID: String?
    }

    struct Asset: Codable, Sendable, Identifiable {
        let id: String
        let relativePath: String
        let originalRelativePath: String
        let role: String
        let sha256: String
        let byteCount: Int64
    }

    struct Model: Codable, Sendable, Identifiable {
        let assetID: String
        let modality: String
        let evaluationStatus: String
        let advisoryOnly: Bool
        var id: String { assetID }
    }

    enum LibraryError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let detail): return "Reference examples: \(detail)"
            }
        }
    }

    let manifest: Manifest
    private let rootURL: URL
    private let assetsByID: [String: Asset]

    static func loadBundled(bundle: Bundle = .main) async throws -> ScratchExampleLibrary {
        guard let root = bundle.resourceURL?.appendingPathComponent("ReferenceExamples", isDirectory: true) else {
            throw LibraryError.invalid("the bundled library is unavailable.")
        }
        return try await load(rootURL: root)
    }

    static func load(rootURL: URL) async throws -> ScratchExampleLibrary {
        try await Task.detached(priority: .utility) {
            guard rootURL.isFileURL else {
                throw LibraryError.invalid("the library must be a local folder.")
            }
            let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
            let manifestURL = try containedURL("manifest.json", root: root)
            let checksumURL = try containedURL("manifest.sha256", root: root)
            try requireRegularFile(manifestURL)
            try requireRegularFile(checksumURL)
            let bytes = try Data(contentsOf: manifestURL)
            let expected = try String(contentsOf: checksumURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard validSHA256(expected), digest(bytes) == expected else {
                throw LibraryError.invalid("the catalogue checksum does not match.")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
            try validate(manifest, root: root)
            return ScratchExampleLibrary(
                manifest: manifest,
                rootURL: root,
                assetsByID: Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
            )
        }.value
    }

    /// Rechecks the selected original every time, so a replacement after loading
    /// cannot inherit an earlier verification. The work stays off the UI actor.
    func verifiedURL(assetID: String) async throws -> URL {
        guard let asset = assetsByID[assetID] else {
            throw LibraryError.invalid("the requested asset is not in the catalogue.")
        }
        let root = rootURL
        return try await Task.detached(priority: .utility) {
            let url = try Self.containedURL(asset.relativePath, root: root)
            try Self.requireRegularFile(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var byteCount: Int64 = 0
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                byteCount += Int64(chunk.count)
                guard byteCount <= asset.byteCount else {
                    throw LibraryError.invalid("asset size changed: \(asset.id).")
                }
                hasher.update(data: chunk)
            }
            guard byteCount == asset.byteCount,
                  hasher.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw LibraryError.invalid("asset checksum or size changed: \(asset.id).")
            }
            // Resolve again before returning: a symlink replacement must not
            // turn a previously contained selection into an outside URL.
            guard try Self.containedURL(asset.relativePath, root: root) == url else {
                throw LibraryError.invalid("the asset path changed during verification.")
            }
            return url
        }.value
    }

    private static func validate(_ manifest: Manifest, root: URL) throws {
        guard manifest.schema == "scratchlab_reference_examples_v1",
              !manifest.id.isEmpty, !manifest.title.isEmpty, !manifest.selection.isEmpty,
              validSHA256(manifest.sourceManifestSHA256),
              !manifest.limitations.isEmpty, manifest.limitations.allSatisfy({ !$0.isEmpty }),
              !manifest.examples.isEmpty, !manifest.assets.isEmpty else {
            throw LibraryError.invalid("unsupported or incomplete catalogue metadata.")
        }
        try requireUnique(manifest.assets.map(\.id), field: "asset IDs")
        try requireUnique(manifest.assets.map(\.relativePath), field: "asset paths")
        try requireUnique(manifest.examples.map(\.id), field: "example IDs")
        try requireUnique(manifest.models.map(\.assetID), field: "model IDs")
        try requireUnique(manifest.models.map(\.modality), field: "model modalities")
        for asset in manifest.assets {
            guard ["video", "audio", "handCache", "model"].contains(asset.role),
                  validSHA256(asset.sha256), asset.byteCount > 0 else {
                throw LibraryError.invalid("invalid asset metadata: \(asset.id).")
            }
            _ = try containedURL(asset.relativePath, root: root)
            try requireRelativePath(asset.originalRelativePath)
        }
        let assets = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        func requireAsset(_ id: String, role: String) throws {
            guard assets[id]?.role == role else {
                throw LibraryError.invalid("missing asset or incorrect role: \(id).")
            }
        }
        for example in manifest.examples {
            guard ScratchClassLabel(rawValue: example.classLabel) != nil,
                  example.bpm > 0, example.take.hasPrefix("take"),
                  example.take.dropFirst(4).allSatisfy(\.isNumber),
                  (Int(example.take.dropFirst(4)) ?? 0) > 0,
                  example.id == "pro-dj-v1:\(example.classLabel):\(example.bpm):\(example.take)",
                  example.labelStatus == "sourceLabelUnreviewed", !example.canonicalApproval,
                  !example.angles.isEmpty,
                  Set(example.audioAssetIDs.keys) == Set(["noBeat", "withBeat", "beatOnly"]) else {
                throw LibraryError.invalid("unsupported example identity or approval state: \(example.id).")
            }
            try requireUnique(example.angles.map(\.id), field: "camera angles")
            for angle in example.angles {
                guard ["angle_1", "angle_2", "angle_3", "angle_4"].contains(angle.id) else {
                    throw LibraryError.invalid("unknown camera angle: \(angle.id).")
                }
                try requireAsset(angle.videoAssetID, role: "video")
                if let handCacheID = angle.handCacheAssetID {
                    try requireAsset(handCacheID, role: "handCache")
                }
            }
            for id in example.audioAssetIDs.values { try requireAsset(id, role: "audio") }
        }
        for model in manifest.models {
            guard ["audio", "motion"].contains(model.modality), model.advisoryOnly,
                  model.evaluationStatus == "unseenPerformanceAccuracyUnverified" else {
                throw LibraryError.invalid("unsupported model role or evaluation status.")
            }
            try requireAsset(model.assetID, role: "model")
        }
    }

    private static func requireUnique(_ values: [String], field: String) throws {
        guard values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count else {
            throw LibraryError.invalid("empty or duplicate \(field).")
        }
    }

    private static func requireRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw LibraryError.invalid("unsafe relative asset path.")
        }
    }

    private static func containedURL(_ path: String, root: URL) throws -> URL {
        try requireRelativePath(path)
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw LibraryError.invalid("an asset path escapes the library folder.")
        }
        return url
    }

    private static func requireRegularFile(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryError.invalid("the requested library file is unavailable.")
        }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
