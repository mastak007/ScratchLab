# CXL delivery preparation — 13 September 2026

The user requested a Mac, iPhone and Watch delivery plus a one-page setup/use guide. The local packages are prepared. External installation, TestFlight upload/review/invitation and Mac notarization are **not complete**.

## Intended delivery

- **Mac:** a Developer ID signed, notarized download named **ScratchLab CXL**, retaining `com.machelpnz.scratchlab.cxl-authoring` and team `2DDKGL33BU`.
- **iPhone and paired Watch:** one **ScratchLab** TestFlight invitation; the Watch app is embedded in the iPhone distribution. No device-ID collection is needed for the intended TestFlight route. Apple's first external beta review may be required before the tester can install.
- **Guide:** `docs/cxl_one_page_guide.md`, rendered and visually checked as one A4 PDF. The final PDF is in the local package directory below.

CXL uses his own Apple Account. Continuity Camera requires the Mac and iPhone to share that account with two-factor authentication. The Watch is paired with his iPhone. Do not share Karl's account or credentials.

## Prepared artifacts

Root: `/Users/karlwatson/Developer/ScratchLab-CXL-Handoff-20260913`.

| Artifact | Current state |
| --- | --- |
| `package/ScratchLab CXL Quick Start.pdf` | One page; prerequisites, installation, optional cameras/Watch, audio check, four attempts, review and export |
| `package/ScratchLab-CXL-Mac-Pilot-development-signed.zip` | Internal pilot candidate only; Apple Development signed, **not** Developer ID notarized; external Mac installation unverified |
| `archives/ScratchLab-iOS-Watch.xcarchive` | Successful Release archive using stable Xcode 26.6 |
| `testflight-export/ScratchLab.ipa` | Successfully exported and verified Apple Distribution signatures for both iPhone and embedded Watch; **not uploaded**, and not a directly installable tester ZIP |

Source is `dcd7a7686575c2d7ca505677d8eb9130d60aa3d3`. Mac is version 1.0.1/build 21, universal Intel/Apple silicon, minimum macOS 15. iPhone/Watch are version 1.0.1/build 22, minimum iOS 26.5/watchOS 10. Build 22 is a local candidate; check App Store Connect's existing builds before upload. The project build number was not changed.

Both exported iPhone/Watch profiles have `get-task-allow=false` and no registered-device list. The selected Apple Distribution certificate is `C9B7542362B8993470B7B75F47A45C8F8E9F6FFA`, team `2DDKGL33BU`. All 169 reference assets match their manifest hashes in the staged Mac and archived/exported iPhone apps. No personal capture library was packaged. The Mac code-directory hashes match the installed app for both architectures; re-signing changes the executable file hash through its signature.

Evidence includes `delivery-files.json`, `exported-ipa-verification.json`, `bundled-library-verification.json`, `mac-stage.json`, archive/export logs and the staging receipt. The Mac ZIP passes CRC and contains the exact final guide PDF. The installed Mac app and blank capture library were not changed.

## Remaining steps before sending

1. Karl signs in to Apple on the opened App Store Connect page. No authenticated session was available during preparation. Enter credentials on Apple's page, never in chat. Check the existing app record, build numbers, beta details and any outstanding account agreements.
2. Confirm CXL's Mac/iPhone/Watch models and OS versions meet the built minimums. Obtain the email address he wants to use for TestFlight. These details are still pending.
3. Validate and upload the prepared iPhone archive/IPA to its existing app record, complete the actual export-compliance/beta-review fields, and obtain any required external beta review. Prepare the tester invitation for the supplied recipient; no invitation has been sent.
4. Finish Mac distribution signing. The current keychain has Apple Development and Apple Distribution identities, but **no Developer ID Application identity**. Obtain a valid Developer ID Application certificate from the existing team using the account's authorized certificate-management flow. The current staging helper binds a WWDR requirement for development signing; do not simply pass a Developer ID certificate into that unchanged helper. Use an appropriate Developer ID requirement, hardened runtime, secure timestamp and distribution entitlements, then notarize, staple and assess the final ZIP. Do not weaken Gatekeeper or reuse ad hoc signing.
5. Confirm installation on CXL's Mac and one short actual-rig recording, playback and export before a batch. Portrait/second-camera/Watch relay and Seventy-Two/Twelve routing remain operator checks. The one-page guide explains the optional Watch limitation when the same iPhone is also a Continuity Camera.

## Packaging notes

This was distribution/documentation work; no app source was changed, no new hardware recordings were made and no broad XCTest gate was repeated. Existing software-gate results remain separate from physical acceptance.

The first archive compiled but failed assembling `BuildProductsPath`: Xcode's global `IDEBuildLocationStyle=Custom` overrode the intended archive location. The successful invocation sets `-IDEBuildLocationStyle=Unique` for this command only, with an isolated `-derivedDataPath`; global Xcode preferences were not changed. Keep the archive's own generated product/intermediate structure rather than overriding `SYMROOT`/`OBJROOT` inconsistently.

The first local export rejected manually selected Xcode-managed Store profiles. Using automatic export signing selected the existing valid Apple Distribution identity and the correct Store profiles for both targets. Both successful commands and rejected-attempt logs are retained under `evidence/`. No upload was attempted without account visibility.

Apple instructions: [TestFlight installation, including Watch](https://testflight.apple.com/), [external beta invitations and review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers), [Developer ID distribution](https://developer.apple.com/developer-id/), [Continuity Camera prerequisites](https://support.apple.com/en-us/102546).
