# CXL pilot repair installed — 2026-09-12

## Current state and scope

Use only /Users/karlwatson/.codex/worktrees/35b5/ScratchLab, branch codex/cxl-pilot-checks-20260912. Baseline e83401ff4287cbba7863c1fef5858a808be37627 was clean. User authorizes verified commits/pushes and in-place app updates. Original Recovery/source and dirty Downloads checkout remain untouched. No new task or full audit loop is needed. Current checkpoint is recorded in /Users/karlwatson/Developer/ScratchLab-CXL-Pilot-20260912/evidence/save-playback-relay/checkpoint.json after commit.

Karl reported Save Capture opens nothing, missing Mac Watch relay despite paired companions, and forward movement drawn downward. Later confirmed whole-take video moves and AHHH is audible. Current fixes are built and installed; Karl reports the installed fixes work and explicitly confirms Mac Watch preflight Connected/green. Remaining active failure: live Mac speakers are silent except through delayed monitor; input selection forces AHHH primary output to Rane. Next narrow slice: independent primary playback output choice, retaining recording input and actual output audit. Do not claim hardware acceptance from software checks or Connected labels.

## Diagnoses and implemented fixes

- Save: late Watch Stop timeout updates sidecar diagnostics after immutable Tear review binding; reproduced exact SessionExportValidationFailure error1. Export-only binding refresh permits only same-take/same-command Stop diagnostics and appended watch_stop audit entries, preserving all other known/unknown JSON fields and previous audit entries. Review and original raw files remain immutable. Save progress/error now appears beside the button. Unrelated source changes still reject.
- Recurring relay/signing: old external stage-candidate.py explicitly repeated --sign -. Mac PID63014 logged Local network prohibited while user screenshot showed enabled switches and multiple CXL entries. User challenged repeated recurrence. Use scripts/stage_cxl_mac.py as required by AGENTS.md: Apple-issued signature, stable existing team+bundle designated requirement, universal binary, unchanged permissions/entitlements, validated receipt. Exact current Development identity5C5FDEBBEAC7E2148567C91968CBBA6B6561D298 expires2027-07-12. An old expired certificate shares its name; use fingerprint, not a name-only lookup. Do not switch to other personal team9AX3BP3DJA. No privacy reset/bypass or plist/entitlement/project-signing changes.
- Phone waiting screen exposes existing Connect Mac local-network opt-in. Watch Connected label explicitly describes iPhone link, not Mac readiness.
- Direction: Karl explicitly confirmed Take4 first move was forward on right platter. Saved CC6 ch1 from Rane ONE MKII begins36,35,34. Shared notation decoder now interprets decreasing counts as forward for that exact source/channel; both live/finalized and actual Canvas-coordinate tests verify rise. Raw MIDI/audio counter and old takes stay unchanged; other devices and left deck are not reinterpreted. No playback/audio implementation change.

## Installed candidates

Mac /Users/karlwatson/Applications/ScratchLab CXL.app, bundle com.machelpnz.scratchlab.cxl-authoring, universal, version1.0.1/build21. Verified PID69805, executable SHA256 e7721f77e4d9aa3122b0b3cfe27bd9ff4008915cc7a6f99ac125d33c30bef91f. Team2DDKGL33BU; designated requirement explicitly anchors Apple chain, team and bundle. Old app preserved at /Users/karlwatson/Developer/ScratchLab-CXL-Pilot-20260912/evidence/save-playback-relay/previous-installed/ScratchLab CXL.app. It had already exited before replacement; no capture was interrupted by the repair. Do not install intermediate rejected candidates.

Phone1F80398A-96C8-537A-B0EE-821E186918B9 bundle com.machelpnz.scratchlab and WatchFA341802-22F1-54A7-811C-68EB29F1BF0A bundle com.machelpnz.scratchlab.watchkitapp: in-place installs succeeded; launch results {'iphone': 'success', 'watch': 'success'}. No uninstall or data deletion. Mac new-PID denial search was quiet, which does not establish relay success before user enables it.

## Verification and preserved evidence

Evidence root /Users/karlwatson/Developer/ScratchLab-CXL-Pilot-20260912/evidence/save-playback-relay; RESULT.md, verification.json, installation.json, running-mac.json, companions-candidates.json and device install/launch receipts.

- Initial save baseline2unique/4executions:save fails twice, playback passes twice.
- Broad focused26unique/52executions:23unique pass/3fail. checkpoint-failures.xcresult reproduces all3on pristine e83401ff: testClicksAtHoldAndGestureEdgesRetainIndependentTimes, testOpenAndClosedFaderKeepMotionIndependentOfAudibility, testRestoredSingleCandidateDoesNotInheritAnotherSelectedGap. Eight assertions each configuration. Do not repair or claim these passed as part of this slice.
- Initial direction139unique/278executions had fixture errors; preserved direction.xcresult/log. Corrected direction-rerun139unique/278executions:276pass/2skip/0fail. New physical counter and actual screen-coordinate regression passes. Existing fixture expectations unchanged; synthetic generation now uses observed right-counter sign and preserves raw stationary copies.
- Final-focused25unique/50executions all pass. Union with direction gate163unique =162pass/1optional skip;328actual executions =326pass/2skip, because one shared test occurs in both selections.
- scripts/build.sh all PASSED using explicitly focused XCTest wrapper and isolated roots:Python84/84, signed iOS+embedded Watch, universal Mac Release, standalone Watch. This is NOT a full-suite pass; full suite remains deferred under user's prior speed instruction.509inputs matched after build; packaging script alone subsequently corrected and independently tested, all508other inputs unchanged (post-build-packaging.json).
- First signing gate rejected default certificate-name requirement; corrected explicit team requirement and inline codesign syntax. All rejected logs retained. Actual old/new binaries staged through final script produce identical requirements despite different hashes; ad hoc identity rejected (signing-regression.json). Only final-candidate was installed.
- Four operator takes, session54d8c669-5332-472a-b381-2837c4898308: all12original WAV/MOV/JSON preserved byte-for-byte and verified against all-four-captures.json. CXL-pilot-54d8c669-four-takes-raw-recovery.zip reopens with all12hashes matching. Earlier two-take backup retained. These are raw backups, not canonical packages or unsaved in-memory corrections.

## Next bounded operator action

Pending questions: enable iPhone & Watch Relay on Mac and Connect Mac on phone if offered; report Mac Apple Watch preflight. Then one fresh Movement check (no beat): forward right-platter push should rise, pull should fall; Stop and Finalize; Save Capture should display a dialog and create a readable ZIP. Actual Watch start/Stop/transfer and linked artifact must be checked separately from paired/green status. Allow the explicit macOS Local Network prompt if presented. No skilled Tear, four timed repetitions, canonical approval or training is required for this diagnostic.

Preserve new captures and inspect literal error/source before any further change. Do not repeat builds/installs without a new concrete failure. Rane ONE is pilot hardware; Seventy-Two+Twelve source/channel-pair acceptance remains separate.
