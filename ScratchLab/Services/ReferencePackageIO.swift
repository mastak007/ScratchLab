// ReferencePackageIO — writes and reads reference packages on disk.
//
// Shared by iOS and macOS: macOS authors packages, iOS reads and verifies the
// ones a build installed. Both sides use the same hashing and the same layout,
// which is what makes "does this package still match its manifest?" the same
// question in both places.
//
// Writing is transactional. The package is assembled in a scratch directory
// and moved into place only once every artifact is written and hashed, so an
// interrupted export leaves no half-package that the import step might mistake
// for a real one.

import Foundation
import CryptoKit

enum ReferencePackageIOError: LocalizedError, Equatable {
    case sourceArtifactMissing(role: String, path: String)
    case couldNotCreatePackage(String)
    case manifestUnreadable(String)
    case packageRejected([String])

    var errorDescription: String? {
        switch self {
        case .sourceArtifactMissing(let role, let path):
            return "Cannot build the reference package: the \(role) artifact is missing at \(path)."
        case .couldNotCreatePackage(let detail):
            return "Cannot build the reference package: \(detail)"
        case .manifestUnreadable(let detail):
            return "Cannot read the reference package manifest: \(detail)"
        case .packageRejected(let issues):
            return issues.joined(separator: "\n")
        }
    }
}

/// One artifact to place into a package.
struct ReferencePackageInput {
    let role: ReferenceArtifactRecord.Role
    /// Package-relative destination, e.g. `"audio/reference.wav"`.
    let packagePath: String
    /// Either a file to copy, or bytes to write. Exactly one is set.
    let sourceURL: URL?
    let data: Data?

    init(role: ReferenceArtifactRecord.Role, packagePath: String, sourceURL: URL) {
        self.role = role
        self.packagePath = packagePath
        self.sourceURL = sourceURL
        self.data = nil
    }

    init(role: ReferenceArtifactRecord.Role, packagePath: String, data: Data) {
        self.role = role
        self.packagePath = packagePath
        self.sourceURL = nil
        self.data = data
    }
}

enum ReferencePackageIO {

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Write

    /// Assemble a package directory under `parentDirectory`.
    ///
    /// `makeManifest` receives the artifact records produced from `inputs` and
    /// returns the finished manifest. Taking a closure rather than a manifest
    /// keeps hashing here — the caller cannot hand in stale hashes, because it
    /// never computes any.
    @discardableResult
    static func writePackage(
        inputs: [ReferencePackageInput],
        parentDirectory: URL,
        packageDirectoryName: String,
        makeManifest: ([ReferenceArtifactRecord]) -> ReferencePackageManifest,
        fileManager: FileManager = .default
    ) throws -> URL {
        let stagingURL = parentDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let finalURL = parentDirectory
            .appendingPathComponent(packageDirectoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            throw ReferencePackageIOError.couldNotCreatePackage(error.localizedDescription)
        }
        // A staging directory that survives a throw would accumulate on every
        // failed export.
        defer { try? fileManager.removeItem(at: stagingURL) }

        var records: [ReferenceArtifactRecord] = []
        for input in inputs {
            let destination = stagingURL.appendingPathComponent(input.packagePath)
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw ReferencePackageIOError.couldNotCreatePackage(error.localizedDescription)
            }

            let bytes: Data
            if let data = input.data {
                bytes = data
                do {
                    try data.write(to: destination, options: .atomic)
                } catch {
                    throw ReferencePackageIOError.couldNotCreatePackage(error.localizedDescription)
                }
            } else if let sourceURL = input.sourceURL {
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw ReferencePackageIOError.sourceArtifactMissing(
                        role: input.role.rawValue,
                        path: sourceURL.lastPathComponent
                    )
                }
                do {
                    try fileManager.copyItem(at: sourceURL, to: destination)
                    bytes = try Data(contentsOf: destination)
                } catch {
                    throw ReferencePackageIOError.couldNotCreatePackage(error.localizedDescription)
                }
            } else {
                throw ReferencePackageIOError.sourceArtifactMissing(
                    role: input.role.rawValue,
                    path: input.packagePath
                )
            }

            records.append(
                ReferenceArtifactRecord(
                    path: input.packagePath,
                    byteCount: Int64(bytes.count),
                    sha256: sha256Hex(bytes),
                    role: input.role
                )
            )
        }

        let manifest = makeManifest(records)
        let manifestIssues = ReferencePackageValidator.manifestIssues(manifest)
        guard manifestIssues.isEmpty else {
            throw ReferencePackageIOError.packageRejected(manifestIssues.map(\.message))
        }

        do {
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: stagingURL.appendingPathComponent(ReferencePackageManifest.fileName),
                options: .atomic
            )
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        } catch let error as ReferencePackageIOError {
            throw error
        } catch {
            throw ReferencePackageIOError.couldNotCreatePackage(error.localizedDescription)
        }
        return finalURL
    }

    // MARK: - Read

    static func readManifest(
        atPackageURL packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> ReferencePackageManifest {
        let manifestURL = packageURL.appendingPathComponent(ReferencePackageManifest.fileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ReferencePackageIOError.manifestUnreadable(
                "\(ReferencePackageManifest.fileName) is not in \(packageURL.lastPathComponent)."
            )
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try decoder.decode(ReferencePackageManifest.self, from: data)
        } catch {
            throw ReferencePackageIOError.manifestUnreadable(
                SessionExportFailureText.describe(error)
            )
        }
    }

    /// Measure every artifact the manifest declares, for the hash check.
    ///
    /// A declared file that is absent yields NO measurement, which
    /// `ReferencePackageValidator.artifactIssues` reports as a missing file.
    /// It never yields a zero-byte measurement, which would read as a
    /// corruption rather than an absence.
    static func measureArtifacts(
        manifest: ReferencePackageManifest,
        packageURL: URL,
        fileManager: FileManager = .default
    ) -> [String: (byteCount: Int64, sha256: String)] {
        var measurements: [String: (byteCount: Int64, sha256: String)] = [:]
        for artifact in manifest.artifacts {
            let url = packageURL.appendingPathComponent(artifact.path)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { continue }
            measurements[artifact.path] = (Int64(data.count), sha256Hex(data))
        }
        return measurements
    }

    /// Full verification: manifest checks plus on-disk hash checks.
    /// An empty array means the package may be imported.
    static func verify(
        packageURL: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let manifest: ReferencePackageManifest
        do {
            manifest = try readManifest(atPackageURL: packageURL, fileManager: fileManager)
        } catch {
            return [(error as? LocalizedError)?.errorDescription
                ?? "Reference package manifest could not be read."]
        }
        var issues = ReferencePackageValidator.manifestIssues(manifest).map(\.message)
        let measurements = measureArtifacts(
            manifest: manifest,
            packageURL: packageURL,
            fileManager: fileManager
        )
        issues.append(
            contentsOf: ReferencePackageValidator
                .artifactIssues(manifest, measurements: measurements)
                .map(\.message)
        )
        return issues
    }
}
