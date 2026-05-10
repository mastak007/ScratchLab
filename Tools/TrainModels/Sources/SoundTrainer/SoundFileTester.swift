//
//  SoundFileTester.swift
//  SoundTrainer
//
//  Loads a Core ML sound-classification model and runs prediction over an
//  audio file via SoundAnalysis. Used by the `test-sound-classifier` CLI to
//  smoke-test a freshly-trained .mlmodel before it's bundled into the app.
//
//  Inference is synchronous so the CLI can iterate files without orchestration.
//

import Foundation
import CoreML
import SoundAnalysis

public struct SoundFileClassification: Sendable, Equatable {
    public let label: String
    public let confidence: Double
}

public struct SoundFilePrediction: Sendable, Equatable {
    public let topLabel: String
    public let topConfidence: Double
    public let allClassifications: [SoundFileClassification]

    public init(topLabel: String, topConfidence: Double, allClassifications: [SoundFileClassification]) {
        self.topLabel = topLabel
        self.topConfidence = topConfidence
        self.allClassifications = allClassifications
    }
}

public enum SoundFileTesterError: Error, Equatable {
    case modelNotFound(path: String)
    case unsupportedModelExtension(ext: String)
    case modelLoadFailed(underlying: String)
    case analyzerSetupFailed(underlying: String)
    case noClassification
}

public struct SoundFileTester: Sendable {

    public init() {}

    /// Load a Core ML model from a `.mlmodel` (compiles at runtime) or
    /// pre-compiled `.mlmodelc` URL.
    public static func loadModel(at url: URL) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SoundFileTesterError.modelNotFound(path: url.path)
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mlmodelc":
            do { return try MLModel(contentsOf: url) }
            catch { throw SoundFileTesterError.modelLoadFailed(underlying: error.localizedDescription) }
        case "mlmodel":
            do {
                let compiled = try MLModel.compileModel(at: url)
                return try MLModel(contentsOf: compiled)
            } catch {
                throw SoundFileTesterError.modelLoadFailed(underlying: error.localizedDescription)
            }
        default:
            throw SoundFileTesterError.unsupportedModelExtension(ext: ext)
        }
    }

    /// Synchronously classify a single audio file. Returns the top-confidence
    /// label averaged across all windows the analyzer produced.
    public static func classify(audioFile url: URL, with model: MLModel) throws -> SoundFilePrediction {
        let analyzer: SNAudioFileAnalyzer
        do {
            analyzer = try SNAudioFileAnalyzer(url: url)
        } catch {
            throw SoundFileTesterError.analyzerSetupFailed(underlying: error.localizedDescription)
        }

        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(mlModel: model)
        } catch {
            throw SoundFileTesterError.analyzerSetupFailed(underlying: error.localizedDescription)
        }

        let observer = AggregatingObserver()
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            throw SoundFileTesterError.analyzerSetupFailed(underlying: error.localizedDescription)
        }

        // SNAudioFileAnalyzer.analyze() is synchronous: by the time it returns
        // the observer has received every classification result for the file.
        analyzer.analyze()

        guard let prediction = observer.aggregate() else {
            throw SoundFileTesterError.noClassification
        }
        return prediction
    }
}

private final class AggregatingObserver: NSObject, SNResultsObserving {
    private var sums: [String: Double] = [:]
    private var counts: [String: Int] = [:]

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        for c in classification.classifications {
            sums[c.identifier, default: 0] += c.confidence
            counts[c.identifier, default: 0] += 1
        }
    }

    func aggregate() -> SoundFilePrediction? {
        guard !sums.isEmpty else { return nil }
        var averaged: [SoundFileClassification] = []
        for (label, sum) in sums {
            let n = counts[label, default: 1]
            averaged.append(SoundFileClassification(
                label: label,
                confidence: sum / Double(n)
            ))
        }
        averaged.sort { $0.confidence > $1.confidence }
        guard let top = averaged.first else { return nil }
        return SoundFilePrediction(
            topLabel: top.label,
            topConfidence: top.confidence,
            allClassifications: averaged
        )
    }
}
