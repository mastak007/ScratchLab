# ScratchLab

ScratchLab is an Apple-platform DJ practice and capture repo with three active app targets, a local-first capture-pipeline workflow, and a separate `nz-tax-workflow/` utility project.

## Current Scope

- `ScratchLab`: iPhone practice and capture app
- `ScratchLabWatch`: Apple Watch companion for remote control and motion capture
- `ScratchLabDesktop`: macOS companion for analyzer and review workflows
- `docs/`, `templates/`, and `scripts/`: local scratch-capture session workflow for structured recording, rename, and validation
- `nz-tax-workflow/`: standalone NZ small-business tax-prep tooling kept outside the app targets

This repo is still local-first for the canonical dataset workflow, but the app layer now also contains an upload packaging client. The `scripts/` session workflow remains the canonical dataset contract; the iOS/macOS/watch apps should be treated as staging capture frontends until their exports are validated against that contract.

Current app-side reliability boundary:

- app-created `sessionID` values are UUID-backed and globally unique
- app-created `takeID` values are explicit per-session identities such as `take-001`
- watch motion is only considered present when a linked watch artifact matches the exact `sessionID` + `takeID`
- app export/share/upload now fails closed when a package cannot satisfy the canonical manifest and take-log contract
- the staging inspector is the operator surface for blocked export, quarantine review, restore, and reconcile before export

## Repo Structure

```text
ScratchLab.xcodeproj/          Xcode project for iPhone, Mac, and Watch targets
ScratchLab/                    iPhone app sources
ScratchLabDesktop/                 macOS companion sources
ScratchLabWatch/               Apple Watch companion sources
docs/                          Capture workflow and metadata documentation
templates/                     Session manifest and take log templates
scripts/                       Build, device-run, session-create, rename, and validate scripts
nz-tax-workflow/               Separate NZ tax workflow project
build/                         Local build products
```

## Capture Pipeline

The current capture-pipeline workflow is file-based and human-readable.

Key rule: `manifests/take_log.csv` is the operator-edited source of truth for takes.

### Session Workflow

1. Create a session folder:

```bash
python3 scripts/create_session.py "DJ Prime Cuts" 2026-04-12
```

If you rerun `create_session.py`, it now only keeps an existing `session_manifest.json` and `take_log.csv` when the existing manifest already matches the requested DJ, date, and session path.

2. Copy original media into the new session's `raw/` folder.
3. Fill in `manifests/take_log.csv` with one row per take.
4. Rename and place files into the standard layout:

```bash
python3 scripts/rename_files.py sessions/DJPRIMECUTS/2026-04-12/baby_scratch
```

5. Validate the session:

```bash
python3 scripts/validate_session.py sessions/DJPRIMECUTS/2026-04-12/baby_scratch
```

The validator fails if:

- `manifests/session_manifest.json` is missing
- a renamed take exists on disk but is missing from `take_log.csv`
- the required primary files are missing for a take
- the primary `camA` or `serato` capture is too short
- the `camA` and `serato` durations disagree enough to suggest a mismatched take
- a watch CSV is malformed or too short to look like a real exported motion capture
- a `raw_*` entry points outside the session `raw/` folder
- naming does not match the standard format
- required BPM coverage is missing

### Capture Docs

- `docs/capture_spec_v1.md`
- `docs/dj_operator_quickstart.md`
- `docs/pilot_session_runbook.md`
- `docs/staging_operations_runbook.md`
- `docs/session_checklist.md`
- `docs/naming_convention.md`
- `docs/metadata_schema.md`

## Scripts

- `scripts/build.sh`: run capture-pipeline fixture tests, run the checked-in macOS XCTest suite, then build iPhone, Mac, and Watch targets
- `scripts/run-on-phone.sh`: install and launch the iPhone app on a connected device
- `scripts/create_session.py`: create a capture session folder and seed the manifest files
- `scripts/rename_files.py`: copy raw files into the standard naming layout and regenerate manifest takes
- `scripts/validate_session.py`: validate renamed media against the take log and metadata rules
- `scripts/test_capture_pipeline.py`: fixture-driven regression coverage for session create/rename/validate behavior
- `scripts/dataset_processor/label_clip.py`: create `.meta.json` sidecars for loose audio/video clips before ingest
- `scripts/dataset_processor/process_dataset.py`: offline processor for ScratchLab export ZIPs and manually labeled loose clips
- `scripts/dataset_processor/ingest_makemkv_scratch.py`: first-pass normalization of cleaner MakeMKV DVD rips into canonical per-angle video plus per-audio-stream WAV metadata folders
- `scripts/dataset_processor/build_coach_demo_audio.py`: trim bundled `baby` and `chirpflare` ScratchLab Coach demo WAVs from clean MakeMKV source files using Chapter 2 plus a fixed offset

