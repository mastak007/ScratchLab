# CXL delivery preparation — 13 September 2026

The user requested a Mac, iPhone and Watch delivery plus a one-page setup/use guide. **iPhone/Watch build 23 is uploaded and processed but not yet submitted for external beta review. The Mac app is archived but not uploaded.** No external group, tester or invitation exists for this delivery.

**Route change (13 September):** Karl now prefers TestFlight for the Mac as well. That supersedes the earlier Developer ID/notarized-download plan. A Developer ID certificate is not needed for this route.

## Intended delivery

- **Mac:** a separate **ScratchLab CXL** App Store Connect record distributed through TestFlight for Mac, retaining `com.machelpnz.scratchlab.cxl-authoring` and team `2DDKGL33BU`. Do not upload the general-purpose Mac app in its place.
- **iPhone and paired Watch:** one **ScratchLab** TestFlight invitation (ASC app `6761674709`); the Watch app is embedded in the iPhone distribution. No device-ID collection is needed. Apple's first external beta review is required before an external tester can install.
- **Guide:** `docs/cxl_one_page_guide.md`, rendered and visually checked as one A4 PDF. Install tells CXL to use TestFlight on both Mac and iPhone.

CXL uses his own Apple Account. Continuity Camera requires the Mac and iPhone to share that account with two-factor authentication. The Watch is paired with his iPhone. Do not share Karl's account or credentials.

## App Store Connect state

| Item | State |
| --- | --- |
| iPhone/Watch 1.0.1 **build 23** | Uploaded with `altool` (validation `VERIFY SUCCEEDED`); ASC build `6c121fee-cf50-4f6e-91a6-60745a19dff6`, processing `VALID`, non-exempt encryption false, expires 2026-12-11. External state `READY_FOR_BETA_SUBMISSION` (not submitted). Internal `IN_BETA_TESTING`: auto-added to the existing internal group |
| Watch in processed build | Verified inside the uploaded IPA; the ASC API lists only the iPhone bundle, so confirm in the App Store Connect build metadata |
| iPhone build 22 | ASC already had an unrelated 1.0.1 build 22 (2026-09-03); the prepared build 22 IPA was not uploaded and remains unchanged |
| Mac ScratchLab CXL | No bundle ID, profile or app record yet; archive ready, not exported or uploaded |
| Existing beta values | Review contact, feedback email and beta description are set; beta privacy URL empty (app privacy URL exists). The existing external "Pro DJs" group has a public link enabled — do not add CXL builds there |

API key `M6C29AZTW5` (team issuer) can read, validate and upload. Apple refuses its bundle ID registration, cloud signing/profile creation and TestFlight writes. App records cannot be created through the API. Key `WA9BQB34S6` has no private key file on this Mac.

## Prepared artifacts

Root: `/Users/karlwatson/Developer/ScratchLab-CXL-Handoff-20260913`. Read `NEXT_STEPS_AFTER_SIGN_IN.md` there first.

| Artifact | Current state |
| --- | --- |
| `package/ScratchLab CXL Quick Start.pdf` | One page, TestFlight install route. The earlier version is kept as `(superseded download route)` |
| `archives/ScratchLab-iOS-Watch-build23.xcarchive`, `ios-build23/testflight-export/ScratchLab.ipa` | Uploaded build 23: stable Xcode 26.6, iPhone and Watch Apple Distribution signed, `get-task-allow=false`, no device list, 169/169 assets; receipt `ios-build23/evidence/upload-receipt.json` |
| `archives/ScratchLab-CXL-Mac.xcarchive` | CXLRelease archive, version 1.0.1/build 21, stable Xcode 26.6/macOS 26.5 SDK, universal, minimum macOS 15, App Sandbox plus existing entitlements, Apple Development signed pending distribution export; **not exported or uploaded** |
| `archives/ScratchLab-iOS-Watch.xcarchive`, `testflight-export/ScratchLab.ipa` | Original build 22 candidate; unusable for upload because the number is taken; kept unchanged |
| `package/ScratchLab-CXL-Mac-Pilot-development-signed.zip` | Internal Apple Development pilot only; superseded for CXL delivery by the TestFlight route |
| `TESTFLIGHT_BETA_INFO_APPROVED.md` | Karl-approved beta description, what-to-test, reviewer notes and Mac record details |

Build 22 artifacts come from `dcd7a7686575c2d7ca505677d8eb9130d60aa3d3`. The Mac and build 23 archives were built from later commits that differ from it only in documentation and handoff files. Minimums are iOS 26.5, watchOS 10 and macOS 15. The project build numbers were not changed; build 23 used a command-line `CURRENT_PROJECT_VERSION=23`.

The Apple Distribution certificate `C9B7542362B8993470B7B75F47A45C8F8E9F6FFA` and 3rd Party Mac Developer Installer certificate `0A2B7B8A6510A60194E2DB4BD7CD84BE9BA524BF` match the serials listed in App Store Connect for team `2DDKGL33BU`. No personal capture library was packaged. The installed Mac app and blank capture library were not changed.

## Mac TestFlight route

- App Review Guideline 2.4.5 requires Mac App Store/TestFlight apps to be sandboxed, packaged with Xcode and self-contained. The CXL entitlements file already enables App Sandbox with camera, audio input, user-selected read-write files and network client/server (local network relay and companion camera). No entitlement or capability was removed or added. MIDI, audio process tap and Bonjour usage descriptions are unchanged.
- The installed pilot was built with an Xcode 27 beta SDK, which App Store Connect does not accept. The distribution archive was therefore rebuilt with stable Xcode 26.6.
- Export attempts failed:
  - without any account: `No Accounts` / `No profiles … were found`
  - with key M6C29AZTW5: `Cloud signing permission error`
- The bundle ID, profile and app record need an Admin-capable sign-in or the website. Build 21 is suitable for the new app record.

## Remaining steps before sending

1. In App Store Connect, confirm build 23's metadata lists the Watch app.
2. Enter the approved beta text and reviewer notes. Create a new external group without testers or public link, add build 23 and submit for Beta App Review. Record the resulting state.
3. Register `com.machelpnz.scratchlab.cxl-authoring` and create the ScratchLab CXL macOS app record on the website.
4. With Xcode signed in or an Admin API key on this Mac, export and upload the Mac archive. After processing, complete its beta information, add it to an external group and submit for review.
5. Obtain CXL's tester email and device/OS versions; send invitations only when Karl asks.
6. Confirm installation on CXL's Mac and one short actual-rig recording, playback and export before a batch. Portrait/second-camera/Watch relay and Seventy-Two/Twelve routing remain operator checks. The guide explains the optional Watch limitation when the same iPhone is also a Continuity Camera.

## Packaging notes

This was distribution/documentation work; no app source was changed, no new hardware recordings were made and no broad XCTest gate was repeated. Existing software-gate results remain separate from physical acceptance.

For archives, set `-IDEBuildLocationStyle=Unique` for the command only, with an isolated `-derivedDataPath`; global Xcode `Custom` build locations broke the first iPhone archive. Do not override `SYMROOT`/`OBJROOT`. iPhone export signing must be automatic; it works offline with the existing Xcode-managed Store profiles, while manually selected profiles were rejected. The 2.4 GB IPA upload took 5.3 hours at about 1 Mbps. Commands, logs and failed-attempt logs are under `evidence/`, `ios-build23/evidence/` and `mac-testflight/evidence/`.

Apple instructions: [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app), [App Review Guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/#2.4.5), [external beta invitations and review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers), [Continuity Camera prerequisites](https://support.apple.com/en-us/102546).
