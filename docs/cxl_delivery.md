# CXL delivery preparation — 13 September 2026

The user requested a Mac, iPhone and Watch delivery plus a one-page setup/use guide. The local archives are prepared. App Store Connect records, uploads, processing, external beta review and invitations are **not complete**.

**Route change (13 September):** Karl now prefers TestFlight for the Mac as well. That supersedes the earlier Developer ID/notarized-download plan. A Developer ID certificate is not needed for this route.

## Intended delivery

- **Mac:** a separate **ScratchLab CXL** App Store Connect record distributed through TestFlight for Mac, retaining `com.machelpnz.scratchlab.cxl-authoring` and team `2DDKGL33BU`. Do not upload the general-purpose Mac app in its place.
- **iPhone and paired Watch:** one **ScratchLab** TestFlight invitation; the Watch app is embedded in the iPhone distribution. No device-ID collection is needed. Apple's first external beta review is required before an external tester can install.
- **Guide:** `docs/cxl_one_page_guide.md`, rendered and visually checked as one A4 PDF. Install now tells CXL to use TestFlight on both Mac and iPhone.

CXL uses his own Apple Account. Continuity Camera requires the Mac and iPhone to share that account with two-factor authentication. The Watch is paired with his iPhone. Do not share Karl's account or credentials.

## Prepared artifacts

Root: `/Users/karlwatson/Developer/ScratchLab-CXL-Handoff-20260913`. Read `NEXT_STEPS_AFTER_SIGN_IN.md` there first.

| Artifact | Current state |
| --- | --- |
| `package/ScratchLab CXL Quick Start.pdf` | One page, TestFlight install route. The earlier version is kept as `(superseded download route)` |
| `archives/ScratchLab-CXL-Mac.xcarchive` | CXLRelease archive, version 1.0.1/build 21, stable Xcode 26.6/macOS 26.5 SDK, universal, minimum macOS 15, App Sandbox plus existing entitlements, Apple Development signed pending distribution export; **not exported or uploaded** |
| `archives/ScratchLab-iOS-Watch.xcarchive` | Release archive, version 1.0.1/build 22, stable Xcode 26.6 |
| `testflight-export/ScratchLab.ipa` | Apple Distribution export of iPhone plus embedded Watch; **not uploaded** |
| `package/ScratchLab-CXL-Mac-Pilot-development-signed.zip` | Internal Apple Development pilot only; superseded for CXL delivery by the TestFlight route |
| `TESTFLIGHT_BETA_INFO_APPROVED.md` | Karl-approved beta description, what-to-test, reviewer notes and Mac record details |

The iPhone/Watch artifacts come from source `dcd7a7686575c2d7ca505677d8eb9130d60aa3d3`. The Mac archive was built from `7afb2e0`, which differs from `dcd7a76` only in documentation and handoff files. iPhone/Watch are version 1.0.1/build 22 with minimums iOS 26.5 and watchOS 10. The project build numbers were not changed.

Both exported iPhone/Watch profiles have `get-task-allow=false` and no registered-device list. The Apple Distribution certificate is `C9B7542362B8993470B7B75F47A45C8F8E9F6FFA`. The 3rd Party Mac Developer Installer certificate `0A2B7B8A6510A60194E2DB4BD7CD84BE9BA524BF` for signing the Mac upload package is also present, both for team `2DDKGL33BU`. All 169 reference assets match manifest `5583667a…` in the exported iPhone app and the Mac archive. No personal capture library was packaged. The installed Mac app and blank capture library were not changed.

## Mac TestFlight route

- App Review Guideline 2.4.5 requires Mac App Store/TestFlight apps to be sandboxed, packaged with Xcode and self-contained. The CXL entitlements file already enables App Sandbox with camera, audio input, user-selected read-write files and network client/server (local network relay and companion camera). No entitlement or capability was removed or added. MIDI, audio process tap and Bonjour usage descriptions are unchanged.
- The installed pilot was built with an Xcode 27 beta SDK, which App Store Connect does not accept. The distribution archive was therefore rebuilt with stable Xcode 26.6.
- No Mac App Store profile exists for `com.machelpnz.scratchlab.cxl-authoring`. The local export attempt failed with `No Accounts` / `No profiles … were found` because Xcode has no signed-in account. Automatic export signing with a signed-in team account should create the profile.
- Build 21 is suitable only for a new app record with no existing builds; check ASC first.

## Remaining steps before sending

1. Karl signs in to Xcode 26.6 and App Store Connect on Apple's own screens; never enter credentials in chat. The local API key `M6C29AZTW5` also needs its non-secret Issuer ID before command-line use.
2. Check the existing ScratchLab record's builds; upload the IPA if build 22 is unused, otherwise re-archive with a higher build.
3. Create the ScratchLab CXL macOS record if none exists, export/upload the Mac archive, and confirm both builds finish processing (the iPhone build must list the Watch app).
4. Enter the approved beta text, reuse existing beta review contact, feedback and privacy values (ask if empty), add each build to an external group without testers, and submit for Beta App Review.
5. Obtain CXL's tester email and device/OS versions; send invitations only when Karl asks.
6. Confirm installation on CXL's Mac and one short actual-rig recording, playback and export before a batch. Portrait/second-camera/Watch relay and Seventy-Two/Twelve routing remain operator checks. The guide explains the optional Watch limitation when the same iPhone is also a Continuity Camera.

## Packaging notes

This was distribution/documentation work; no app source was changed, no new hardware recordings were made and no broad XCTest gate was repeated. Existing software-gate results remain separate from physical acceptance.

For archives, set `-IDEBuildLocationStyle=Unique` for the command only, with an isolated `-derivedDataPath`; global Xcode `Custom` build locations broke the first iPhone archive. Do not override `SYMROOT`/`OBJROOT`. Export signing must be automatic; manually selected Xcode-managed Store profiles were rejected. Commands, logs and failed-attempt logs are under `evidence/` and `mac-testflight/evidence/`.

Apple instructions: [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [App Review Guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/#2.4.5), [external beta invitations and review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers), [Continuity Camera prerequisites](https://support.apple.com/en-us/102546).
