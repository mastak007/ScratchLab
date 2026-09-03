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

## Take Boundary And Duration

A routine take has exactly one boundary, and it is the media.

- The take's clock starts when `AVCaptureFileOutput` reports `didStartRecordingTo`, not when `startRecording(to:)` was issued. Camera and writer startup is measurable (about 0.9 s on a warm MacBook Pro camera, longer cold) and must never be charged against the requested take length.
- The requested take length is enforced primarily by `AVCaptureMovieFileOutput.maxRecordedDuration`, which is measured in recorded media time. A wall-clock backstop is armed from the confirmed media start as a second line of defence.
- Recording duration, controller/MIDI timing, movement timing, platter telemetry, and the onboard audio tap all use that same confirmed media-start epoch. Anything observed before it is dropped, never clamped to zero.
- Finalization (muxing the onboard audio into the movie, writing sidecars) happens *after* the boundary and is not part of the take.

Two distinct duration fields are exported, and they must not be conflated:

| Field | Meaning |
| --- | --- |
| `plannedTakeDurationSeconds` | The take length the operator requested. Never overwritten by a measurement. |
| `totalDurationSeconds` | The **actual playable** duration, measured from the captured audio. |

Configs written before `plannedTakeDurationSeconds` existed carry only `takeDurationSeconds`, which at the time was the operator's requested length. Those decode with the stored value migrated into `plannedTakeDurationSeconds` so a legacy session keeps its request. The old field was overloaded — export also wrote the measured aggregate back into it — so for legacy data the two meanings cannot be told apart; retaining the stored value is the documented choice, and it is re-validated against the take-length range before it can bound a take.

A wall-clock span from sidecar `startedAt` to `endedAt` is not a take duration — it also contains startup and finalization — and is used only as a fallback when a take's audio artifact cannot be read.

## Session Date And Time Zone Policy

There is exactly one calendar date per session, and one rule for producing it.

- **A session's date is the capture device's local calendar date at session start.**
- That single value appears, identically, in:
  - the export folder name (`session_YYYY_MM_DD_...`)
  - `manifests/session_manifest.json` → `date`
  - every manifest take's `date`
- Absolute instants — `createdAt`, `generatedAt`, audit-trail timestamps — stay UTC ISO-8601 and are deliberately **not** required to fall on the same calendar day. A 08:04 NZ session is 20:04 UTC the previous day; both statements are true.

The zone is **persisted**, not inferred. `CaptureSessionConfig.sessionTimeZoneIdentifier` is stamped with the capture device's IANA zone when the session identity is created, travels in the sidecar and in `session_metadata.json`, and is what the export reads. Deriving the date from the exporting machine's current zone would re-date a session exported after travel or a DST change. A legacy session with no recorded zone is dated in **UTC** — the UTC calendar day of `createdAt`. That fallback is deliberately not the exporting device's zone: a legacy session carries no evidence of where it was captured, so the only defensible date is a reproducible one. Re-exporting the same legacy session on another machine, after travel, or across a DST boundary yields the identical folder name and manifest date, and it matches the date pre-policy exports already wrote, so recovering an old session never silently re-dates it.

`CaptureCanonicalFormatting.sessionDateString(_:timeZoneIdentifier:)` and `sessionFolderDateString(_:timeZoneIdentifier:)` are the only two formatters allowed to produce a session date. `validate_session.py` fails a session whose folder date, manifest date, and take dates do not agree.

## Generated Audio Levels

Audio ScratchLab renders itself (the timing/beat stem, and the scratch + timing mix) is held to a headroom policy:

- generated stems (`beat_only`, `timing.wav`) peak at or below **-1 dBFS**
- the scratch + timing mix peaks at or below **-0.1 dBFS** and never reaches full scale
- overshoot is corrected with a single linear attenuation across the whole buffer, never by clamping individual samples — hard clipping is audible, irreversible, and makes a stem that no longer represents the pattern
- attenuation only; a quiet pattern is never boosted
- because the correction is a pure gain, `scratch_only`, `beat_only`, and `scratch_with_beat` keep **identical exact frame counts** and stay sample-aligned

**The captured recording is never turned down to make room for generated audio.** In the mix the scratch runs at unity and headroom is found by lowering the *timing* stem: the largest gain no greater than the nominal 0.55 for which `|scratch + gain x timing| <= ceiling` holds at every frame, solved exactly in one pass. The mix ceiling sits just inside full scale rather than at -1 dBFS precisely because a hot capture (the regression fixture peaks at -0.234 dBFS) would otherwise force an attenuation of the recording. Only when the captured scratch alone exceeds the ceiling is the whole mix attenuated, and the applied mix gain is reported so that case is visible rather than silent.

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

---

## Appendix: Notation extensions

The notation file format does not need to change to support new technique families. The following capabilities ride on top of existing event types as target-side patterns and renderer behaviour — they do **not** introduce new fields, new schemas, or new validation rules.

- **Crossfader state.** Already partly modeled. Continuous lane (open / closed) plus discrete events (cut on, cut off, transformer pulse) reuse the existing fader-event type.
- **Cut timing.** Scored against target notation, but stored using the existing fader-event timing fields. Score is computed at review time; no on-disk score field is added.
- **Technique families (chirp, transform, flare, etc.).** Defined as *target patterns* — sequences of stroke direction + fader-cut events expressed using the existing event types. Live in target/reference data, not in captured-take data.
- **Overlay visualization.** Notation rendered as a transparent overlay on top of the camera feed in Practice and Performer Monitor. Purely a render concern; no schema impact.

**Gate.** Anything that would require a schema change to support a new technique goes through the same review gate as any export-format change. The default answer is "express it as a target pattern over existing event types".

See `AI_CONTEXT.md` → *Notation Extensions* for the strategic framing.
