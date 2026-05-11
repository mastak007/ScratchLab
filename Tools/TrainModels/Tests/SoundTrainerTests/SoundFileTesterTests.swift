import XCTest
@testable import SoundTrainer

final class SoundFileTesterTests: XCTestCase {

    func test_loadModel_throwsForMissingFile() {
        let bogus = URL(fileURLWithPath: "/var/empty/no_such_model_\(UUID().uuidString).mlmodel")
        XCTAssertThrowsError(try SoundFileTester.loadModel(at: bogus)) { err in
            guard case SoundFileTesterError.modelNotFound = err else {
                return XCTFail("expected .modelNotFound, got \(err)")
            }
        }
    }

    func test_loadModel_throwsForUnsupportedExtension() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not_a_model_\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try SoundFileTester.loadModel(at: tmp)) { err in
            guard case SoundFileTesterError.unsupportedModelExtension(let ext) = err else {
                return XCTFail("expected .unsupportedModelExtension, got \(err)")
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    func test_classification_struct_holdsValuesVerbatim() {
        let c = SoundFileClassification(label: "baby", confidence: 0.81)
        XCTAssertEqual(c.label, "baby")
        XCTAssertEqual(c.confidence, 0.81, accuracy: 1e-9)
    }

    func test_prediction_struct_holdsValuesVerbatim() {
        let p = SoundFilePrediction(
            topLabel: "baby",
            topConfidence: 0.9,
            allClassifications: [
                .init(label: "baby", confidence: 0.9),
                .init(label: "tears", confidence: 0.05)
            ]
        )
        XCTAssertEqual(p.topLabel, "baby")
        XCTAssertEqual(p.topConfidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(p.allClassifications.count, 2)
        XCTAssertEqual(p.allClassifications.first?.label, "baby")
    }
}