## Offline Dataset Processor

Use the offline dataset processor when you need to turn ScratchLab export ZIPs, older manually labeled audio/video clips, or cleaner MakeMKV DVD rips into a clean dataset layout outside the apps.

Examples:

```bash
python3 scripts/dataset_processor/label_clip.py data/loose_clips/clip_001.mov --performer Qbert --scratch-type baby --bpm 90 --beat-mode withBeat --confidence 0.9
python3 scripts/dataset_processor/process_dataset.py --input data/raw_zips --output data/processed_dataset --mode process
python3 scripts/dataset_processor/process_dataset.py --input data/loose_clips --output data/processed_dataset --mode process --allow-loose-clips
python3 scripts/dataset_processor/ingest_makemkv_scratch.py --input-root "$HOME/Movies/QBERT DISC 1 CLEAN" --output-root "$HOME/Movies/QBERT DATASET/processed_makemkv" --inspect-streams --audio-map "$HOME/Movies/QBERT DATASET/audio_map.json"
python3 scripts/dataset_processor/ingest_makemkv_scratch.py --input-root "$HOME/Movies/QBERT DISC 1 CLEAN" --output-root "$HOME/Movies/QBERT DATASET/processed_makemkv" --audio-map "$HOME/Movies/QBERT DATASET/audio_map.json" --performer "Qbert"
python3 scripts/dataset_processor/build_coach_demo_audio.py --source-root "$HOME/Movies/QBERT DISC 1 CLEAN" --output-root ScratchLab/Resources/CoachDemoAudio --offset 2.0 --force
```

See `scripts/dataset_processor/README.md` for the sidecar schema, MakeMKV stream-mapping ingest rules, coach demo audio trim helper, rejection rules, and output layout.
Future offline segmentation planning is documented in `scripts/dataset_processor/SEGMENTATION_PLAN.md`; it does not change the current whole-take dataset output.

## Troubleshooting

- Missing take-log row:
  - symptom: `renamed files exist on disk but the take is missing from manifests/take_log.csv`
  - fix: add the missing row to `manifests/take_log.csv`, rerun `rename_files.py`, then rerun `validate_session.py`

- Missing Serato audio:
  - symptom: `missing serato audio file`
  - fix: copy the correct WAV into `raw/`, confirm the `raw_audio` value in `take_log.csv`, rerun `rename_files.py`, then rerun `validate_session.py`

- `camB`-only take:
  - symptom: `missing camA video file`
  - fix: add the matching primary `camA` file; `camB` is extra coverage only and cannot stand on its own

- Missing BPM set:
  - symptom: `Missing BPM set: 70 BPM has no renamed takes` or the same message for `90` or `110`
  - fix: record or recover at least one usable take for that BPM, add it to `take_log.csv`, rerun `rename_files.py`, then rerun `validate_session.py`

- Duration mismatch or truncated primary capture:
  - symptom: `camA and serato durations differ` or `serato duration is ... below the minimum`
  - fix: confirm the raw video and WAV belong to the same take, replace any truncated source file in `raw/`, rerun `rename_files.py`, then rerun `validate_session.py`

- Invalid watch CSV:
  - symptom: `does not match the expected watch CSV header` or `has only ... watch samples`
  - fix: re-export the watch CSV from the imported watch motion session, replace the bad file in `raw/` or the renamed `watch/` folder as appropriate, rerun `rename_files.py` if the canonical file changed, then rerun `validate_session.py`

- Invalid raw source path:
  - symptom: `Raw source paths must stay inside the session raw/ folder`
  - fix: copy the source file into this session's `raw/` directory, update the `raw_*` value in `take_log.csv` to a relative path under `raw/`, then rerun the scripts

## Build

Default validation:

```bash
./scripts/build.sh
```

The default build now fails fast on capture-pipeline regressions before invoking `xcodebuild`.

Platform-specific options:

```bash
./scripts/build.sh ios
./scripts/build.sh mac
./scripts/build.sh watch
./scripts/build.sh all
```

Real Apple Watch install:

```bash
./scripts/run-on-watch.sh
```

Before App Store Connect submission:

```bash
./scripts/pre_release_check.sh
```

If Xcode reports that watchOS is not installed for the device destination, install the matching runtime first:

```bash
xcodebuild -downloadPlatform watchOS
```

## Notes

- `camA` is the required primary video source for a valid take.
- `camB` is optional additive coverage only.
- `serato` audio is required for a valid renamed take.
- Apple Watch capture is optional; sessions remain usable without it.
- macOS ingest and review are optional; sessions remain usable on iPhone without the Mac companion.
