import Foundation
import Testing

/// Structural tests for the bundled reference-audio folders consumed by
/// `ScratchAnalyzer.loadReferenceSamples()`.
///
/// These tests do **not** import `ScratchAnalyzer` itself (the desktop test
/// target does not compile that file). Instead they read the source file
/// and the on-disk Resources tree to verify three contracts:
///
/// 1. The folder names baked into `ScratchAnalyzer.swift` match the actual
///    folder names under `ScratchLab/Resources/`.
/// 2. The beginner reference folder no longer ships any `karl_qb_*` files.
/// 3. The reference folder names and their contents do not leak any
///    blocklisted source/provenance tokens into the app bundle.
struct ScratchAnalyzerReferenceFoldersTests {

    // MARK: - Filesystem layout

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ScratchLabDesktopTests
            .deletingLastPathComponent()  // repo root
    }

    private static var analyzerSourceURL: URL {
        repoRoot
            .appendingPathComponent("ScratchLab/Audio/ScratchAnalyzer.swift")
    }

    private static func resourcesFolder(_ name: String) -> URL {
        repoRoot.appendingPathComponent("ScratchLab/Resources/\(name)")
    }

    private static func wavFiles(in folder: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: - Constants in source match disk

    @Test("ScratchAnalyzer.swift uses the on-disk reference folder names")
    func loaderUsesOnDiskFolderNames() throws {
        let source = try String(
            contentsOf: Self.analyzerSourceURL,
            encoding: .utf8
        )

        // The three folder names that exist on disk MUST be present in the
        // source so the loader actually finds them.
        #expect(source.contains("\"reference_pro\""))
        #expect(source.contains("\"reference_champ\""))
        #expect(source.contains("\"reference_beginner\""))
    }

    @Test("ScratchAnalyzer.swift no longer references the legacy folder names")
    func loaderDoesNotReferenceLegacyFolderNames() throws {
        let source = try String(
            contentsOf: Self.analyzerSourceURL,
            encoding: .utf8
        )

        // These are the historical names that did not match the actual
        // folder layout. They must not be re-introduced.
        #expect(!source.contains("\"pro_reference\""))
        #expect(!source.contains("\"advanced_reference\""))
        #expect(!source.contains("\"learner_reference\""))
    }

    // MARK: - reference_beginner content

    @Test("reference_beginner folder contains the expected karl_beginner WAV set")
    func beginnerFolderContainsExpectedFiles() throws {
        let folder = Self.resourcesFolder("reference_beginner")
        let wavs = try Self.wavFiles(in: folder)

        let expected = [
            "karl_beginner_01.wav",
            "karl_beginner_02.wav",
            "karl_beginner_03.wav",
            "karl_beginner_04.wav",
            "karl_beginner_05.wav",
            "karl_beginner_06.wav",
            "karl_beginner_07.wav",
            "karl_beginner_08.wav",
            "karl_beginner_09.wav",
            "karl_beginner_10.wav",
            "karl_beginner_11.wav",
            "karl_beginner_12.wav",
            "karl_beginner_13.wav",
            "karl_beginner_14.wav",
            "karl_beginner_15.wav",
            "karl_beginner_16.wav",
            "karl_beginner_19.wav",
        ]
        #expect(wavs == expected)
    }

    @Test("reference_beginner folder no longer contains any karl_qb_* files")
    func beginnerFolderHasNoQbFiles() throws {
        let folder = Self.resourcesFolder("reference_beginner")
        let wavs = try Self.wavFiles(in: folder)
        let leftovers = wavs.filter { $0.lowercased().contains("qb_") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Other reference folders are non-empty

    @Test("reference_champ folder contains the expected cxl_clean WAV set")
    func champFolderContainsExpectedFiles() throws {
        let folder = Self.resourcesFolder("reference_champ")
        let wavs = try Self.wavFiles(in: folder)
        let expected = [
            "cxl_clean_01.wav",
            "cxl_clean_02.wav",
            "cxl_clean_03.wav",
            "cxl_clean_04.wav",
        ]
        #expect(wavs == expected)
    }

    @Test("reference_pro folder is not empty")
    func proFolderIsNotEmpty() throws {
        let folder = Self.resourcesFolder("reference_pro")
        let wavs = try Self.wavFiles(in: folder)
        #expect(!wavs.isEmpty)
    }

    // MARK: - Bundled-resource safety

    @Test("Reference folders contain only WAV audio files (no provenance docs)")
    func referenceFoldersContainOnlyAudio() throws {
        for name in ["reference_pro", "reference_champ", "reference_beginner"] {
            let folder = Self.resourcesFolder(name)
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            let nonWav = contents
                .filter { url in
                    url.pathExtension.lowercased() != "wav"
                        // Allow the macOS Finder metadata file even if
                        // present locally — it is excluded by .gitignore.
                        && url.lastPathComponent != ".DS_Store"
                }
            #expect(nonWav.isEmpty)
        }
    }

    @Test("Reference folder names and WAV filenames contain no blocklisted tokens")
    func referenceFolderNamesAreSafe() throws {
        // Tokens that must never appear in folder or filename surfaces of
        // the bundled reference audio.
        let bannedTokens = [
            "MakeMKV",
            "processed_makemkv",
            "sourceMKV",
            "sourceDVD",
            "QBERT",
            "Qbert",
            "SXRATCH",
            "rightsStatus",
            "reviewStatus",
            "karlwatson",
            "Karl Watson",
        ]
        // Note: a more aggressive scan also rejects "qb_" — see
        // beginnerFolderHasNoQbFiles for that contract on the beginner
        // folder specifically. The other folders are not constrained here
        // because pre-existing app-shipped audio there is out of scope.

        for name in ["reference_pro", "reference_champ", "reference_beginner"] {
            for token in bannedTokens {
                #expect(
                    !name.contains(token),
                    "folder name \(name) must not contain blocklisted token \(token)"
                )
            }

            let folder = Self.resourcesFolder(name)
            let wavs = try Self.wavFiles(in: folder)
            for wav in wavs {
                for token in bannedTokens {
                    #expect(
                        !wav.contains(token),
                        "wav \(name)/\(wav) must not contain blocklisted token \(token)"
                    )
                }
            }
        }
    }
}
