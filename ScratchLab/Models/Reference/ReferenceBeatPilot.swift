import AVFoundation
import CryptoKit
import Foundation

/// An unapproved, procedural CXL beat candidate. These descriptions are data
/// only; the generated assets live outside bundle resources until a human
/// listening/Rane pilot approves one.
struct ReferenceBeatPilotRecipe: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = "scratchlab_cxl_beat_pilot_recipe_v1"

    let id: String
    let family: String
    let bpm: Int
    let feel: ReferenceBeatFeel
    let engineMode: BeatEngineMode

    var version: Int { 1 }
    var countInBeats: Int { 4 }
    var loopBeats: Int { 16 }
    var sampleRate: Int { 48_000 }
    var channels: Int { 2 }
}

enum ReferenceBeatPilotCatalog {
    static let six: [ReferenceBeatPilotRecipe] = [
        .init(id: "boom_bap_straight_80", family: "boom-bap", bpm: 80, feel: .straight, engineMode: .boomBapTrainer),
        .init(id: "boom_bap_swing_90", family: "boom-bap", bpm: 90, feel: .swing, engineMode: .minimalFunk),
        .init(id: "funk_break_straight_90", family: "funk-break", bpm: 90, feel: .straight, engineMode: .battleLoop),
        .init(id: "funk_light_swing_100", family: "funk", bpm: 100, feel: .lightSwing, engineMode: .minimalFunk),
        .init(id: "electro_straight_110", family: "electro", bpm: 110, feel: .straight, engineMode: .boomBapTrainer),
        .init(id: "half_time_80", family: "half-time", bpm: 80, feel: .halfTime, engineMode: .battleLoop)
    ]
}

struct ReferenceBeatPilotArtifact: Codable, Equatable, Sendable {
    let fileName: String
    let sha256: String
    let role: String
}

struct ReferenceBeatPilotRightsReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = "scratchlab_cxl_beat_rights_v1"
    let schemaVersion: String
    let candidateID: String
    let rightsState: ReferenceBeatRightsState
    let source: String
    let externalRecordingUsed: Bool
}

struct ReferenceBeatPilotManifest: Codable, Equatable, Sendable {
    static let schemaVersion = "scratchlab_cxl_beat_pilot_manifest_v1"
    let schemaVersion: String
    let approvalState: String
    let recipe: ReferenceBeatPilotRecipe
    let countInFrameCount: Int64
    let loopStartFrame: Int64
    let loopFrameCount: Int64
    let totalFrameCount: Int64
    let productionMaster: ReferenceBeatPilotArtifact
    let sparseAnalysisMix: ReferenceBeatPilotArtifact
    let stems: [ReferenceBeatPilotArtifact]
    let rightsReceipt: ReferenceBeatPilotArtifact

    var binding: ReferenceBeatSpecBinding {
        ReferenceBeatSpecBinding(
            id: recipe.id,
            version: recipe.version,
            family: recipe.family,
            bpm: recipe.bpm,
            feel: recipe.feel,
            countInFrameCount: countInFrameCount,
            loopStartFrame: loopStartFrame,
            loopFrameCount: loopFrameCount,
            sampleRate: recipe.sampleRate,
            productionMasterFileName: productionMaster.fileName,
            productionMasterSHA256: productionMaster.sha256,
            sparseAnalysisMixFileName: sparseAnalysisMix.fileName,
            sparseAnalysisMixSHA256: sparseAnalysisMix.sha256,
            availableStemSHA256: Dictionary(uniqueKeysWithValues: stems.map { ($0.fileName, $0.sha256) }),
            rightsState: .procedurallyGeneratedOriginal,
            provenance: "Rendered locally by ScratchLabBeatEngine; no external recording or sample was used."
        )
    }
}

enum ReferenceBeatPilotGenerator {
    static func generateAll(at root: URL, fileManager: FileManager = .default) throws -> [ReferenceBeatPilotManifest] {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return try ReferenceBeatPilotCatalog.six.map { try generate($0, at: root, fileManager: fileManager) }
    }

