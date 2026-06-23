import Foundation

// MARK: - Local Verified Override Profile

/// A user-generated profile produced by guided MIDI verification capture.
/// Must NOT overwrite sourced built-in profiles.
struct LocalVerifiedProfile: Codable, Equatable {
    let localProfileID: String
    let baseProfileID: String?
    let detectedDeviceName: String
    let capturedEndpointID: String
    let verifiedControls: [String]
    let warnings: [String]
    let createdAt: Date
    let appVersion: String

    var displayLabel: String { "Local override – \(detectedDeviceName)" }
}

// MARK: - Detection Result

struct ControllerDetectionResult: Equatable {
    let profile: ControllerProfile
    let matchedFragment: String?
    let requiresVerification: Bool

    var publicStatusLine: String {
        switch profile.mappingStatus {
        case .complete, .partial:
            return requiresVerification ? "Verification required" : "Profile loaded"
        case .detectionOnly:
            return "Controller detected. No verified scratch-motion profile yet."
        case .liveVerifiedLocalOnly:
            return "Using local verified profile"
        case .unsupported:
            return "Controller detected (not supported for scratch capture)"
        }
    }
}

// MARK: - Auto-Detector

/// Pure name-matching auto-detector. No CoreMIDI, no I/O.
enum ControllerAutoDetector {

    /// Resolve the best-matching profile for a given MIDI endpoint display name.
    /// Returns nil when no match is found (caller should use the generic-unknown stub).
    static func resolve(
        endpointName: String,
        in catalog: ControllerProfileCatalog
    ) -> ControllerDetectionResult? {
        let lower = endpointName.lowercased()

        // 1. Exact profile match (search in priority order: complete → partial → detectionOnly).
        let prioritized = catalog.allProfiles
        for profile in prioritized {
            for name in profile.matchNames {
                if lower.contains(name.lowercased()) {
                    return ControllerDetectionResult(
                        profile: profile,
                        matchedFragment: name,
                        requiresVerification: profile.verificationRequired
                    )
                }
            }
        }
        return nil
    }

    /// Classify a bare endpoint name with no matching profile.
    static func genericSession(endpointName: String) -> ControllerDetectionResult {
        ControllerDetectionResult(
            profile: ControllerProfileCatalog.genericUnknownProfile(endpointName: endpointName),
            matchedFragment: nil,
            requiresVerification: true
        )
    }
}

// MARK: - Catalog

/// Immutable catalog of all built-in controller profiles.
/// Profiles are divided by mapping status; local overrides are kept separately.
struct ControllerProfileCatalog {

    let completeProfiles: [ControllerProfile]
    let partialProfiles: [ControllerProfile]
    let detectionOnlyProfiles: [ControllerProfile]
    let unsupportedKnownDevices: [ControllerProfile]
    var localVerifiedProfiles: [LocalVerifiedProfile]

    // Profiles searched in precedence order during auto-detection.
    var allProfiles: [ControllerProfile] {
        completeProfiles + partialProfiles + detectionOnlyProfiles + unsupportedKnownDevices
    }

    // MARK: Shared instance

    static let shared: ControllerProfileCatalog = .build()

    // MARK: Factory

    static func build() -> ControllerProfileCatalog {
        ControllerProfileCatalog(
            completeProfiles: [
                .ddj_flx10
            ],
            partialProfiles:
                RaneControllerProfiles.partialProfiles,
            detectionOnlyProfiles:
                AlphaThetaProfiles.detectionStubs
                + RaneControllerProfiles.stubs
                + ReloopProfiles.stubs
                + OtherDJProfiles.stubs,
            unsupportedKnownDevices: [],
            localVerifiedProfiles: []
        )
    }

    // MARK: Generic unknown device

    static func genericUnknownProfile(endpointName: String) -> ControllerProfile {
        ControllerProfile(
            id: "generic.unknown",
            internalManufacturer: "",
            internalModel: "",
            publicDisplayFamily: "Detected MIDI Device",
            matchNames: [],
            deviceNameRegexes: [],
            profileKind: .compactDJController,
            deviceClass: .detectionOnly,
            mappingStatus: .detectionOnly,
            sourceConfidence: .unknown,
            verificationRequired: true,
            deckCount: 0,
            physicalDeckCount: 0,
            bindings: [],
            verificationSteps: [],
            assumptions: ["No built-in profile found; requires guided MIDI capture verification."],
            sourceNotes: "Auto-detected endpoint: \(endpointName)",
            sourceURLs: [],
            lastCheckedDate: ""
        )
    }

    // MARK: Legal disclaimer

    static let controllerSettingsDisclaimer =
        "Product names are used only to identify connected MIDI devices. " +
        "ScratchLab is independent and is not endorsed by or affiliated with any hardware manufacturer."
}
