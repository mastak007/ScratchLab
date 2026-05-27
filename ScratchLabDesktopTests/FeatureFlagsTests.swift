import XCTest
@testable import ScratchLab

final class FeatureFlagsTests: XCTestCase {

    // MARK: - Env-var override parsing

    func testEnvOverrideAcceptsOneAsTrue() {
        XCTAssertTrue(FeatureFlags.envOverride("EXAMPLE", environment: ["SCRATCHLAB_FF_EXAMPLE": "1"]) == true)
    }

    func testEnvOverrideAcceptsZeroAsFalse() {
        XCTAssertTrue(FeatureFlags.envOverride("EXAMPLE", environment: ["SCRATCHLAB_FF_EXAMPLE": "0"]) == false)
    }

    func testEnvOverrideAcceptsTextualBooleans() {
        XCTAssertTrue(FeatureFlags.envOverride("E", environment: ["SCRATCHLAB_FF_E": "true"])  == true)
        XCTAssertTrue(FeatureFlags.envOverride("E", environment: ["SCRATCHLAB_FF_E": "FALSE"]) == false)
        XCTAssertTrue(FeatureFlags.envOverride("E", environment: ["SCRATCHLAB_FF_E": "on"])    == true)
        XCTAssertTrue(FeatureFlags.envOverride("E", environment: ["SCRATCHLAB_FF_E": "off"])   == false)
    }

    func testEnvOverrideMissingKeyReturnsNil() {
        XCTAssertNil(FeatureFlags.envOverride("ABSENT", environment: [:]))
    }

    func testEnvOverrideUnparseableReturnsNil() {
        XCTAssertNil(FeatureFlags.envOverride("X", environment: ["SCRATCHLAB_FF_X": "maybe"]))
    }

    // MARK: - Default policy

    func testEnvOverrideWinsOverBuildDefaults() {
        XCTAssertTrue(FeatureFlags.isOn(
            "X",
            releaseDefault: false,
            debugDefault: false,
            environment: ["SCRATCHLAB_FF_X": "1"]
        ))
        XCTAssertFalse(FeatureFlags.isOn(
            "X",
            releaseDefault: true,
            debugDefault: true,
            environment: ["SCRATCHLAB_FF_X": "0"]
        ))
    }

    func testBuildConfigDefaultAppliesWhenEnvAbsent() {
        #if DEBUG
        XCTAssertTrue(FeatureFlags.isOn("X",  releaseDefault: false, debugDefault: true,  environment: [:]))
        XCTAssertFalse(FeatureFlags.isOn("X", releaseDefault: true,  debugDefault: false, environment: [:]))
        #else
        XCTAssertFalse(FeatureFlags.isOn("X", releaseDefault: false, debugDefault: true,  environment: [:]))
        XCTAssertTrue(FeatureFlags.isOn("X",  releaseDefault: true,  debugDefault: false, environment: [:]))
        #endif
    }
}