    static func generate(
        _ recipe: ReferenceBeatPilotRecipe,
        at root: URL,
        fileManager: FileManager = .default
    ) throws -> ReferenceBeatPilotManifest {
        let directory = root.appendingPathComponent(recipe.id, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let beatFrames = Int64((60.0 / Double(recipe.bpm) * Double(recipe.sampleRate)).rounded())
        let countInFrames = beatFrames * Int64(recipe.countInBeats)
        let loopFrames = beatFrames * Int64(recipe.loopBeats)
        let totalFrames = countInFrames + loopFrames
        let duration = Double(totalFrames) / Double(recipe.sampleRate)

        let masterURL = directory.appendingPathComponent("production_master.wav")
        let analysisURL = directory.appendingPathComponent("sparse_analysis.wav")
        let stemURL = directory.appendingPathComponent("beat_only.wav")

        let master = try ScratchLabBeatEngine.renderedTimingBuffer(
            mode: recipe.engineMode,
            bpm: recipe.bpm,
            durationSeconds: duration,
            countInBeats: recipe.countInBeats,
            beatsPerBar: 4,
            clickStartHostTime: nil,
            recordingStartHostTime: nil,
            sampleRate: Double(recipe.sampleRate),
            channelCount: AVAudioChannelCount(recipe.channels),
            exactFrameCount: AVAudioFrameCount(totalFrames)
        )
        let sparse = try ScratchLabBeatEngine.renderedTimingBuffer(
            mode: .clickTrack,
            bpm: recipe.bpm,
            durationSeconds: duration,
            countInBeats: recipe.countInBeats,
            beatsPerBar: 4,
            clickStartHostTime: nil,
            recordingStartHostTime: nil,
            sampleRate: Double(recipe.sampleRate),
            channelCount: AVAudioChannelCount(recipe.channels),
            exactFrameCount: AVAudioFrameCount(totalFrames)
        )

        try writePCM16(master, to: masterURL)
        try writePCM16(sparse, to: analysisURL)
        try writePCM16(master, to: stemURL)

        let receipt = ReferenceBeatPilotRightsReceipt(
            schemaVersion: ReferenceBeatPilotRightsReceipt.schemaVersion,
            candidateID: recipe.id,
            rightsState: .procedurallyGeneratedOriginal,
            source: "ScratchLabBeatEngine deterministic procedural synthesis",
            externalRecordingUsed: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let receiptURL = directory.appendingPathComponent("rights_receipt.json")
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)

        let manifest = ReferenceBeatPilotManifest(
            schemaVersion: ReferenceBeatPilotManifest.schemaVersion,
            approvalState: "unapproved_pilot_candidate",
            recipe: recipe,
            countInFrameCount: countInFrames,
            loopStartFrame: countInFrames,
            loopFrameCount: loopFrames,
            totalFrameCount: totalFrames,
            productionMaster: artifact(masterURL, role: "production_master"),
            sparseAnalysisMix: artifact(analysisURL, role: "sparse_analysis"),
            stems: [artifact(stemURL, role: "procedural_beat_stem")],
            rightsReceipt: artifact(receiptURL, role: "rights_receipt")
        )
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return manifest
    }

    private static func writePCM16(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: Int(buffer.format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private static func artifact(_ url: URL, role: String) -> ReferenceBeatPilotArtifact {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return ReferenceBeatPilotArtifact(
            fileName: url.lastPathComponent,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            role: role
        )
    }
}

/// The immutable asset set prepared before a capture intent is frozen.
/// This is separate from the six historical, unapproved listening pilots.
struct ReferencePreparedBeat: Equatable, Sendable {
    let binding: ReferenceBeatSpecBinding
    let mode: BeatEngineMode
    let directoryURL: URL

    var productionMasterURL: URL { directoryURL.appendingPathComponent(binding.productionMasterFileName) }
    var sparseAnalysisURL: URL { directoryURL.appendingPathComponent(binding.sparseAnalysisMixFileName) }
    var rightsReceiptURL: URL { directoryURL.appendingPathComponent("rights_receipt.json") }
    var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }
}

enum ReferenceBeatAssetError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "The exact beat assets could not be verified: \(detail)"
        }
    }
}

