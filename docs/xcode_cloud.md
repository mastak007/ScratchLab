# Xcode Cloud for ScratchLab

Use the dedicated `codex/xcode-cloud-setup-20260913` branch while validating setup. The initial timing candidate (`d86a369`) failed independent review. This branch includes the verified origin correction from `235abb8`; remaining capture audit findings still need separate closure. Keep the CXL capture product separate from the full learner app. No tester invitations or public releases are part of this setup.

## Configured manual workflows

| Workflow | Scheme | Action | Start condition |
| --- | --- | --- | --- |
| CXL Mac build | ScratchLabCXL | macOS build using CXLRelease | Manual initially |
| iPhone and Watch build | ScratchLab | iOS build; existing embedded Watch dependency | Manual initially |
| Capture regressions | ScratchLabDesktop | macOS test, ScratchLabCloudCapture test plan | Manual initially |

These verification workflows share the ScratchLab Cloud source product and use Xcode 26.6 with macOS 26.6.2. The CXL scheme retains its separate bundle identity; the apps are not combined. CXL archive/TestFlight distribution will need its own Cloud product associated with the separate CXL app record. Start with the included compute allowance; do not purchase a higher plan or enable all-branch builds. When the first builds pass, enable branch-specific checks after reviewing usage. TestFlight distribution is a separate deliberate postaction and requires an archive and correct app record/build number.

## Private reference library

The source repository is public; reference media is deliberately not committed there. `ci_scripts/reference-library.lock.json` pins an exact commit of the private `mastak007/ScratchLab-ReferenceAssets` repository. `ci_scripts/ci_post_clone.sh` fetches that commit using Xcode Cloud's authorized Git access, verifies the manifest, provenance and every asset, and places it at the existing `LocalReferenceLibrary/ReferenceExamples` resource path. It then runs the existing Python capture fixtures.

Grant Xcode Cloud access only to the app repository and this private dependency. Do not paste a personal GitHub token into source or build logs. A missing permission or changed asset must fail the build; never substitute an empty library. Local developers can retain their existing library symlink: preparation verifies it and does not overwrite it.

Update the private dependency intentionally, review its source/content and verification receipt, then change the pinned commit and manifest SHA in one reviewable source change. This setup does not rebuild media, relabel examples, approve captures or train models.

## Verification boundary

The Cloud capture plan selects 15 affected classes, with one configuration to avoid duplicate execution. It is a focused regression gate, not the full test suite or a physical rig test. The selection includes the independent timing regressions and exact beat-export tests missed by the earlier local gate. Hardware-dependent test skips remain visible. Retain the broader local gate and a short real camera/audio/MIDI/Watch capture-to-export check before CXL delivery.

## Current activation status

Source access is connected. ScratchLab Cloud product `4ABF7852-6C7E-45C8-B7AD-FAD2040DBEF4` has these workflows, all inactive until the private dependency is fully uploaded:

- iPhone and Watch build: `8AB7AEE3-668E-47A7-8DFB-3C2A973CE90D`
- CXL Mac build: `429b3ceb-089d-4e31-873c-b10cb1e896b0`
- Capture regressions: `f30de045-bce3-4623-baeb-333218c64cc7`

Manual starts are restricted to the setup branch. No automatic branch/tag/pull-request/schedule trigger or distribution postaction is configured. Private repository access is granted. The asset upload is still in progress; no successful remote build is claimed. A one-time completion runner in the local evidence folder waits for the exact dependency and source commits, runs the workflows sequentially, and verifies executed test counts before recording completion. The CXL Mac App Store Connect record is `6811514515`, bundle `com.machelpnz.scratchlab.cxl-authoring`. See AI_HANDOFF.md for the current evidence and remaining activation steps.
