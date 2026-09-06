// LegacyReferenceInventory — the bundled reference recordings that shipped
// before crossfader calibration existed, and the reason each is withdrawn.
//
// Product decision, 2026-09-04: every one of these is DEPRECATED and untrusted
// for training. They were recorded and exported while capture normalized the
// crossfader as `raw / 127`, assuming the fader spans its full physical range.
// It does not: a right-deck cut on a RANE ONE MKII runs centre-to-left, so
// those takes' derived fader events were classified against a compressed axis.
// The 2026-09-04 baby-scratch export is the worked example — 826 crossfader
// samples over raw 0…52, and 12 of 20 derived events unclassifiable.
//
// Nothing here is deleted. The files stay in the bundle so an approved
// replacement can be compared against what it replaces, and so no asset is
// destroyed before its replacement exists. They are simply not servable: the
// registry lists them under `deprecatedAssets`, which is a dead end — there is
// no code path from a deprecated asset to playback.
//
// When CXL's re-records are approved and imported, the developer import step
// adds entries; only then does `ReferenceRegistry.resolve` start returning
// `.available`. Removing an entry from this list is NOT how a technique
// becomes trainable.
//
// Foundation only.

import Foundation

enum LegacyReferenceInventory {

    /// Bundle-relative directories holding pre-calibration reference audio.
    static let deprecatedResourceDirectories = [
        "reference_champ",
        "reference_pro",
        "reference_beginner",
        "PracticeReelAudio"
    ]

    /// The withdrawn assets, named individually so the audit trail records
    /// exactly what was pulled and when.
    ///
    /// `technique` is `nil` where the legacy asset was never filed against a
    /// specific technique. A `nil` technique still cannot be served — it just
    /// cannot be used to explain a particular technique's absence either.
    static func deprecatedAssets(deprecatedAt: Date) -> [DeprecatedReferenceAsset] {
        var assets: [DeprecatedReferenceAsset] = []

        // Previously the app's best-labeled baby-scratch bundle. Withdrawn on
        // the same terms as everything else here: recorded before crossfader
        // calibration existed, so its fader stream cannot be trusted, and it
        // is not to be treated as a correct example of the technique pending
        // CXL's re-record and explicit approval.
        for index in 1...4 {
            let name = String(format: "cxl_clean_%02d", index)
            assets.append(
                DeprecatedReferenceAsset(
                    assetID: "reference_champ/\(name)",
                    technique: .babyScratch,
                    resourcePath: "reference_champ/\(name).wav",
                    reason: .uncalibratedCrossfader,
                    deprecatedAt: deprecatedAt
                )
            )
        }

        for index in 1...8 {
            let name = String(format: "pro_reference_%02d", index)
            assets.append(
                DeprecatedReferenceAsset(
                    assetID: "reference_pro/\(name)",
                    technique: nil,
                    resourcePath: "reference_pro/\(name).wav",
                    reason: .uncalibratedCrossfader,
                    deprecatedAt: deprecatedAt
                )
            )
        }

        // The bundled call-and-response reel bakes its response gaps into the
        // recording, which is the second reason it cannot be the model for
        // call-and-response training: the response window is now generated at
        // playback time by `CallAndResponseSchedule`.
        assets.append(
            DeprecatedReferenceAsset(
                assetID: "PracticeReelAudio/baby_reel_callresponse",
                technique: .babyScratch,
                resourcePath: "PracticeReelAudio/baby_reel_callresponse.wav",
                reason: .uncalibratedCrossfader,
                deprecatedAt: deprecatedAt
            )
        )

        return assets
    }

    /// The registry this build ships with: nothing servable, every legacy
    /// asset withdrawn, the full training set awaiting re-record.
    ///
    /// This is the "never silently fall back" rule expressed as data. A build
    /// that has imported no approved package resolves every technique to
    /// `.awaitingReRecord` or `.unavailable`, and the training UI says so.
    static func withdrawnBaselineRegistry(now: Date = Date()) -> ReferenceRegistry {
        ReferenceRegistry(
            document: .withdrawnLegacyBaseline(
                deprecatedAssets: deprecatedAssets(deprecatedAt: now),
                generatedAt: now
            )
        )
    }
}