enum ReferenceBeatAssetStore {
    static let sampleRate = 48_000
    static let channels = 2
    private static let assetVersion = 2
    private static let schemaVersion = "scratchlab_runtime_beat_assets_v2"
    private static let provenance = "ScratchLab runtime asset v2: four procedural clicks followed by the selected procedural pattern; no external recording or sample was used."

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("ReferenceBeatAssets", isDirectory: true)
    }

    private struct Manifest: Codable, Equatable {
        let schemaVersion: String
        let mode: BeatEngineMode
        let loopBeats: Int
        let channels: Int
        let binding: ReferenceBeatSpecBinding
        let rightsReceipt: ReferenceBeatPilotArtifact
    }

    static func prepare(
        mode: BeatEngineMode,
        bpm: Int,
        loopBeats: Int = 16,
        rootURL: URL? = nil
    ) throws -> ReferencePreparedBeat {
        try validateConfiguration(mode: mode, bpm: bpm, loopBeats: loopBeats)
        let root = rootURL ?? defaultRootURL
        let id = identifier(mode: mode, bpm: bpm, loopBeats: loopBeats)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let manifest = try readManifest(at: destination)
            guard manifest.mode == mode, manifest.loopBeats == loopBeats,
                  manifest.binding.id == id, manifest.binding.bpm == bpm else {
                throw ReferenceBeatAssetError.invalid("the existing manifest does not match Setup")
            }
            return try resolve(binding: manifest.binding, rootURL: root)
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let beatFrames = Int64((60.0 / Double(bpm) * Double(sampleRate)).rounded())
        let countInFrames = beatFrames * 4
        let loopFrames = beatFrames * Int64(loopBeats)
        let countIn = try ClickTrackEngine.renderedClickTrackBuffer(
            bpm: bpm, durationSeconds: Double(countInFrames) / Double(sampleRate),
            sampleRate: Double(sampleRate), channelCount: AVAudioChannelCount(channels),
            startBeatIndex: 0, exactFrameCount: AVAudioFrameCount(countInFrames)
        )
        let loop = try ScratchLabBeatEngine.renderedTimingBuffer(
            mode: mode, bpm: bpm, durationSeconds: Double(loopFrames) / Double(sampleRate),
            countInBeats: 0, beatsPerBar: 4, clickStartHostTime: nil, recordingStartHostTime: nil,
            sampleRate: Double(sampleRate), channelCount: AVAudioChannelCount(channels),
            exactFrameCount: AVAudioFrameCount(loopFrames)
        )
        let sparseLoop = try ClickTrackEngine.renderedClickTrackBuffer(
            bpm: bpm, durationSeconds: Double(loopFrames) / Double(sampleRate),
            sampleRate: Double(sampleRate), channelCount: AVAudioChannelCount(channels),
            startBeatIndex: 0, exactFrameCount: AVAudioFrameCount(loopFrames)
        )
        let masterURL = staging.appendingPathComponent("production_master.wav")
        let sparseURL = staging.appendingPathComponent("sparse_analysis.wav")
        // Write two consecutive buffers into one file. The pattern cannot bleed
        // into the four-click count-in, or reset its phase at the first drum hit.
        try writePCM16([countIn, loop], to: masterURL)
        try writePCM16([countIn, sparseLoop], to: sparseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let receiptURL = staging.appendingPathComponent("rights_receipt.json")
        let receipt = ReferenceBeatPilotRightsReceipt(
            schemaVersion: ReferenceBeatPilotRightsReceipt.schemaVersion,
            candidateID: id, rightsState: .procedurallyGeneratedOriginal,
            source: provenance, externalRecordingUsed: false
        )
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        let binding = ReferenceBeatSpecBinding(
            id: id, version: assetVersion, family: mode.beatPatternName ?? "click-track", bpm: bpm,
            feel: mode == .minimalFunk ? .lightSwing : .straight,
            countInFrameCount: countInFrames, loopStartFrame: countInFrames,
            loopFrameCount: loopFrames, sampleRate: sampleRate,
            productionMasterFileName: masterURL.lastPathComponent,
            productionMasterSHA256: try sha256(masterURL),
            sparseAnalysisMixFileName: sparseURL.lastPathComponent,
            sparseAnalysisMixSHA256: try sha256(sparseURL),
            availableStemSHA256: [:], rightsState: .procedurallyGeneratedOriginal,
            provenance: provenance
        )
        let manifest = Manifest(
            schemaVersion: schemaVersion, mode: mode, loopBeats: loopBeats, channels: channels,
            binding: binding,
            rightsReceipt: .init(fileName: receiptURL.lastPathComponent,
                                 sha256: try sha256(receiptURL), role: "rights_receipt")
        )
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try validate(manifest, binding: binding, directory: staging)
        do {
            // moveItem refuses an existing destination; bound bytes are never
            // replaced, including when another preparer wins publication.
            try fm.moveItem(at: staging, to: destination)
        } catch {
            guard fm.fileExists(atPath: destination.path) else { throw error }
            return try resolve(binding: binding, rootURL: root)
        }
        return try resolve(binding: binding, rootURL: root)
    }

    static func resolve(binding: ReferenceBeatSpecBinding, rootURL: URL? = nil) throws -> ReferencePreparedBeat {
        guard !binding.id.isEmpty, binding.id != ".", binding.id != "..",
              !binding.id.contains("/"), !binding.id.contains("\\") else {
            throw ReferenceBeatAssetError.invalid("the asset identifier is not a directory name")
        }
        let directory = (rootURL ?? defaultRootURL).appendingPathComponent(binding.id, isDirectory: true)
        let manifest = try readManifest(at: directory)
        try validate(manifest, binding: binding, directory: directory)
        return ReferencePreparedBeat(binding: binding, mode: manifest.mode, directoryURL: directory)
    }

    private static func identifier(mode: BeatEngineMode, bpm: Int, loopBeats: Int) -> String {
        "cxl_runtime_v2_\(mode.rawValue)_\(bpm)bpm_\(loopBeats)beats_48000_stereo"
    }

    private static func validateConfiguration(mode: BeatEngineMode, bpm: Int, loopBeats: Int) throws {
        guard BeatEngineMode.practiceModes.contains(mode), bpm == CaptureClickTrackDefaults.clampedBPM(bpm),
              loopBeats >= 4, loopBeats <= 256, loopBeats.isMultiple(of: 4) else {
            throw ReferenceBeatAssetError.invalid("unsupported pattern, BPM or whole-bar loop length")
        }
    }

    private static func readManifest(at directory: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private static func validate(_ manifest: Manifest, binding: ReferenceBeatSpecBinding, directory: URL) throws {
        try validateConfiguration(mode: manifest.mode, bpm: binding.bpm, loopBeats: manifest.loopBeats)
        let beatFrames = Int64((60.0 / Double(binding.bpm) * Double(sampleRate)).rounded())
        guard manifest.schemaVersion == schemaVersion, manifest.channels == channels,
              manifest.binding == binding, binding.schemaVersion == ReferenceBeatSpecBinding.currentSchemaVersion,
              binding.id == identifier(mode: manifest.mode, bpm: binding.bpm, loopBeats: manifest.loopBeats),
              binding.version == assetVersion, binding.sampleRate == sampleRate,
              binding.timeSignatureNumerator == 4, binding.timeSignatureDenominator == 4,
              binding.countInFrameCount == beatFrames * 4, binding.loopStartFrame == binding.countInFrameCount,
              binding.loopFrameCount == beatFrames * Int64(manifest.loopBeats),
              binding.family == (manifest.mode.beatPatternName ?? "click-track"),
              binding.feel == (manifest.mode == .minimalFunk ? .lightSwing : .straight),
              binding.mixRole == .productionMaster, binding.rightsState == .procedurallyGeneratedOriginal,
              binding.provenance == provenance, binding.availableStemSHA256.isEmpty,
              binding.productionMasterFileName == "production_master.wav",
              binding.sparseAnalysisMixFileName == "sparse_analysis.wav",
              manifest.rightsReceipt.fileName == "rights_receipt.json",
              manifest.rightsReceipt.role == "rights_receipt" else {
            throw ReferenceBeatAssetError.invalid("manifest configuration or frame boundaries do not match the binding")
        }
        let totalFrames = binding.countInFrameCount + binding.loopFrameCount
        for (fileName, hash) in [(binding.productionMasterFileName, binding.productionMasterSHA256),
                                  (binding.sparseAnalysisMixFileName, binding.sparseAnalysisMixSHA256)] {
            let url = directory.appendingPathComponent(fileName)
            guard try sha256(url) == hash else {
                throw ReferenceBeatAssetError.invalid("\(fileName) has changed")
            }
            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat
            guard file.length == totalFrames, format.sampleRate == Double(sampleRate),
                  format.channelCount == AVAudioChannelCount(channels),
                  format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                  format.streamDescription.pointee.mBitsPerChannel == 16,
                  format.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat == 0 else {
                throw ReferenceBeatAssetError.invalid("\(fileName) has an unexpected WAV format or frame count")
            }
        }
        let receiptURL = directory.appendingPathComponent(manifest.rightsReceipt.fileName)
        guard try sha256(receiptURL) == manifest.rightsReceipt.sha256 else {
            throw ReferenceBeatAssetError.invalid("the rights receipt has changed")
        }
        let receipt = try JSONDecoder().decode(ReferenceBeatPilotRightsReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.schemaVersion == ReferenceBeatPilotRightsReceipt.schemaVersion,
              receipt.candidateID == binding.id, receipt.rightsState == binding.rightsState,
              receipt.source == provenance, !receipt.externalRecordingUsed else {
            throw ReferenceBeatAssetError.invalid("the rights receipt does not describe this procedural asset")
        }
    }

    private static func writePCM16(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            for buffer in buffers { try file.write(from: buffer) }
            if #available(macOS 15.0, iOS 18.0, watchOS 11.0, *) { file.close() }
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
