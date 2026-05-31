Read `AI_HANDOFF.md` first (top entry: 2026-06-01 Kid Prototype touch-audio gate stabilised).
Read `SOUL.md` and `PROFILE.md`.
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Kid Prototype — Instruction Cards Polish Slice

## Goal

Add or refine short "how to play" instruction cards before the "ahh"
interaction starts, without touching the audio engine or changing the
accepted gate behaviour. This is a small UI-only slice — **not Batch 2.**

## Starting state

- Branch: `release/testflight-1`
- HEAD: `aee94d8` — `Kid prototype: stabilize touch audio gate` (pushed)
- The Kid Mode Prototype is DEBUG-visible. The touch-audio gate is
  stable and user-accepted (see the 2026-06-01 `AI_HANDOFF.md` entry).
- The final stability commit touched `ScratchLab/Views/KidPrototypeView.swift`
  only; `KidScrubAudioPlayer.swift` was unchanged.
- Working tree may still contain unrelated dirty/untracked planning docs
  (`DEV_LOG.md`, `TASKS.md`, `analysis/`, `docs/`,
  `deep-research-skills/`). Do **not** stage or touch those.

## What to do

- Inspect the current Kid Prototype start/onboarding flow first.
- Add or clean up concise "How to play" instruction card(s) shown
  **before** Start Practice / before the "ahh" interaction begins.
- Keep changes confined to the Kid Prototype view layer.

## Rules (preserve `aee94d8` behaviour exactly)

- Preserve the accepted touch-audio rules:
  - no touch = silence
  - below 12 fresh touch = silence
  - touch in allowed zone = audio
  - release = silence
  - no sustained-scratch freeze
- No audio autoplay.
- Do **not** touch audio unless fixing a clear regression.
- No Batch 2 (no ribbon/agent/hybrid expansion).
- No BPM grid.
- No crossfader.
- No scoring / logging.
- No capture / notation / export changes.
- No AudioEngine or ScratchPlaybackLabEngine changes.
- No signing / bundle IDs / entitlements / `Info.plist` /
  `PrivacyInfo.xcprivacy` / `Copy Bundle Resources` changes.
- Small, testable diffs.

## Verification

- iOS build
- macOS build-for-testing
- Install on iPhone K
- Manual test:
  - Start screen instructions visible
  - Start Practice enters prototype
  - no touch = silence
  - below 12 = silence
  - hard scratch for 30 s = no freeze
  - release = silence

## Stop conditions

- Do not commit until the user tests on device and approves.
- Do not push.
- No `Co-Authored-By` trailer.
