# Scratch Capture Spec v1

## Purpose

This document defines the pilot capture workflow for repeatable scratch recordings. The goal is consistency across DJs, not production polish.

## Scope

This MVP includes:

- baby scratch only
- local file storage only
- Serato DJ Pro audio capture on Mac
- iPhone video capture
- optional Apple Watch motion capture

This MVP does not include:

- other scratch types
- database storage
- machine learning training pipelines

ScratchLab app code now includes an upload/packaging client, but that app-side flow is not the canonical dataset contract. The canonical contract for repeatable dataset capture is still the file-based `scripts/` pipeline and its manifest/validation rules.

For the app staging layer:

- `sessionID` must be globally unique and is no longer derived from the capture date
- every staged take must carry a deterministic `takeID` within that session
- watch control and watch exports must carry the same `sessionID` + `takeID`
- app export is only valid when it can emit the same manifest and `take_log.csv` structure the canonical scripts expect
- share/upload must refuse packages that fail that canonical validation gate

## ScratchLab App Capture Modes

ScratchLab's shared capture setup now exposes two operator-safe modes for staged recordings:

- `Calibration`: starts recording without a click track and without the timed 4-beat count-in
- `Timed capture`: plays an internal 4/4 click track with a 4-beat count-in, then continues the click while recording

The click track is generated inside the app from code. It must not depend on random loops, external audio files, or UI timers.

Timed capture defaults to the internal click track. Optional generated practice beats can be selected for training or demo use, but they are not part of the MVP capture protocol and are not the recommended path for clean dataset collection.

Timed-capture tempo rules:

- recommended presets: `80`, `95`, `110`
- custom BPM range: `60...140`
- beat 1 uses the stronger accent pattern `accent-first-beat`
- click schema version: `scratchlab-click-v1`
- practice-beat engine version: `scratchlab-beat-engine-v1`
- practice-beat pattern version: `scratchlab-beats-v1`

Optional practice-beat timing sources:

- `Click track`: default timed-capture timing source and the recommended timing source for dataset collection
- `Boom Bap Trainer`: sparse generated kick/snare/hat pattern for practice only
- `Minimal Funk`: light generated kick/snare/hat pattern with mild swing for practice only
- `Battle Loop`: sparse generated battle-style pattern for practice only

Dataset guidance:

- `Calibration` must remain silent with no click and no beat
- `Timed capture` should use `Click track` for clean dataset collection
- practice beats are future-facing training/demo modes and should not be treated as ground-truth timing audio

## Required Capture Rules

Every take must follow these rules:

- scratch type must be `baby`
- BPM must be `70`, `90`, or `110`
- each take contains exactly `3` scratches
- each scratch lasts about `20` seconds
- all three scratches in a take use the same scratch type

## Required Take Script

Each take must follow this exact structure:

1. DJ says: `baby scratch, [BPM], take [number]`
2. DJ performs `CLAP CLAP CLAP`
3. Scratch 1 for about 20 seconds
4. DJ performs `CLAP`
5. Scratch 2 for about 20 seconds
6. DJ performs `CLAP`
7. Scratch 3 for about 20 seconds

The verbal slate and clap pattern are mandatory for MVP consistency.

## Capture Hardware

### Required

- `1 x iPhone` as the primary camera
- `Serato DJ Pro` recording clean audio to WAV on Mac
- `Pioneer S9` style scratch workflow

### Optional

- `1 x second iPhone` as a secondary camera
- `Apple Watch Series 7 or later` on the scratching hand for motion data

## Camera Framing

### Primary camera (`camA`)

Treat the primary iPhone as the required video record for the take.

- frame the record hand, crossfader hand, platter, and mixer
- keep the phone stable for the full take
- avoid face-first framing if the hands and deck are harder to read
- use landscape if it gives a clearer view of platter and fader

### Secondary camera (`camB`, optional)

Use `camB` only if it adds a helpful extra angle without slowing the session down.

- keep the same take number as `camA`
- do not replace `camA`; treat it as extra coverage

## Audio Capture

- record clean audio in Serato
- export or save as WAV whenever possible
- keep one audio file per take
- avoid phone mic audio as the primary dataset audio

## Watch Capture

If watch capture is used:

- wear the watch on the scratching hand
- start the watch recording before the verbal slate
- stop it after the third scratch
- keep one watch file per take

When the Mac initiates watch capture through the iPhone relay, treat the take as synchronized only after an explicit watch acknowledgement. A timeout or unavailable watch path is degraded capture, not synchronized capture, even if a late acknowledgement eventually arrives.

If no watch is used, the take is still valid for MVP.

## Session Folder Layout

Each session lives under:

```text
sessions/
  DJ_NAME/
    YYYY-MM-DD/
      baby_scratch/
        raw/
        70bpm/
        90bpm/
        110bpm/
        audio/
        video/
        watch/
        manifests/
```

### Folder intent

- `raw/`: untouched imports from phones, Serato, and watch before rename
- `70bpm/`, `90bpm/`, `110bpm/`: human-facing BPM buckets for review and quick session checks
- `audio/`: renamed final WAV files
- `video/`: renamed final MOV files
- `watch/`: renamed final watch CSV files
- `manifests/`: session manifest, take log, and validation output

Canonical media lives in `audio/`, `video/`, and `watch/`. The BPM folders exist so operators can quickly confirm coverage at a glance.

## Local App Recording Sidecars

ScratchLab app-created recordings are staging artifacts, not canonical take files. The iPhone companion recorder and the Mac routine recorder must save:

