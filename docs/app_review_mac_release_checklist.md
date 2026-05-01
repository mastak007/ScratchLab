# App Review Mac Release Checklist

Use this before uploading a macOS review-fix build.

## Clean Install

- Delete any installed `ScratchLab.app` copy you control for the review run.
- Delete local ScratchLab session draft storage at `~/Library/Application Support/ScratchLab/RoutineSessionDrafts.json`.
- Reset camera permission with `tccutil reset Camera com.machelpnz.scratchlab`.
- Reset microphone permission with `tccutil reset Microphone com.machelpnz.scratchlab`.
- Launch the Release build from Xcode or the archived app.
- Confirm the first-launch empty state shows:
  - Title: `Create your first session`
  - Body: `Start a scratch practice capture, add details, then export your session.`
  - Button: `New Session`

## New Session Verification

- Click the toolbar `New Session` button.
- Click the sidebar `New Session` button.
- Use `File > New Session`.
- On an empty install, click the empty-state `New Session` button.
- Confirm each path:
  - creates a new draft session immediately
  - switches to Routine Capture if needed
  - adds a selected item in the Sessions list
  - leaves performer, scratch type, and BPM editable after creation
  - shows a visible alert if persistence fails

## Release Build

- Run `xcodebuild -project ScratchLab.xcodeproj -scheme ScratchLabDesktop -configuration Release -destination 'platform=macOS' build`.
- Run `./scripts/build.sh`.
- Confirm the release app launches and `File > New Session` no longer opens a generic empty window workflow.

## Update Install

- Launch over an existing draft-store file and confirm previously saved sessions still load.
- Create another session and confirm the newest draft becomes selected.

## Screenshot Review

- Use `./scripts/seed_review_demo_data.sh` to create deterministic review data for a selected `Demo DJ` / `Baby Scratch` / `90 BPM` / `Full Capture` session.
- Relaunch ScratchLab after seeding so the app reloads the draft store and completed local routine capture sidecar/media from disk.
- Use `./scripts/capture_mac_review_window.sh --shot <id>` or `./scripts/capture_mac_review_window.sh --all` to capture deterministic filenames under `build/app-review-mac-screenshots/final/`.
- Capture `06-recording-in-progress.png` only while a real Routine Capture recording is active and the app shows `Stop Recording` or a visible `Recording` status.
- Capture `07-captured-result-or-export-ready.png` only after a real completed recording or after the seeded completed local routine capture loads into the normal export/share UI.
- If `07-captured-result-or-export-ready.png` shows `Save ZIP...`, click it once and confirm the save panel opens and can write a `session_*.zip` archive to a user-chosen location.
- Use this final App Store order: `01-session-workspace.png`, `02-new-session-selected.png`, `03-ready-to-record-and-metadata.png`, `06-recording-in-progress.png`, `07-captured-result-or-export-ready.png`, `04-stage-and-audio-routing.png`, `05-empty-state.png`.
- Keep `05-empty-state.png` last only; it is first-launch proof, not a primary workflow screenshot.
- Keep any overlay copy to one or two short lines, and verify the app UI remains dominant.
- Replace any marketing-only, splash-style, blank, stale, or setup-only Mac screenshots before submission.

## Final Screenshot Checklist

For `04-stage-and-audio-routing.png`:

- Camera feed is intentional, not mostly ceiling.
- Manual deck guide boxes are aligned to visible objects or desk zones.
- Audio routing section is visible.
- No fake hardware or marketing graphics are present.

For `06-recording-in-progress.png`:

- `Stop Recording` or another active recording state is visible.
- Selected session is visible.
- Camera/deck guide overlay is visible.
- Hand/person/object interaction is visible if possible.
- Camera feed is not mostly ceiling.

For `07-captured-result-or-export-ready.png`:

- `Ready to export` is visible.
- `Save ZIP`, `Share Session`, or `Reveal ZIP` state is visible.
- Completed recording or export-ready item is visible.
- No staged-only UI is shown unless the app can actually load that state.

## App Review Reply

Hello,

Thank you for the feedback.

We identified and resolved an issue where the "New Session" action on macOS was not correctly creating and selecting a session. This has been fixed so that a new session is now created, selected, and immediately visible with clear UI feedback on both clean install and update flows.

We have also replaced the macOS screenshots to accurately reflect the app in use. The updated set shows the full workflow, including session creation, setup, active recording, and completed capture/export-ready results, to clearly demonstrate the app's core functionality.

Please let us know if anything further is required.
