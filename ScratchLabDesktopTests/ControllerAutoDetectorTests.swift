import XCTest
@testable import ScratchLab

final class ControllerAutoDetectorTests: XCTestCase {

    private let catalog = ControllerProfileCatalog.shared

    // MARK: - Exact name matching

    func testDDJFLX10ExactMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "DDJ-FLX10", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "alphatheta.ddj-flx10")
    }

    func testDDJFLX10PioneerPrefixMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "Pioneer DDJ-FLX10", in: catalog)
        XCTAssertEqual(result?.profile.id, "alphatheta.ddj-flx10")
    }

    func testDDJFLX10AlphaThetaPrefixMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "AlphaTheta DDJ-FLX10", in: catalog)
        XCTAssertEqual(result?.profile.id, "alphatheta.ddj-flx10")
    }

    func testTWELVEMKIIMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "TWELVE MKII", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "rane.twelve-mkii")
    }

    func testDJMDashS9Match() {
        let result = ControllerAutoDetector.resolve(endpointName: "DJM-S9", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "alphatheta.djm-s9")
        XCTAssertEqual(result?.profile.deviceClass, .faderPrimary)
    }

    func testReloopReadyMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "Reloop Ready", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "reloop.ready")
    }

    func testReloopEliteMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "Reloop Elite", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "reloop.elite")
    }

    // MARK: - Alias / alternate endpoint name matching

    func testDDJFLX10AlternateSpelling() {
        // DDJFLX10 without hyphen
        let result = ControllerAutoDetector.resolve(endpointName: "DDJFLX10", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "alphatheta.ddj-flx10")
    }

    func testTWELVEMK2Variant() {
        let result = ControllerAutoDetector.resolve(endpointName: "TWELVE MK2", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "rane.twelve-mkii")
    }

    func testRaneONEMKIIMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "RANE ONE MKII", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "rane.one-mkii")
    }

    func testNS7IIIMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "NS7III", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "numark.ns7iii")
    }

    func testHerculesInpulseT7Match() {
        let result = ControllerAutoDetector.resolve(endpointName: "DJControl Inpulse T7", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "hercules.inpulse-t7")
    }

    func testTraktroS4MK3Match() {
        let result = ControllerAutoDetector.resolve(endpointName: "Traktor Kontrol S4 MK3", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "ni.traktor-s4-mk3")
    }

    func testAkaiAMXMatch() {
        let result = ControllerAutoDetector.resolve(endpointName: "Akai AMX", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "akai.amx")
    }

    // MARK: - Unknown device handling

    func testUnknownEndpointReturnsNil() {
        let result = ControllerAutoDetector.resolve(endpointName: "XYZ Firmware MIDI 9000", in: catalog)
        XCTAssertNil(result, "Unrecognised endpoint should return nil from resolve()")
    }

    func testGenericSessionForUnknownEndpoint() {
        let session = ControllerAutoDetector.genericSession(endpointName: "XYZ Firmware MIDI 9000")
        XCTAssertEqual(session.profile.id, "generic.unknown")
        XCTAssertTrue(session.requiresVerification)
    }

    func testUnknownDevicePublicLabelIsGeneric() {
        let session = ControllerAutoDetector.genericSession(endpointName: "XYZ MIDI 9000")
        XCTAssertEqual(session.profile.publicDisplayFamily, "Detected MIDI Device")
    }

    func testUnknownDeviceCannotFeedScoringBeforeVerification() {
        let session = ControllerAutoDetector.genericSession(endpointName: "XYZ MIDI 9000")
        XCTAssertFalse(session.profile.canFeedScoringAfterVerification)
    }

    // MARK: - UI naming safety

    func testDetectionResultPublicSubtitleIsNotBrandFacing() {
        let result = ControllerAutoDetector.resolve(endpointName: "DDJ-FLX10", in: catalog)
        // The publicDisplayFamily must not expose brand mode names.
        let family = result?.profile.publicDisplayFamily ?? ""
        XCTAssertFalse(family.contains("Pioneer Mode"))
        XCTAssertFalse(family.contains("AlphaTheta Mode"))
        XCTAssertFalse(family.contains("Official"))
    }

    func testTechnicalDetailMayShowActualEndpointName() {
        // The spec permits showing the actual endpoint name in technical detail rows.
        // Verify the profile's internalModel exposes the device name for technical rows.
        let result = ControllerAutoDetector.resolve(endpointName: "DDJ-FLX10", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.internalModel, "DDJ-FLX10")
    }

    // MARK: - Verification requirement

    func testDDJFLX10RequiresVerification() {
        let result = ControllerAutoDetector.resolve(endpointName: "DDJ-FLX10", in: catalog)
        XCTAssertEqual(result?.requiresVerification, true)
    }

    func testDetectionOnlyDeviceRequiresVerification() {
        let result = ControllerAutoDetector.resolve(endpointName: "DDJ-REV7", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.requiresVerification, true)
    }

    // MARK: - Motorized / Rane class

    func testMotorisedPlatterProfileCanExistWithoutBreakingCapture() {
        let result = ControllerAutoDetector.resolve(endpointName: "TWELVE MKII", in: catalog)
        XCTAssertNotNil(result, "Motorized platter profile must be detectable")
        XCTAssertEqual(result?.profile.mappingStatus, .detectionOnly,
            "Motorized profile is detection-only until binding-list is sourced")
    }

    func testMotorisedPlatterCannotFeedScoringBeforeVerification() {
        guard let result = ControllerAutoDetector.resolve(endpointName: "TWELVE MKII", in: catalog) else {
            XCTFail("TWELVE MKII not found"); return
        }
        XCTAssertFalse(result.profile.canFeedScoringAfterVerification,
            "Detection-only motorized profile must not feed scoring")
    }

    // MARK: - Reloop class

    func testReloopProfileCanExistWithoutBreakingCapture() {
        let result = ControllerAutoDetector.resolve(endpointName: "Reloop Mixon 8 Pro", in: catalog)
        XCTAssertNotNil(result)
    }

    func testReloopProfileCannotFeedScoringWithoutVerification() {
        guard let result = ControllerAutoDetector.resolve(endpointName: "Reloop Mixon 8 Pro", in: catalog) else {
            XCTFail(); return
        }
        XCTAssertFalse(result.profile.canFeedScoringAfterVerification)
    }
}
