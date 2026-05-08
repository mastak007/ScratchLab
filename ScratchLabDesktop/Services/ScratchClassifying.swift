import Foundation

/// Protocol describing a single-scratch classifier.
///
/// The existing real-time detector is hardcoded to Baby Scratch
/// (see ``MacScratchDetector/matchBabyScratch``). To learn additional
/// families (Chirp, Flare, Transform, …) without rewriting the
/// detection pipeline, new classifiers conform to this protocol and are
/// registered with ``ScratchClassifierRegistry``. Each classifier owns
/// its own buffering and returns an optional result for the audio
/// window it was given. The registry picks the highest-confidence
/// match across all registered classifiers, defaulting to whatever the
/// Baby Scratch classifier emits when nothing else fires.
///
/// This is intentionally a thin abstraction: it does not change the
/// existing `MacScratchDetector` API and does not pull in any
/// training-data, vendor, rights, or filesystem metadata.
protocol ScratchClassifying: AnyObject {
    /// The single scratch type this classifier can recognise.
    var supportedScratchType: CaptureSessionScratchType { get }

    /// Run one classification pass on the given mono audio samples.
    /// Implementations may buffer internally and return `nil` until
    /// they have enough audio to decide.
    func classify(samples: [Float], sampleRate: Double) -> MacScratchDetectionResult?

    /// Reset any internal buffers / state.
    func resetClassifier()
}

/// Adapter that exposes the existing `MacScratchDetector` as a
/// `ScratchClassifying` instance for Baby Scratch. The adapter does
/// **not** modify the detector — it forwards every call to it. This
/// preserves the existing real-time behaviour and tests.
final class BabyScratchClassifier: ScratchClassifying {
    private let detector: MacScratchDetector

    init(detector: MacScratchDetector = MacScratchDetector()) {
        self.detector = detector
    }

    var supportedScratchType: CaptureSessionScratchType { .babyScratch }

    func classify(samples: [Float], sampleRate: Double) -> MacScratchDetectionResult? {
        detector.process(samples: samples, sampleRate: sampleRate)
    }

    func resetClassifier() {
        detector.reset()
    }
}

/// Picks the highest-confidence detection across a list of
/// classifiers. When only the Baby Scratch classifier is registered
/// (the current shipping configuration), the registry returns
/// whatever that classifier returns — so existing call sites that go
/// through the registry behave exactly like calling the detector
/// directly.
final class ScratchClassifierRegistry {
    private var classifiers: [ScratchClassifying] = []

    init(classifiers: [ScratchClassifying] = []) {
        self.classifiers = classifiers
    }

    func register(_ classifier: ScratchClassifying) {
        let supported = classifier.supportedScratchType
        classifiers.removeAll { $0.supportedScratchType == supported }
        classifiers.append(classifier)
    }

    var supportedScratchTypes: [CaptureSessionScratchType] {
        classifiers.map { $0.supportedScratchType }
    }

    func resetAll() {
        classifiers.forEach { $0.resetClassifier() }
    }

    func classify(samples: [Float], sampleRate: Double) -> MacScratchDetectionResult? {
        guard !classifiers.isEmpty else { return nil }

        var best: MacScratchDetectionResult?
        for classifier in classifiers {
            guard let candidate = classifier.classify(samples: samples, sampleRate: sampleRate) else {
                continue
            }
            if let current = best {
                if candidate.confidence > current.confidence {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }
}
