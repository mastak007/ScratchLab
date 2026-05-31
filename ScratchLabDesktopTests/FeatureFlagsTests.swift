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

    // MARK: - Kid Mode prototype gate (Batch 1.6: dev-default-on)

    /// The flag's configured defaults: ON in DEBUG, OFF in release, with the
    /// env override still able to force either way. Uses the same KIDPROTOTYPE
    /// key + defaults as `FeatureFlags.kidPrototypeEnabled`.
    func testKidPrototypeDefaultsAndOverride() {
        // Env override forces on/off regardless of build config.
        XCTAssertTrue(FeatureFlags.isOn(
            "KIDPROTOTYPE", releaseDefault: false, debugDefault: true,
            environment: ["SCRATCHLAB_FF_KIDPROTOTYPE": "1"]))
        XCTAssertFalse(FeatureFlags.isOn(
            "KIDPROTOTYPE", releaseDefault: false, debugDefault: true,
            environment: ["SCRATCHLAB_FF_KIDPROTOTYPE": "0"]))

        // No override → build-config default: DEBUG on, release off.
        #if DEBUG
        XCTAssertTrue(FeatureFlags.isOn(
            "KIDPROTOTYPE", releaseDefault: false, debugDefault: true, environment: [:]))
        #else
        XCTAssertFalse(FeatureFlags.isOn(
            "KIDPROTOTYPE", releaseDefault: false, debugDefault: true, environment: [:]))
        #endif
    }

    /// Pin the real property: in a DEBUG test run with no env override set, the
    /// Kid Mode prototype flag must be on.
    func testKidPrototypeEnabledPropertyDefaultsOnInDebug() {
        guard ProcessInfo.processInfo.environment["SCRATCHLAB_FF_KIDPROTOTYPE"] == nil else {
            return // an explicit override is in effect; default not under test
        }
        #if DEBUG
        XCTAssertTrue(FeatureFlags.kidPrototypeEnabled)
        #else
        XCTAssertFalse(FeatureFlags.kidPrototypeEnabled)
        #endif
    }
}
