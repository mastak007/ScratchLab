import XCTest
@testable import ScratchLabML

final class ScratchClassLabelTests: XCTestCase {

    func test_allCases_haveUniqueRawValues() {
        let raws = ScratchClassLabel.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "Class label rawValues must be unique")
    }

    func test_allCases_haveNonEmptyDisplayNames() {
        for label in ScratchClassLabel.allCases {
            XCTAssertFalse(label.displayName.isEmpty,
                "displayName must be set for \(label.rawValue)")
        }
    }

    func test_initFromModelLabel_acceptsKnownStrings() {
        XCTAssertEqual(ScratchClassLabel(modelLabel: "baby"), .baby)
        XCTAssertEqual(ScratchClassLabel(modelLabel: "1clickflare"), .oneClickFlare)
        XCTAssertEqual(ScratchClassLabel(modelLabel: "long_short_tips"), .longShortTips)
        XCTAssertEqual(ScratchClassLabel(modelLabel: "cresentflare"), .crescentFlare)
    }

    func test_initFromModelLabel_returnsNilForUnknown() {
        XCTAssertNil(ScratchClassLabel(modelLabel: "not_a_real_scratch"))
        XCTAssertNil(ScratchClassLabel(modelLabel: ""))
        XCTAssertNil(ScratchClassLabel(modelLabel: "BABY")) // case sensitive
    }

    func test_caseCountMatchesTrainedClassExpectation() {
        // The dataset folder set has 23 class labels; this guards against
        // accidental enum drift.
        XCTAssertEqual(ScratchClassLabel.allCases.count, 23)
    }
}
