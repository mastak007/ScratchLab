// Offline, explicitly advisory recognition for finalized media. This service
// never writes capture metadata, operator readings, canonical approval or scores.
import Foundation
import AVFoundation
import CoreML
import CryptoKit
import SoundAnalysis

public enum OfflineAdvisoryModality: String, Sendable, Codable, CaseIterable {
    case audio, motion
}

public struct OfflineAdvisoryModelSource: Sendable, Equatable {
    public let modelURL: URL
    /// SHA256 of a raw .mlmodel, or the deterministic directory fingerprint
    /// returned by modelArtifactSHA256(at:) for a compiled .mlmodelc.
    public let sourceSHA256: String

    public init(modelURL: URL, sourceSHA256: String) {
        self.modelURL = modelURL
        self.sourceSHA256 = sourceSHA256.lowercased()
    }
}

public struct OfflineAdvisoryClassification: Sendable, Codable, Equatable {
    public let label: String
    /// Model output score. This is not accuracy or a calibrated probability.
    public let modelScore: Double
}

public struct OfflineAdvisoryWindow: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let modality: OfflineAdvisoryModality
    public let startSeconds: Double
    public let endSeconds: Double
    public let label: String
    public let modelScore: Double
    public let classifications: [OfflineAdvisoryClassification]
    public let sourceSHA256: String
    public let modelSHA256: String
    public let qualityNotes: [String]
}

public struct OfflineAdvisoryIssue: Sendable, Codable, Equatable {
    public let modality: OfflineAdvisoryModality
    public let message: String
}

public struct OfflineAdvisorySourceReceipt: Sendable, Codable, Equatable {
    public let modality: OfflineAdvisoryModality
    public let mediaURL: URL
    public let mediaSHA256: String
    public let durationSeconds: Double
    public let modelURL: URL
    public let modelSHA256: String
    public let preprocessing: String
}

public struct OfflineScratchAdvisoryReport: Sendable, Codable, Equatable {
    public let schema: String
    public let generatedAt: Date
    public let windows: [OfflineAdvisoryWindow]
    /// One requested modality can fail while the other supplies useful results.
    public let issues: [OfflineAdvisoryIssue]
    public let sources: [OfflineAdvisorySourceReceipt]
    public let limitations: [String]
}

public enum OfflineScratchAdvisoryError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case sourceUnavailable(String)
    case sourceChanged(String)
    case modelIdentityMismatch(String)
    case modelIncompatible(String)
    case analysisFailed(String)
    case noResults([OfflineAdvisoryIssue])

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail), .sourceUnavailable(let detail),
             .sourceChanged(let detail), .modelIdentityMismatch(let detail),
             .modelIncompatible(let detail), .analysisFailed(let detail):
            return detail
        case .noResults(let issues):
            return "No advisory results. " + issues.map { "\($0.modality.rawValue): \($0.message)" }.joined(separator: " ")
        }
    }
}

public struct OfflineScratchAdvisoryService: Sendable {
    /// A whole-file analysis bound, not a crop. Longer media is explicitly
    /// refused so the user is never shown an unlabelled truncated result.
    public let maximumDurationSeconds: Double
    public static let motionPreprocessingVersion = "legacy-action-67-v1:requested30Hz:window60:stride30:topLeft:clamp01:missingZero"

