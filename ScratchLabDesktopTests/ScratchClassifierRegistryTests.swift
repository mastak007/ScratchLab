import XCTest
@testable import ScratchLab

final class ScratchClassifierRegistryTests: XCTestCase {

    // MARK: - Test doubles

    private final class StubClassifier: ScratchClassifying {
        let supportedScratchType: CaptureSessionScratchType
        let result: MacScratchDetectionResult?
        private(set) var resetCount = 0

        init(_ type: CaptureSessionScratchType, result: MacScratchDetectionResult?) {
            self.supportedScratchType = type
            self.result = result
        }

        func classify(samples: [Float], sampleRate: Double) -> MacScratchDetectionResult? {
            result
        }

        func resetClassifier() {
            resetCount += 1
        }
    }

    private func makeResult(
        _ type: CaptureSessionScratchType,
        accuracy: Double = 80,
        confidence: Double = 80
    ) -> MacScratchDetectionResult {
        MacScratchDetectionResult(
            scratchID: type.rawValue,
            scratchName: type.title,
            accuracy: accuracy,
            confidence: confidence,
            feedback: [],
            detectedAt: Date(timeIntervalSince1970: 1)
        )
    }

    // MARK: - Empty registry

    func testEmptyRegistryReturnsNil() {
        let registry = ScratchClassifierRegistry()
        XCTAssertNil(registry.classify(samples: [0.1, 0.2, 0.3], sampleRate: 44_100))
        XCTAssertEqual(registry.supportedScratchTypes, [])
    }

    // MARK: - Baby Scratch only path (regression guard)

    func testRegistryWithOnlyBabyClassifierReturnsBabyResult() throws {
        let babyResult = makeResult(.babyScratch, accuracy: 72, confidence: 78)
        let stub = StubClassifier(.babyScratch, result: babyResult)
        let registry = ScratchClassifierRegistry(classifiers: [stub])

        let detection = registry.classify(samples: [0.1, 0.2], sampleRate: 44_100)

        XCTAssertEqual(detection?.scratchID, "baby_scratch")
        XCTAssertEqual(detection?.scratchName, "Baby Scratch")
        XCTAssertEqual(try XCTUnwrap(detection?.confidence), 78, accuracy: 0.0001)
        XCTAssertEqual(registry.supportedScratchTypes, [.babyScratch])
    }

    func testRegistryWithOnlyBabyClassifierForwardsNilWhenNotDetected() {
        let stub = StubClassifier(.babyScratch, result: nil)
        let registry = ScratchClassifierRegistry(classifiers: [stub])

        XCTAssertNil(registry.classify(samples: [], sampleRate: 44_100))
    }

    // MARK: - Multi-type selection

    func testRegistryPicksHighestConfidenceMatch() throws {
        let baby = StubClassifier(.babyScratch, result: makeResult(.babyScratch, confidence: 60))
        let chirp = StubClassifier(.chirp, result: makeResult(.chirp, confidence: 88))
        let flare = StubClassifier(.flare1Click, result: makeResult(.flare1Click, confidence: 72))
        let registry = ScratchClassifierRegistry(classifiers: [baby, chirp, flare])

        let detection = registry.classify(samples: [], sampleRate: 44_100)

        XCTAssertEqual(detection?.scratchID, "chirp")
        XCTAssertEqual(detection?.scratchName, "Chirp")
        XCTAssertEqual(try XCTUnwrap(detection?.confidence), 88, accuracy: 0.0001)
    }

    func testRegistryFallsBackToBabyWhenOtherClassifiersAreSilent() throws {
        let baby = StubClassifier(.babyScratch, result: makeResult(.babyScratch, confidence: 55))
        let chirp = StubClassifier(.chirp, result: nil)
        let transform = StubClassifier(.transform, result: nil)
        let registry = ScratchClassifierRegistry(classifiers: [baby, chirp, transform])

        let detection = registry.classify(samples: [], sampleRate: 44_100)

        XCTAssertEqual(detection?.scratchID, "baby_scratch")
        XCTAssertEqual(try XCTUnwrap(detection?.confidence), 55, accuracy: 0.0001)
    }

    // MARK: - Registration

    func testRegisterReplacesExistingClassifierForSameType() throws {
        let registry = ScratchClassifierRegistry()
        let firstChirp = StubClassifier(.chirp, result: makeResult(.chirp, confidence: 30))
        let secondChirp = StubClassifier(.chirp, result: makeResult(.chirp, confidence: 95))

        registry.register(firstChirp)
        registry.register(secondChirp)

        let detection = registry.classify(samples: [], sampleRate: 44_100)
        XCTAssertEqual(try XCTUnwrap(detection?.confidence), 95, accuracy: 0.0001)
        XCTAssertEqual(registry.supportedScratchTypes, [.chirp])
    }

    func testResetAllForwardsToEveryClassifier() {
        let baby = StubClassifier(.babyScratch, result: nil)
        let chirp = StubClassifier(.chirp, result: nil)
        let registry = ScratchClassifierRegistry(classifiers: [baby, chirp])

        registry.resetAll()

        XCTAssertEqual(baby.resetCount, 1)
        XCTAssertEqual(chirp.resetCount, 1)
    }

    // MARK: - Baby Scratch adapter (real detector)

    func testBabyScratchClassifierExposesTheBabyScratchType() {
        let classifier = BabyScratchClassifier()
        XCTAssertEqual(classifier.supportedScratchType, .babyScratch)
    }

    func testBabyScratchClassifierIsSilentOnEmptyAudio() {
        // Regression guard: the existing detector returns nil for empty
        // input, and this adapter must preserve that contract so the
        // shipping Baby Scratch path keeps working when the registry
        // is wired up.
        let classifier = BabyScratchClassifier()
        XCTAssertNil(classifier.classify(samples: [], sampleRate: 44_100))
    }

    // MARK: - All known scratch families have safe display titles

    func testEveryScratchTypeProducesNonEmptyAppFacingTitle() {
        for type in CaptureSessionScratchType.allCases {
            XCTAssertFalse(type.title.isEmpty,
                           "CaptureSessionScratchType.\(type.rawValue) produced an empty UI title")
            XCTAssertTrue(ScratchTypeMetadataSafety.isSafe(type.title),
                          "CaptureSessionScratchType.\(type.rawValue) has an unsafe title \(type.title)")
            XCTAssertTrue(ScratchTypeMetadataSafety.isSafe(type.rawValue),
                          "CaptureSessionScratchType.\(type.rawValue) has an unsafe raw value")
        }
    }

    func testTargetedScratchFamiliesAreModelled() {
        // The training plan calls out these families specifically. If
        // any of them disappears from the enum we want the test to
        // fail loudly so the offline labels stay in sync with the
        // app's type system.
        let required: [CaptureSessionScratchType] = [
            .babyScratch,
            .chirp,
            .flare1Click,
            .flare2Click,
            .transform,
        ]
        let allCases = Set(CaptureSessionScratchType.allCases)
        for type in required {
            XCTAssertTrue(allCases.contains(type),
                          "CaptureSessionScratchType is missing required case .\(type.rawValue)")
        }
    }
}
