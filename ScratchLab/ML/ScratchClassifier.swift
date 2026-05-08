//
//  ScratchClassifier.swift
//  ScratchLab
//
//  Coordinator over the runtime sound + (stubbed) action classifiers. Phase 1
//  delegates predictions to `ScratchSoundClassifier`; the action classifier
//  slot is filled by `ScratchActionClassifierStub` and contributes nothing
//  until Phase 2 lands a feature-based motion model.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Unified prediction

public enum ScratchSignalSource: String, Sendable, Equatable, Codable {
    case sound
    case motion
    case fused
}

public struct ScratchPrediction: Sendable, Equatable {
    public let label: ScratchClassLabel
    public let confidence: Double
    public let source: ScratchSignalSource
    public let timestamp: TimeInterval

    public init(label: ScratchClassLabel,
                confidence: Double,
                source: ScratchSignalSource,
                timestamp: TimeInterval) {
        self.label = label
        self.confidence = confidence
        self.source = source
        self.timestamp = timestamp
    }
}

// MARK: - Coordinator

public final class ScratchClassifier: ObservableObject {

    @Published public private(set) var currentPrediction: ScratchPrediction?

    public let soundClassifier: ScratchSoundClassifier
    public let actionClassifier: ScratchActionClassifying

    public init(
        soundClassifier: ScratchSoundClassifier = ScratchSoundClassifier(),
        actionClassifier: ScratchActionClassifying = ScratchActionClassifierStub()
    ) {
        self.soundClassifier = soundClassifier
        self.actionClassifier = actionClassifier
    }

    /// Begin streaming inference. Returns `false` if the sound model couldn't
    /// be loaded; inspect `soundClassifier.lastError` for details.
    @discardableResult
    public func start(audioFormat: AVAudioFormat) -> Bool {
        actionClassifier.reset()
        return soundClassifier.start(format: audioFormat) { [weak self] sound in
            self?.handleSoundPrediction(sound)
        }
    }

    public func stop() {
        soundClassifier.stop()
        actionClassifier.reset()
        DispatchQueue.main.async { [weak self] in
            self?.currentPrediction = nil
        }
    }

    /// Forward an audio buffer to the sound classifier. Safe to call from the
    /// audio engine's tap callback.
    public func ingestAudio(buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        soundClassifier.analyze(buffer: buffer, at: time)
    }

    /// Forward a single motion observation to the action classifier. The
    /// Phase 1 stub accepts and discards these, keeping the call site stable
    /// for the future feature-based motion model.
    public func ingestMotion(frame: ScratchMotionFrame) {
        actionClassifier.ingest(frame: frame)
    }

    // MARK: - Private

    private func handleSoundPrediction(_ sound: ScratchSoundPrediction) {
        // Phase 1: action classifier returns nothing, so the unified prediction
        // is sound-only. Phase 2 will add fusion (combine confidences when
        // sound and motion agree on a label, downgrade when they disagree).
        let unified = ScratchPrediction(
            label: sound.label,
            confidence: sound.confidence,
            source: .sound,
            timestamp: sound.timestamp
        )
        DispatchQueue.main.async { [weak self] in
            self?.currentPrediction = unified
        }
    }
}
