import XCTest
@testable import ScratchLabML

final class ScratchClassifierTests: XCTestCase {

    func test_defaultInit_usesStubActionClassifier() {
        let coord = ScratchClassifier()
        XCTAssertTrue(coord.actionClassifier is ScratchActionClassifierStub,
            "Phase 1 must default to the stub action classifier")
    }

    func test_init_acceptsInjectedDependencies() {
        let sound = ScratchSoundClassifier()
        let action = ScratchActionClassifierStub()
        let coord = ScratchClassifier(soundClassifier: sound, actionClassifier: action)
        XCTAssertTrue(coord.soundClassifier === sound)
        XCTAssertTrue((coord.actionClassifier as AnyObject) === (action as AnyObject))
    }

    func test_actionStub_throwsNotImplementedOnClassify() {
        let stub = ScratchActionClassifierStub()
        XCTAssertThrowsError(try stub.classifyCurrentWindow()) { err in
            XCTAssertEqual(err as? ScratchActionClassifierError, .notImplemented)
        }
    }

    func test_actionStub_ingestAndResetDoNotCrash() {
        let stub = ScratchActionClassifierStub()
        stub.ingest(frame: ScratchMotionFrame(timestamp: 0))
        stub.ingest(frame: ScratchMotionFrame(timestamp: 1, dominantHand: CGPoint(x: 0.5, y: 0.5)))
        stub.reset()
        // Still throws after reset — stub never produces results.
        XCTAssertThrowsError(try stub.classifyCurrentWindow())
    }

    func test_motionFrame_holdsOptionalFields() {
        let frame = ScratchMotionFrame(
            timestamp: 1.0,
            dominantHand: CGPoint(x: 0.4, y: 0.6),
            recordEdgeAngle: 12.5,
            crossfaderPosition: 0.7
        )
        XCTAssertEqual(frame.timestamp, 1.0)
        XCTAssertEqual(frame.dominantHand?.x, 0.4)
        XCTAssertEqual(frame.recordEdgeAngle, 12.5)
        XCTAssertEqual(frame.crossfaderPosition, 0.7)
    }

    func test_motionPrediction_holdsValuesVerbatim() {
        let p = ScratchMotionPrediction(label: .tears, confidence: 0.7, windowEnd: 4.2)
        XCTAssertEqual(p.label, .tears)
        XCTAssertEqual(p.confidence, 0.7)
        XCTAssertEqual(p.windowEnd, 4.2)
    }
}