- a `.mov` media file
- a same-basename `.json` sidecar file

Use deterministic app-local names instead of timestamp-only names:

- `local-YYYYMMDD-ios-companion_take001_camA.mov`
- `local-YYYYMMDD-ios-companion_take001_camA.json`
- `local-YYYYMMDD-mac-routine_take001_routine.mov`
- `local-YYYYMMDD-mac-routine_take001_routine.json`

Each sidecar must record:

- the shared Capture Core schema version `scratchlab_local_recording_sidecar_v1`
- `sessionID`
- `takeID`
- `appLocalTakeNumber`
- platform and app surface
- recording role
- selected camera and audio source details available at capture time
- `startedAt` and `endedAt`
- `recordingStatus`
- `errorDescription` when capture fails
- click/capture mode metadata from the shared session config:
  - `captureMode`
  - `bpm`
  - `clickEnabled`
  - `beatEngineMode`
  - `beatEnabled`
  - `beatPatternName`
  - `beatPatternVersion`
  - `swingAmount`
  - `engineVersion`
  - `countInBeats`
  - `beatsPerBar`
  - `clickAccentPattern`
  - `clickVersion`
  - `timingPrintedToRecording`
- stable timing metadata when present:
  - `clickStartHostTime`
  - `recordingStartHostTime`

The iPhone companion recorder and the Mac routine recorder must both emit this same sidecar schema. Platform-specific source detail fields can be empty when they do not apply, but the schema version and top-level field meanings stay the same across both apps.

The deterministic app-local `sessionID`, `takeID`, and padded `takeNNN` naming pattern must also come from the shared Capture Core helpers so both recorders scan prior takes and allocate the next local take number the same way.

The same shared Capture Core path must also derive the paired `.mov` and `.json` output URLs and reject pre-existing targets before recording starts, so the iPhone and Mac staging recorders cannot drift on basename pairing or overwrite behavior.

That same shared creation path must also build and persist the initial sidecar payload for a new recording before movie capture begins, including `takeID`, `appLocalTakeNumber`, the same-basename media and sidecar file names, and the in-progress `recording` state, instead of leaving each app to assemble those fields separately.

When a recording stops or fails, both apps must also use the shared Capture Core completion path to stamp `endedAt`, set `recordingStatus`, carry any `errorDescription`, and resolve the final same-basename sidecar URL instead of each recorder mutating those fields differently.

Do not rely on Finder ordering, free-form timestamps, or operator memory to map these files back to a session. When moving app-created captures into `sessions/.../raw/`, keep the `.mov` and `.json` together.

The canonical session manifest still gets its BPM-specific `take_number` from `take_log.csv`. The local sidecar exists so pre-rename recordings stay traceable before they are imported and renamed.

## Exported Timing Metadata

ScratchLab export now writes click, beat, and export-mix metadata through the existing shared resolver path into:

- `manifests/session_manifest.json`
- `manifests/take_log.csv`
- `manifests/session_metadata.json`
- `manifests/export_metadata.json`

`session_metadata.json` records the session-level timing defaults plus per-take `clickStartHostTime` and `recordingStartHostTime` when they are available.

`export_metadata.json` records the export mix mode and dataset-quality interpretation for the staged export.

Supported export mix modes:

- `Scratch only`: default dataset-safe export; exports the recorded scratch audio and represents timing through metadata
- `Scratch + timing`: exports the recorded scratch audio plus a regenerated timing stem aligned from metadata
- `Timing only`: exports only the regenerated timing stem for alignment/debugging
- `Export stems`: exports `scratch.wav`, `timing.wav`, and `raw_take.wav` when the scratch stem differs from the raw take

Dataset-quality rules:

- `captureQuality = clean` only when `timingPrintedToRecording = false`
- `captureQuality = mixed` when timing may already be present in the recorded audio
- `captureQuality = processed` for regenerated timing or remixed exports such as `Scratch + timing` and `Timing only`
- clean ground-truth training data should use `Scratch only` with `captureQuality = clean`
- mixed captures can still be useful for review or demo workflows, but should be filtered out of ML training unless intentionally included
- timing should be reconstructed from metadata where possible instead of treating printed click or beat audio as ground truth

## Take Numbering

- take numbering restarts within each BPM set
- first valid take at a BPM is `take01`
- retakes continue upward with no skipped numbers

Examples:

- `070_take01`, `070_take02`
- `090_take01`
- `110_take01`, `110_take02`, `110_take03`

## Minimum Complete Session

For the MVP, a session is considered minimally complete when it contains:

- at least one valid baby-scratch take at `70` BPM
- at least one valid baby-scratch take at `90` BPM
- at least one valid baby-scratch take at `110` BPM

More takes are allowed, but the workflow should stay identical.

## Valid Take Requirements

A take passes MVP validation when:

- the verbal slate is present
- the triple sync clap is present before the first scratch
- the single clap separators are present between scratches
- there are exactly three scratch segments
- the BPM matches the announced BPM
- the scratch type is baby scratch throughout
- the renamed primary `camA` video file exists
- the renamed `serato` audio file exists

## Invalid Take Examples

Mark the take as invalid or retake it if any of these happen:

- wrong BPM
- mixed scratch types inside one take
- missing opening triple clap
- missing separator clap
- fewer than three scratch sections
- camera does not clearly show the scratch action
- audio is clipped, missing, or not linked to the take

## Related Documents

- `docs/dj_operator_quickstart.md`
- `docs/session_checklist.md`
- `docs/naming_convention.md`
- `docs/metadata_schema.md`
- `docs/staging_operations_runbook.md`
