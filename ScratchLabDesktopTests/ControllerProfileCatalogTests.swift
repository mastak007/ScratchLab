import XCTest
@testable import ScratchLab

final class ControllerProfileCatalogTests: XCTestCase {

    private let catalog = ControllerProfileCatalog.shared

    // MARK: - Catalog loading

    func testCompletProfilesLoad() {
        XCTAssertFalse(catalog.completeProfiles.isEmpty, "At least one complete profile must be present")
        XCTAssertTrue(catalog.completeProfiles.contains { $0.id == "alphatheta.ddj-flx10" })
    }

    func testPartialProfilesListIsPresent() {
        XCTAssertFalse(catalog.partialProfiles.isEmpty,
            "At least one partial profile (Rane ONE MKII) must be present")
        XCTAssertTrue(catalog.partialProfiles.contains { $0.id == "rane.one-mkii" })
    }

    func testDetectionOnlyProfilesLoad() {
        XCTAssertFalse(catalog.detectionOnlyProfiles.isEmpty)
        // Spot-check at least one stub per brand family.
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "alphatheta.ddj-rev7" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "rane.twelve-mkii" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "reloop.mixon-8-pro" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "denon.sc6000m" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "numark.ns7iii" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "hercules.inpulse-t7" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "ni.traktor-s4-mk3" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "allen-heath.xone-k2" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "akai.amx" })
        XCTAssertTrue(catalog.detectionOnlyProfiles.contains { $0.id == "novation.twitch" })
    }

    func testUnsupportedKnownDevicesListIsPresent() {
        XCTAssertNotNil(catalog.unsupportedKnownDevices)
    }

    func testAllProfilesHaveUniqueIDs() {
        let ids = catalog.allProfiles.map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "Duplicate profile IDs found: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }

    func testAllProfilesHaveNonEmptyPublicDisplayFamily() {
        for profile in catalog.allProfiles {
            XCTAssertFalse(profile.publicDisplayFamily.isEmpty, "\(profile.id) has empty publicDisplayFamily")
        }
    }

    // MARK: - Device class consistency

    func testDetectionOnlyProfilesDoNotFeedScoringWithoutVerification() {
        for profile in catalog.detectionOnlyProfiles where profile.mappingStatus == .detectionOnly {
            XCTAssertTrue(profile.verificationRequired,
                "\(profile.id): detection-only profile must require verification")
        }
    }

    // MARK: - Legal safety: no brand-facing mode names in publicDisplayFamily

    func testPublicDisplayFamilyContainsNoBrandModeNames() {
        let forbiddenTerms = [
            "Pioneer Mode", "AlphaTheta Mode", "Rane Mode", "Reloop Mode",
            "Denon Mode", "Numark Mode", "Hercules Mode", "Native Instruments Mode",
            "Official", "Certified", "Endorsed", "Partnership", "Affiliated"
        ]
        for profile in catalog.allProfiles {
            for term in forbiddenTerms {
                XCTAssertFalse(
                    profile.publicDisplayFamily.contains(term),
                    "\(profile.id).publicDisplayFamily contains forbidden term: '\(term)'"
                )
            }
        }
    }

    func testDisclaimerStringIsPresent() {
        let disclaimer = ControllerProfileCatalog.controllerSettingsDisclaimer
        XCTAssertFalse(disclaimer.isEmpty)
        XCTAssertTrue(disclaimer.contains("independent"), "Disclaimer must state independence")
        XCTAssertTrue(disclaimer.contains("not endorsed"), "Disclaimer must state non-endorsement")
    }

    // MARK: - Motorized platter class tagging

    func testMotorisedPlatterControllersTaggedScratchPrimary() {
        let motorized = catalog.detectionOnlyProfiles.filter { $0.profileKind == .motorizedPlatterController }
        XCTAssertFalse(motorized.isEmpty, "At least one motorized platter stub expected")
        for profile in motorized {
            XCTAssertEqual(profile.deviceClass, .scratchPrimary,
                "\(profile.id): motorized platter controller should be scratchPrimary")
        }
    }

    func testBattleMixersTaggedFaderPrimary() {
        let mixers = catalog.detectionOnlyProfiles.filter { $0.profileKind == .battleMixer }
        XCTAssertFalse(mixers.isEmpty)
        for profile in mixers {
            XCTAssertTrue(
                profile.deviceClass == .faderPrimary || profile.deviceClass == .detectionOnly,
                "\(profile.id): battle mixer must be faderPrimary or detectionOnly"
            )
        }
    }

    // MARK: - Rane ONE / MKII cross-reference

    func testRaneOneMKIIPartialProfileInPartialList() {
        guard let stub = catalog.partialProfiles.first(where: { $0.id == "rane.one-mkii" }) else {
            XCTFail("Rane ONE MKII partial profile not found in partialProfiles")
            return
        }
        XCTAssertEqual(stub.sourceConfidence, .highThirdPartyMapping)
        XCTAssertEqual(stub.mappingStatus, .partial)
        XCTAssertTrue(stub.assumptions.contains { $0.contains("MIDIHardwareRegistry") },
            "Profile must reference MIDIHardwareRegistry as the platter binding source")
        XCTAssertTrue(stub.sourceNotes.contains("uploadedDjayMapping"),
            "sourceNotes must record the djay mapping source type")
    }

    func testRaneOneMKIINotInDetectionOnlyList() {
        let detectionIDs = catalog.detectionOnlyProfiles.map(\.id)
        XCTAssertFalse(detectionIDs.contains("rane.one-mkii"),
            "rane.one-mkii is now partial; it must not appear in detectionOnlyProfiles")
    }

    // MARK: - Generic unknown device

    func testGenericUnknownProfileForUnrecognisedEndpoint() {
        let result = ControllerAutoDetector.resolve(endpointName: "XYZ Unknown MIDI 9000", in: catalog)
        XCTAssertNil(result, "Unknown endpoint should not match any built-in profile")
        let generic = ControllerAutoDetector.genericSession(endpointName: "XYZ Unknown MIDI 9000")
        XCTAssertEqual(generic.profile.id, "generic.unknown")
        XCTAssertTrue(generic.requiresVerification)
    }

    func testUnknownDeviceCannotFeedScoringBeforeVerification() {
        let generic = ControllerAutoDetector.genericSession(endpointName: "XYZ Unknown")
        XCTAssertFalse(generic.profile.canFeedScoringAfterVerification,
            "Detection-only generic profile must not feed scoring")
    }
}
