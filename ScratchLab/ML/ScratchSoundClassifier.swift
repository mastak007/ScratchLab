//
//  ScratchSoundClassifier.swift
//  ScratchLab
//
//  Streams audio buffers through a Core ML sound-classification model using
//  Apple's SoundAnalysis framework, and surfaces typed predictions.
//
//  Concurrency model:
//    - The class itself is not MainActor. analyze(buffer:at:) is safe to call
//      from the audio engine's tap callback (any thread).
//    - All access to the SNAudioStreamAnalyzer is funnelled through an internal
//      serial queue, matching the framework's threading expectations.
//    - @Published state updates hop to the main queue for SwiftUI consumers.
//
//  The compiled model is expected to ship in the app bundle as either
//  `<modelFilename>.mlmodelc` (preferred) or `<modelFilename>.mlmodel` (which
//  is compiled at runtime). Until the model is trained and added, the
//  classifier reports `.modelMissing` on `start()` and yields no predictions.
//

import Foundation
import AVFoundation
import CoreML
import SoundAnalysis

// MARK: - Result

public struct ScratchSoundPrediction: Sendable, Equatable {
    public let label: ScratchClassLabel
    public let confidence: Double
    public let timestamp: TimeInterval

    public init(label: ScratchClassLabel, confidence: Double, timestamp: TimeInterval) {
        self.label = label
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - Errors

public enum ScratchSoundClassifierError: Error, Equatable {
    case modelMissing(filename: String)
    case modelLoadFailed(underlying: String)
    case analyzerFailed(underlying: String)
}

// MARK: - Configuration

public struct ScratchSoundClassifierConfig: Sendable, Equatable {
    /// Compiled model basename (without extension). The bundle is searched for
    /// `<modelFilename>.mlmodelc` first, then `<modelFilename>.mlmodel`.
    public var modelFilename: String

    /// Minimum top-1 confidence required before emitting a prediction.
    public var minimumConfidence: Double

    /// Sliding window length in seconds. `nil` keeps the model's default
    /// (Apple's MLSoundClassifier currently uses ~0.975 s windows).
    public var windowDuration: TimeInterval?

    /// Window-to-window overlap factor in `[0, 0.95]`.
    public var overlapFactor: Double

    public init(
        modelFilename: String = "ScratchSoundClassifier",
        minimumConfidence: Double = 0.6,
        windowDuration: TimeInterval? = nil,
        overlapFactor: Double = 0.5
    ) {
        self.modelFilename = modelFilename
        self.minimumConfidence = minimumConfidence
        self.windowDuration = windowDuration
        self.overlapFactor = overlapFactor
    }
}

// MARK: - Classifier

public final class ScratchSoundClassifier: ObservableObject {

    @Published public private(set) var lastPrediction: ScratchSoundPrediction?
    @Published public private(set) var isAnalyzing: Bool = false
    @Published public private(set) var lastError: ScratchSoundClassifierError?

    public typealias PredictionHandler = (ScratchSoundPrediction) -> Void

    public let config: ScratchSoundClassifierConfig

    private let bundle: Bundle
    private let analysisQueue = DispatchQueue(label: "com.scratchlab.sound-classifier.analysis",
                                              qos: .userInitiated)

    // All three of the following are accessed only on `analysisQueue`.
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: Observer?
    private var clientHandler: PredictionHandler?

    public init(config: ScratchSoundClassifierConfig = .init(), bundle: Bundle = .main) {
        self.config = config
        self.bundle = bundle
    }

    /// Configure the analyzer for a given audio format. Returns `false` if the
    /// model couldn't be loaded; inspect `lastError` for details.
    @discardableResult
    public func start(format: AVAudioFormat, onPrediction: @escaping PredictionHandler) -> Bool {
        do {
            let model = try loadModel()
            let request = try makeRequest(model: model)
            let observer = Observer(
                config: config,
                onPrediction: { [weak self] prediction in
                    self?.publish(prediction: prediction)
                    self?.clientHandler?(prediction)
                }
            )
            let newAnalyzer = SNAudioStreamAnalyzer(format: format)
            try newAnalyzer.add(request, withObserver: observer)

            analysisQueue.sync {
                self.analyzer?.removeAllRequests()
                self.analyzer = newAnalyzer
                self.observer = observer
                self.clientHandler = onPrediction
            }
            updateState(isAnalyzing: true, lastError: nil)
            return true
        } catch let err as ScratchSoundClassifierError {
            updateState(isAnalyzing: false, lastError: err)
            return false
        } catch {
            updateState(isAnalyzing: false,
                        lastError: .analyzerFailed(underlying: error.localizedDescription))
            return false
        }
    }

    /// Push an audio buffer through the analyzer. Safe to call from any thread,
    /// including the audio engine's real-time tap callback.
    public func analyze(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        analysisQueue.async { [weak self] in
            self?.analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
        }
    }

    public func stop() {
        analysisQueue.sync {
            self.analyzer?.removeAllRequests()
            self.analyzer = nil
            self.observer = nil
            self.clientHandler = nil
        }
        updateState(isAnalyzing: false, lastError: nil)
    }

    // MARK: - Private

    private func loadModel() throws -> MLModel {
        // Prefer pre-compiled .mlmodelc (built into the app bundle by Xcode).
        if let url = bundle.url(forResource: config.modelFilename, withExtension: "mlmodelc") {
            do {
                return try MLModel(contentsOf: url)
            } catch {
                throw ScratchSoundClassifierError.modelLoadFailed(underlying: error.localizedDescription)
            }
        }
        // Fallback: raw .mlmodel — compile at runtime (slower but supported).
        if let url = bundle.url(forResource: config.modelFilename, withExtension: "mlmodel") {
            do {
                let compiled = try MLModel.compileModel(at: url)
                return try MLModel(contentsOf: compiled)
            } catch {
                throw ScratchSoundClassifierError.modelLoadFailed(underlying: error.localizedDescription)
            }
        }
        throw ScratchSoundClassifierError.modelMissing(filename: config.modelFilename)
    }

    private func makeRequest(model: MLModel) throws -> SNClassifySoundRequest {
        do {
            let request = try SNClassifySoundRequest(mlModel: model)
            if let window = config.windowDuration {
                request.windowDuration = CMTime(seconds: window, preferredTimescale: 48_000)
            }
            request.overlapFactor = max(0.0, min(0.95, config.overlapFactor))
            return request
        } catch {
            throw ScratchSoundClassifierError.modelLoadFailed(underlying: error.localizedDescription)
        }
    }

    private func publish(prediction: ScratchSoundPrediction) {
        DispatchQueue.main.async { [weak self] in
            self?.lastPrediction = prediction
        }
    }

    private func updateState(isAnalyzing: Bool, lastError: ScratchSoundClassifierError?) {
        DispatchQueue.main.async { [weak self] in
            self?.isAnalyzing = isAnalyzing
            self?.lastError = lastError
        }
    }
}

// MARK: - Observer

private final class Observer: NSObject, SNResultsObserving {
    let config: ScratchSoundClassifierConfig
    let onPrediction: (ScratchSoundPrediction) -> Void

    init(config: ScratchSoundClassifierConfig,
         onPrediction: @escaping (ScratchSoundPrediction) -> Void) {
        self.config = config
        self.onPrediction = onPrediction
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first else {
            return
        }
        guard top.confidence >= config.minimumConfidence else { return }
        guard let label = ScratchClassLabel(modelLabel: top.identifier) else { return }
        onPrediction(.init(
            label: label,
            confidence: top.confidence,
            timestamp: result.timeRange.start.seconds
        ))
    }
}