    public init(maximumDurationSeconds: Double = 120) {
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    public func analyze(
        audioURL: URL? = nil,
        videoURL: URL? = nil,
        soundModel: OfflineAdvisoryModelSource? = nil,
        actionModel: OfflineAdvisoryModelSource? = nil
    ) async throws -> OfflineScratchAdvisoryReport {
        guard audioURL != nil || videoURL != nil else {
            throw OfflineScratchAdvisoryError.invalidRequest("Choose a finalized audio or video file to analyze.")
        }
        guard maximumDurationSeconds.isFinite, maximumDurationSeconds > 0 else {
            throw OfflineScratchAdvisoryError.invalidRequest("The offline analysis duration limit must be positive and finite.")
        }
        try Task.checkCancellation()
        let cancellation = AdvisoryCancellation()
        // Core ML compilation, hashing and Vision never run on the UI actor.
        let work = Task.detached(priority: .userInitiated) {
            try await analyzeFiles(
                audioURL: audioURL, videoURL: videoURL,
                soundModel: soundModel, actionModel: actionModel,
                cancellation: cancellation
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
    }

    /// File bytes for .mlmodel. For .mlmodelc, SHA256 of sorted relative-path,
    /// NUL, child-file SHA256, newline records (never mutable path metadata).
    public static func modelArtifactSHA256(at url: URL) throws -> String {
        if url.pathExtension.lowercased() != "mlmodelc" {
            return try fingerprintFile(url)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw OfflineScratchAdvisoryError.sourceUnavailable("Cannot read compiled model \(url.lastPathComponent).")
        }
        var entries: [(String, URL)] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OfflineScratchAdvisoryError.sourceUnavailable("Compiled model contains a symbolic link.")
            }
            if values.isRegularFile == true {
                entries.append((String(file.path.dropFirst(url.path.count + 1)), file))
            }
        }
        guard !entries.isEmpty else {
            throw OfflineScratchAdvisoryError.sourceUnavailable("The compiled model contains no files.")
        }
        var hash = SHA256()
        for (path, file) in entries.sorted(by: { $0.0 < $1.0 }) {
            let childHash = try fingerprintFile(file)
            hash.update(data: Data("\(path)\0\(childHash)\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func analyzeFiles(
        audioURL: URL?, videoURL: URL?,
        soundModel: OfflineAdvisoryModelSource?, actionModel: OfflineAdvisoryModelSource?,
        cancellation: AdvisoryCancellation
    ) async throws -> OfflineScratchAdvisoryReport {
        var windows: [OfflineAdvisoryWindow] = []
        var issues: [OfflineAdvisoryIssue] = []
        var sources: [OfflineAdvisorySourceReceipt] = []
        for (modality, media, modelSource) in [
            (OfflineAdvisoryModality.audio, audioURL, soundModel),
            (OfflineAdvisoryModality.motion, videoURL, actionModel)
        ] {
            guard let media else { continue }
            try Task.checkCancellation()
            do {
                guard let modelSource else {
                    throw OfflineScratchAdvisoryError.sourceUnavailable("The verified \(modality.rawValue) model is unavailable.")
                }
                let duration = try await validatedDuration(of: media)
                let originalHash = try Self.fingerprintFile(media)
                let loadedModel = try Self.loadVerifiedModel(modelSource)
                defer {
                    if let temporaryURL = loadedModel.temporaryCompiledURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                }
                let model = loadedModel.model
                let result: [OfflineAdvisoryWindow]
                if modality == .audio {
                    result = try await analyzeAudio(
                        media, model: model, sourceHash: originalHash,
                        modelHash: modelSource.sourceSHA256, cancellation: cancellation
                    )
                } else {
                    result = try await analyzeMotion(
                        media, duration: duration, model: model,
                        sourceHash: originalHash, modelHash: modelSource.sourceSHA256,
                        cancellation: cancellation
                    )
                }
                try Task.checkCancellation()
                guard !result.isEmpty else {
                    throw OfflineScratchAdvisoryError.analysisFailed("The model produced no usable windows for this file.")
                }
                guard try Self.fingerprintFile(media) == originalHash else {
                    throw OfflineScratchAdvisoryError.sourceChanged("The media changed during analysis. Finalize the take and try again.")
                }
                guard try Self.modelArtifactSHA256(at: modelSource.modelURL) == modelSource.sourceSHA256 else {
                    throw OfflineScratchAdvisoryError.sourceChanged("The model changed during analysis. Results were discarded.")
                }
                windows.append(contentsOf: result)
                sources.append(.init(
                    modality: modality, mediaURL: media, mediaSHA256: originalHash,
                    durationSeconds: duration, modelURL: modelSource.modelURL,
                    modelSHA256: modelSource.sourceSHA256,
                    preprocessing: modality == .audio ? "SoundAnalysis model-default windows and overlap; file time" : Self.motionPreprocessingVersion
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                issues.append(.init(modality: modality, message: error.localizedDescription))
            }
        }
        guard !windows.isEmpty else { throw OfflineScratchAdvisoryError.noResults(issues) }
        return .init(
            schema: "scratchlab_offline_advisory_v1", generatedAt: Date(), windows: windows,
            issues: issues, sources: sources,
            limitations: [
                "Research model suggestions only. Model scores are not accuracy or calibrated confidence, and external generalization is unverified.",
                "Audio and motion are independent suggestions in each file's own clock. They are not synchronized or fused evidence.",
                "These suggestions do not set the selected technique, measure fader state, change captured notation, grade practice, or approve a canonical reference.",
                "The legacy action-model evaluation contains related camera views across training and validation; its reported accuracy is not independent performance accuracy."
            ]
        )
    }

    private func validatedDuration(of url: URL) async throws -> Double {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw OfflineScratchAdvisoryError.sourceUnavailable("Cannot read finalized media \(url.lastPathComponent).")
        }
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else {
            throw OfflineScratchAdvisoryError.analysisFailed("The media has no finite positive duration.")
        }
        guard seconds <= maximumDurationSeconds else {
            throw OfflineScratchAdvisoryError.invalidRequest(
                "This file is \(Int(seconds.rounded(.up))) seconds long. Offline analysis accepts whole files up to \(Int(maximumDurationSeconds)) seconds; no partial result was produced."
            )
        }
        return seconds
    }

    private static func fingerprintFile(_ url: URL) throws -> String {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw OfflineScratchAdvisoryError.sourceUnavailable("Cannot read \(url.lastPathComponent).")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func loadVerifiedModel(_ source: OfflineAdvisoryModelSource) throws -> LoadedAdvisoryModel {
        let ext = source.modelURL.pathExtension.lowercased()
        guard ext == "mlmodel" || ext == "mlmodelc" else {
            throw OfflineScratchAdvisoryError.modelIncompatible("The model must be a raw .mlmodel or compiled .mlmodelc.")
        }
        let actualHash = try modelArtifactSHA256(at: source.modelURL)
        guard actualHash == source.sourceSHA256 else {
            throw OfflineScratchAdvisoryError.modelIdentityMismatch("The model does not match its verified source hash.")
        }
        try Task.checkCancellation()
        if ext == "mlmodelc" {
            return .init(model: try MLModel(contentsOf: source.modelURL), temporaryCompiledURL: nil)
        }
        let compiled = try MLModel.compileModel(at: source.modelURL)
        do {
            try Task.checkCancellation()
            return .init(model: try MLModel(contentsOf: compiled), temporaryCompiledURL: compiled)
        } catch {
            try? FileManager.default.removeItem(at: compiled)
            throw error
        }
    }
}

private struct LoadedAdvisoryModel {
    let model: MLModel
    let temporaryCompiledURL: URL?
}

// The lock protects cancellation racing with framework setup/teardown. External
// callbacks run after unlocking; cancelAnalysis/cancelAllCGImageGeneration are
// the frameworks' asynchronous cancellation APIs.
private final class AdvisoryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    func install(_ action: (() -> Void)?) {
        lock.lock()
        self.action = action
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { action?() }
    }

    /// Prevent cancellation from falling between setup and async start.
    func begin(cancel: @escaping () -> Void, start: () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        action = cancel
        start()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = action
        lock.unlock()
        action?()
    }
}

private extension OfflineScratchAdvisoryService {
    func analyzeAudio(
        _ url: URL, model: MLModel, sourceHash: String, modelHash: String,
        cancellation: AdvisoryCancellation
    ) async throws -> [OfflineAdvisoryWindow] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(mlModel: model)
        let observer = AdvisorySoundObserver(sourceHash: sourceHash, modelHash: modelHash)
        try analyzer.add(request, withObserver: observer)
        defer { cancellation.install(nil); analyzer.removeAllRequests() }
        let reachedEnd: Bool = try await withCheckedThrowingContinuation { continuation in
            do {
                try cancellation.begin(
                    cancel: { analyzer.cancelAnalysis() },
                    start: {
                        analyzer.analyze { completed in continuation.resume(returning: completed) }
                    }
                )
            } catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        let snapshot = observer.snapshot()
        if let error = snapshot.error { throw OfflineScratchAdvisoryError.analysisFailed(error) }
        guard reachedEnd else {
            throw OfflineScratchAdvisoryError.analysisFailed("Audio analysis stopped before the end of the file; partial results were discarded.")
        }
        return snapshot.windows.sorted { $0.startSeconds < $1.startSeconds }
    }

    func analyzeMotion(
        _ url: URL, duration: Double, model: MLModel,
        sourceHash: String, modelHash: String, cancellation: AdvisoryCancellation
    ) async throws -> [OfflineAdvisoryWindow] {
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == Set(ActionTrainerFeatures.columns),
              description.inputDescriptionsByName.values.allSatisfy({ $0.type == .double }) else {
            throw OfflineScratchAdvisoryError.modelIncompatible("The action model does not accept the shared legacy 67-feature schema.")
        }
        let labelKey = description.predictedFeatureName ?? "label"
        let probabilityKey = description.predictedProbabilitiesName ?? "labelProbability"
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw OfflineScratchAdvisoryError.analysisFailed("This file has no video track for motion analysis.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.005, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.005, preferredTimescale: 600)
        cancellation.install { generator.cancelAllCGImageGeneration() }
        defer { cancellation.install(nil); generator.cancelAllCGImageGeneration() }
        let sampleCount = max(1, Int((duration * 30).rounded(.down)) + 1)
        var frames: [ScratchMotionFrame] = []
        var samples: [AdvisoryMotionSample] = []
        var failedDecodeCount = 0
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let requested = CMTime(seconds: min(Double(index) / 30, duration), preferredTimescale: 600)
            let image: CGImage
            let actual: CMTime
            do {
                (image, actual) = try await generator.image(at: requested)
            } catch {
                try Task.checkCancellation()
                failedDecodeCount += 1
                continue
            }
            try Task.checkCancellation()
            var visionFailed = false
            let frame: ScratchMotionFrame
            do {
                frame = try ScratchHandPoseFrameExtractor.frame(from: image, timestamp: requested.seconds)
            } catch {
                visionFailed = true
                frame = ScratchMotionFrame(timestamp: requested.seconds)
            }
            frames.append(frame)
            samples.append(.init(
                requested: requested.seconds, actual: actual.seconds,
                visionFailed: visionFailed, offImagePoints: Self.offImagePointCount(frame)
            ))
        }
        let windows = MotionWindowBuilder().windows(
            forFrames: frames, classLabel: "unlabelled", sourceFile: url.lastPathComponent
        )
        guard !windows.isEmpty else {
            throw OfflineScratchAdvisoryError.analysisFailed(
                "Motion analysis needs 60 decodable requested samples (about two seconds); found \(frames.count)."
            )
        }
        let handlessWindowCount = windows.filter { window in
            !window.frames.contains { $0.dominantHandPresent || $0.dominantHandWristPresent }
        }.count
        var predictions: [OfflineAdvisoryWindow] = []
        for window in windows {
            try Task.checkCancellation()
            // A model can return a confident label for sentinel-only input.
            // Do not expose such a label as an observed movement suggestion.
            guard window.frames.contains(where: { $0.dominantHandPresent || $0.dominantHandWristPresent }) else { continue }
            let row = ActionTrainerFeatures.projectToRow(window)
            guard row.values.allSatisfy(\.isFinite) else {
                throw OfflineScratchAdvisoryError.analysisFailed("Motion features contain a non-finite value; no result was retained for this video.")
            }
            let input = try MLDictionaryFeatureProvider(dictionary: row.mapValues { MLFeatureValue(double: $0) })
            let output = try await model.prediction(from: input)
            guard let label = output.featureValue(for: labelKey)?.stringValue, !label.isEmpty,
                  let probabilities = output.featureValue(for: probabilityKey)?.dictionaryValue else {
                throw OfflineScratchAdvisoryError.modelIncompatible("The action model did not provide its label and model-score outputs.")
            }
            let classifications = probabilities.compactMap { key, value -> OfflineAdvisoryClassification? in
                guard let name = key as? String, value.doubleValue.isFinite,
                      (0...1).contains(value.doubleValue) else { return nil }
                return .init(label: name, modelScore: value.doubleValue)
            }.sorted { $0.modelScore > $1.modelScore }
            guard let score = classifications.first(where: { $0.label == label })?.modelScore else {
                throw OfflineScratchAdvisoryError.modelIncompatible("The action model's selected label has no finite score between zero and one.")
            }
            let sampleStart = window.windowIndex * 30
            let sampleSlice = samples[sampleStart..<(sampleStart + 60)]
            let offImage = sampleSlice.reduce(0) { $0 + $1.offImagePoints }
            let visionFailures = sampleSlice.filter(\.visionFailed).count
            let shifts = sampleSlice.map { abs($0.actual - $0.requested) }.filter(\.isFinite)
            let maxShift = shifts.max() ?? 0
            let missing = window.frames.filter { !$0.dominantHandPresent }.count
            var notes = [
                "60 requested samples at 30 Hz, stride 30. Times use the requested sampling clock, not decoded frame PTS or hardware synchronization.",
                "Hand slots are reselected by Vision confidence each frame; dominant/secondary do not identify a persistent hand or handedness.",
                "\(missing)/60 samples lack the primary hand point. Legacy preprocessing includes missing zeros and clips off-image coordinates; model scores are uncalibrated.",
                "\(offImage) raw off-image point observations were clipped by the legacy transform. \(visionFailures) samples had Vision failures.",
                String(format: "Maximum requested-to-decoded timestamp difference in this window: %.4f s.", maxShift),
                "Record center, record angle and physical fader position are unobserved. No MIDI or Watch evidence is used."
            ]
            if handlessWindowCount > 0 {
                notes.append("\(handlessWindowCount) complete windows in this video had no detected primary hand or wrist; they received no model label.")
            }
            if failedDecodeCount > 0 {
                notes.append("\(failedDecodeCount) requested frames in the whole video could not be decoded. Windows use the remaining samples, as in the legacy extractor.")
            }
            predictions.append(.init(
                id: "motion:\(sourceHash):\(window.windowIndex)", modality: .motion,
                startSeconds: window.startTimestamp, endSeconds: window.endTimestamp,
                label: label, modelScore: score, classifications: classifications,
                sourceSHA256: sourceHash, modelSHA256: modelHash, qualityNotes: notes
            ))
        }
        if predictions.isEmpty {
            throw OfflineScratchAdvisoryError.analysisFailed("No motion window contained a detected primary hand or wrist. Missing points cannot identify a scratch.")
        }
        return predictions
    }

    static func offImagePointCount(_ frame: ScratchMotionFrame) -> Int {
        [frame.dominantHand, frame.dominantHandWrist, frame.dominantHandIndexTip,
         frame.dominantHandThumbTip, frame.dominantHandMiddleTip, frame.secondaryHandWrist]
            .compactMap { $0 }
            .filter { !$0.x.isFinite || !$0.y.isFinite || !(0...1).contains($0.x) || !(0...1).contains($0.y) }
            .count
    }
}

private struct AdvisoryMotionSample {
    let requested: Double
    let actual: Double
    let visionFailed: Bool
    let offImagePoints: Int
}

private final class AdvisorySoundObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private let sourceHash: String
    private let modelHash: String
    private var windows: [OfflineAdvisoryWindow] = []
    private var analysisError: String?

    init(sourceHash: String, modelHash: String) {
        self.sourceHash = sourceHash
        self.modelHash = modelHash
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let start = result.timeRange.start.seconds
        let end = CMTimeRangeGetEnd(result.timeRange).seconds
        let classifications = result.classifications.compactMap { classification -> OfflineAdvisoryClassification? in
            guard !classification.identifier.isEmpty, classification.confidence.isFinite,
                  (0...1).contains(classification.confidence) else { return nil }
            return .init(label: classification.identifier, modelScore: classification.confidence)
        }.sorted { $0.modelScore > $1.modelScore }
        lock.lock()
        defer { lock.unlock() }
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              let top = classifications.first else {
            analysisError = "SoundAnalysis returned an invalid time range or model score."
            return
        }
        windows.append(.init(
            id: "audio:\(sourceHash):\(windows.count)", modality: .audio,
            startSeconds: start, endSeconds: end,
            label: top.label, modelScore: top.modelScore, classifications: classifications,
            sourceSHA256: sourceHash, modelSHA256: modelHash,
            qualityNotes: ["SoundAnalysis model-default windows in the audio file's own clock. Scores are model outputs, not validated accuracy; silence and unfamiliar audio can still receive labels."]
        ))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        analysisError = error.localizedDescription
        lock.unlock()
    }

    func snapshot() -> (windows: [OfflineAdvisoryWindow], error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (windows, analysisError)
    }
}
