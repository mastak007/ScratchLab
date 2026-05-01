# App Review Mac Screenshot Plan

Use real ScratchLab macOS UI only. Do not use marketing mockups, splash screens, fake UI, or large promotional overlays. If overlay text is added later in App Store Connect, keep it to one or two lines and keep the app UI dominant.

Seed deterministic review data with:

```sh
./scripts/seed_review_demo_data.sh
```

Capture the actual app window with:

```sh
./scripts/capture_mac_review_window.sh --shot 03
./scripts/capture_mac_review_window.sh --all
```

## Final App Store Order

1. `01-session-workspace.png`
2. `02-new-session-selected.png`
3. `03-ready-to-record-and-metadata.png`
4. `06-recording-in-progress.png`
5. `07-captured-result-or-export-ready.png`
6. `04-stage-and-audio-routing.png`
7. `05-empty-state.png`

Keep `05-empty-state.png` last only. It is first-launch proof, not the main product story.

## No-decks review capture setup

Use this setup when real DJ decks are not available. Do not mock hardware, add fake decks, or create marketing graphics; the screenshot still needs to show the real app UI and a real camera feed.

- Use any flat desk/table surface.
- Place 2-3 visible objects under the overlay zones, such as a laptop, keyboard, mousepad, notebook, phone, controller, vinyl sleeve, or any flat object.
- Tilt the Mac camera down so the desk/object area fills most of the camera frame.
- Keep ceiling/bright light under 20% of the camera frame.
- Align the `Left Deck` box over one object/area.
- Align the `Mixer` box over the middle object/area.
- Align the `Right Deck` box over another object/area.
- It does not need to be real DJ hardware.
- The goal is to show real app guidance, real camera framing, and active capture.

## Required Shots

### 01 Session Workspace

- Show the Routine Capture workspace with a selected seeded session.
- Keep the session list and editor visible.
- The selected session should show real metadata, including `Demo DJ`, `Baby Scratch`, and `90 BPM`.

### 02 New Session Created

- Click `New Session` once from the real app.
- Capture after the new draft appears selected.
- The UI must visibly change within one click.

### 03 Ready To Record And Metadata

- Show the seeded `Demo DJ` session with `Baby Scratch Warmup` notes.
- Keep `Start Recording`, `BPM 90`, `Scratch Type: Baby Scratch`, and `Capture Mode: Full Capture` visible.
- Avoid sidebar scroll positions where `Start Recording` or metadata appears ambiguous.
- Keep the camera/deck stage visible and reduce empty space by sizing the window so the stage fills the right side.

### 06 Recording In Progress

- Start a real Routine Capture recording before capture.
- Capture while the app visibly shows `Stop Recording` or a `Recording ...` status.
- Keep the selected session, deck/camera stage, and recording state visible.
- Do not use a seeded or static fake recording indicator.

### 07 Captured Result Or Export Ready

- Show the real UI after a capture completes.
- Acceptable sources:
  - stop the real recording used for `06-recording-in-progress.png`
  - run `./scripts/seed_review_demo_data.sh` and relaunch so the app loads the seeded completed local routine capture sidecar/media
- The screenshot must show the selected session, a completed recording filename, and `Save ZIP...` or `Share Session` only when backed by the real completed local capture state.

### 04 Stage And Audio Routing

- Use this after the core workflow shots, not as a primary screenshot.
- Prioritize the deck/camera stage and guide overlay.
- Keep audio routing visible only as supporting capture workflow context.
- If possible, frame the physical deck/hand interaction in the live camera view and reduce ceiling/dead space.

### 05 Empty State

- Use a clean install or remove the routine draft store.
- Capture the first-launch empty state with:
  - `Create your first session`
  - `Start a scratch practice capture, add details, then export your session.`
  - `New Session`

## App Review Reply

Hello,

Thank you for the feedback.

We identified and resolved an issue where the "New Session" action on macOS was not correctly creating and selecting a session. This has been fixed so that a new session is now created, selected, and immediately visible with clear UI feedback on both clean install and update flows.

We have also replaced the macOS screenshots to accurately reflect the app in use. The updated set shows the full workflow, including session creation, setup, active recording, and completed capture/export-ready results, to clearly demonstrate the app's core functionality.

Please let us know if anything further is required.
