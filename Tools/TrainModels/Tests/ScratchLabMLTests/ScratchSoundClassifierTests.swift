import XCTest
import AVFoundation
@testable import ScratchLabML

final class ScratchSoundClassifierTests: XCTestCase {

    func test_defaultConfig_hasReasonableValues() {
        let cfg = ScratchSoundClassifierConfig()
        XCTAssertEqual(cfg.modelFilename, "ScratchSoundClassifier")
        XCTAssertGreaterThan(cfg.minimumConfidence, 0)
        XCTAssertLessThanOrEqual(cfg.minimumConfidence, 1)
        XCTAssertGreaterThanOrEqual(cfg.overlapFactor, 0)
        XCTAssertLessThanOrEqual(cfg.overlapFactor, 0.95)
    }

    func test_start_returnsFalseAndModelMissingErrorWhenBundleHasNoModel() throws {
        // Any bundle works — the random model name guarantees no match.
        let bundle = Bundle(for: type(of: self))
        let cfg = ScratchSoundClassifierConfig(modelFilename: "DefinitelyDoesNotExist_\(UUID().uuidString)")
        let classifier = ScratchSoundClassifier(config: cfg, bundle: bundle)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            return XCTFail("Could not construct AVAudioFormat for the test")
        }

        let success = classifier.start(format: format) { _ in }
        XCTAssertFalse(success)

        // The state hop is async; spin briefly so the error reaches `lastError`.
        let exp = expectation(description: "lastError reflects modelMissing")
        DispatchQueue.main.async {
            if case .modelMissing = classifier.lastError {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(classifier.isAnalyzing)
    }

    func test_stop_isIdempotentWhenNotStarted() {
        let classifier = ScratchSoundClassifier()
        classifier.stop()  // must not crash
        classifier.stop()
        XCTAssertFalse(classifier.isAnalyzing)
    }

    func test_predictionStruct_holdsValuesVerbatim() {
        let p = ScratchSoundPrediction(label: .baby, confidence: 0.92, timestamp: 1.5)
        XCTAssertEqual(p.label, .baby)
        XCTAssertEqual(p.confidence, 0.92)
        XCTAssertEqual(p.timestamp, 1.5)
    }
}
