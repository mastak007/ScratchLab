# ScratchLab Release Audit Checklist

Use this checklist before any TestFlight or App Store Connect submission. Treat every unchecked or failed item as a release blocker unless it is explicitly documented as a non-blocking known risk in `DEV_LOG.md`.

## Preflight

- [ ] Review the latest `DEV_LOG.md` entry and confirm the current release scope matches the intended submission.
- [ ] Review `TASKS.md` and confirm no open release-blocking task is still unresolved.
- [ ] Confirm the current branch/worktree only contains intended release changes.
- [ ] Confirm no bundle identifier, target, scheme, signing, or App Store metadata change is being introduced unless explicitly planned outside this checklist.
- [ ] Confirm the repo still contains:
  - `docs/release_audit_checklist.md`
  - `docs/codex_release_audit_prompt.md`
  - `DEV_LOG.md`
  - `TASKS.md`

## Automated Verification

- [ ] Run `./scripts/pre_release_check.sh`.
- [ ] Confirm `./scripts/build.sh` passed inside the pre-release check.
- [ ] Confirm the macOS XCTest plan passed.
- [ ] Confirm iOS, macOS, and watchOS builds all completed successfully.
- [ ] Confirm any focused regression tests added for the release issue also passed.

## iOS Layout And Navigation Audit

- [ ] Test on an iPhone SE or similarly small iPhone.
- [ ] Test on a standard modern iPhone size.
- [ ] Confirm the guided-capture `System Check` screen fits vertically without clipping actions.
- [ ] Confirm all primary and secondary buttons remain reachable without layout overlap.
- [ ] Confirm no ScratchLab overlay covers iOS navigation or status-bar-safe areas.
- [ ] Confirm back/navigation controls are visible and tappable on every guided-capture step.
- [ ] Confirm session setup, system check, camera setup, audio setup, motion setup, record, and review screens all respect safe areas.
- [ ] Confirm modal sheets and pickers do not hide required confirmation buttons.

## Session And Sidebar Audit

- [ ] Confirm the active session is clearly accessible.
- [ ] Confirm `Recent Sessions` is capped per the current shared presentation policy.
- [ ] Confirm `All Sessions` still exposes retained real session history.
- [ ] Confirm completed, exported, or artifact-backed sessions are not silently removed just because more sessions exist.
- [ ] Confirm stale empty/setup-only drafts can be pruned without affecting meaningful capture history.
- [ ] Confirm selecting a session updates ordering/open history as expected.

## Practice Audit

- [ ] Confirm iOS Practice beat controls are visible and tappable.
- [ ] Confirm macOS Practice beat controls are visible and tappable.
- [ ] Confirm beat enable/disable, BPM, beat-mode selection, and play/stop all work on supported surfaces.
- [ ] Confirm Practice mode does not create capture sessions.
- [ ] Confirm entering/leaving Practice does not pollute session history or trigger unintended record setup mutations.

## Record Flow Audit

- [ ] Confirm setup screens do not create new sessions on their own.
- [ ] Confirm a new session is only created when the user explicitly starts one or when recording begins where intended by the shared flow.
- [ ] Confirm the `System Check` to record flow remains intact.
- [ ] Confirm record-start, count-in, stop, and review transitions still work.
- [ ] Confirm guided capture and routine capture continue to preserve session/take identity correctly.
- [ ] Confirm required metadata validation still blocks invalid recording starts.

## watchOS Audit

- [ ] Confirm the watch app launches cleanly.
- [ ] Confirm watch branding and launch presentation are correct for release.
- [ ] Confirm watch motion capture can start when requested from the supported flow.
- [ ] Confirm watch capture can stop cleanly.
- [ ] Confirm the captured watch artifact links to the correct `sessionID` and `takeID`.
- [ ] Confirm the host app does not falsely report watch motion as linked when the exact artifact is missing.

## Export And Schema Audit

- [ ] Confirm export/share validation still fails closed on incomplete or mismatched capture data.
- [ ] Confirm `session_metadata.json`, `export_metadata.json`, manifests, and related archive content match the shared schema.
- [ ] Confirm session metadata values remain aligned with the canonical dataset contract.
- [ ] Confirm selected-take export behavior still uses the intended metadata group.
- [ ] Confirm calibration, click-track, and beat metadata remain correct for the chosen capture mode.
- [ ] Confirm ZIP export/share paths work without deleting the generated archive unintentionally.

## App Review Compliance Audit

- [ ] Confirm no dead buttons, fake states, or unsupported claims remain visible in production UI.
- [ ] Confirm permission copy matches real device usage.
- [ ] Confirm entitlements still match real features in the shipped build.
- [ ] Confirm debug-only or staging-only UI is hidden in release paths.
- [ ] Confirm no review-risk placeholder media, shell UI, or unfinished flows remain.

## Screenshot Validation

- [ ] Confirm the current screenshot plan still matches the real production UI.
- [ ] Confirm App Review screenshots do not show clipped controls, covered navigation, or debug states.
- [ ] Confirm macOS review screenshots still use the documented real-window capture flow.
- [ ] Confirm watch screenshots/branding remain aligned with the current shipped assets.

## Manual Smoke Test Notes

- [ ] Record manual smoke-test results for:
  - iPhone SE or equivalent small iPhone
  - standard iPhone
  - guided-capture `System Check`
  - guided-capture back/navigation controls
  - macOS small-window layout
  - watchOS launch and capture/linking
  - Practice beat controls
  - record/review/export flow
  - App Review screenshots
- [ ] Add any remaining non-blocking risk to `DEV_LOG.md`.

## Final ASC Submission Checklist

- [ ] Confirm the release candidate build is the same one that passed the audit.
- [ ] Confirm all release-blocking issues found during audit were fixed and retested.
- [ ] Confirm `DEV_LOG.md` includes the final audit/build result and remaining risks.
- [ ] Confirm `TASKS.md` reflects the completed audit task.
- [ ] Confirm no unreviewed metadata, bundle, scheme, or target changes are included.
- [ ] Confirm screenshot assets and App Review notes are ready.
- [ ] Confirm the team is ready to submit/upload outside this script-driven workflow.
