# Pilot Session Runbook

## Goal

Use this guide for one real pilot session with a non-technical DJ.

For the app-side staging/export/recovery workflow after capture, use `docs/staging_operations_runbook.md`. This pilot runbook remains focused on the canonical file/session workflow.

## What You Need

- mounted iPhone for `camA`
- Serato DJ Pro recording clean WAV audio
- optional second iPhone for `camB`
- optional Apple Watch
- this repo on the Mac that will run the scripts

## 1. Create The Session

From the repo root:

```bash
python3 scripts/create_session.py "DJ Prime Cuts" 2026-04-12
```

This creates:

- the session folder
- `manifests/session_manifest.json`
- `manifests/take_log.csv`

If you rerun `create_session.py`, it only keeps those files when the existing manifest already matches the requested DJ, date, and session path. If the manifest points at a different session, or a take log is stranded without that matching manifest, the command now stops instead of silently adopting the old files.

Session path example:

```text
sessions/DJPRIMECUTS/2026-04-12/baby_scratch
```

## 2. Record Takes

Rules for every take:

- scratch type: `baby scratch`
- BPM: `70`, `90`, or `110`
- three scratch sections per take
- one `camA` video file is required
- one Serato WAV file is required

Take script:

1. Say: `baby scratch, [BPM], take [number]`
2. Clap three times
3. Scratch for about 20 seconds
4. Clap once
5. Scratch for about 20 seconds
6. Clap once
7. Scratch for about 20 seconds
8. Stop recording

After each take:

- copy the original files into `raw/`
- keep the next take number ready for that BPM

## 3. Fill `take_log.csv`

Open:

```text
sessions/DJPRIMECUTS/2026-04-12/baby_scratch/manifests/take_log.csv
```

Add one row per take.

Important:

- `take_log.csv` is the operator-edited source of truth
- if a renamed take is on disk but missing from `take_log.csv`, validation fails
- use `raw_camA` for the primary iPhone file
- use `raw_audio` for the Serato WAV file
- keep every `raw_*` value relative to this session's `raw/` folder; do not use absolute paths or `..`
- use `raw_camB` only when a second video exists for the same take
- enter `verbal_slate_used` and `sync_clap_used` explicitly as `true` or `false`
- do not leave `verbal_slate_used` or `sync_clap_used` blank; blank values fail both rename and validation

Example rows:

```csv
bpm,take_number,raw_camA,raw_camB,raw_audio,raw_watch,verbal_slate_used,sync_clap_used,notes
70,1,IMG_0070.MOV,,SERATO_0070.WAV,,true,true,clean take
90,1,IMG_0090.MOV,IMG_0090_B.MOV,SERATO_0090.WAV,WATCH_0090.CSV,true,true,watch used
110,1,IMG_0110.MOV,,SERATO_0110.WAV,,true,true,
```

## 4. Run `rename_files.py`

From the repo root:

```bash
python3 scripts/rename_files.py sessions/DJPRIMECUTS/2026-04-12/baby_scratch
```

What it does:

- reads `take_log.csv`
- copies files from `raw/`
- writes standard filenames into `video/`, `audio/`, and `watch/`
- updates `session_manifest.json`

Important:

- it stops with a conflict if the expected renamed filename already exists
- it does not create a take record unless both `camA` and `serato` exist
- if any row fails, it removes renamed files copied during that run and leaves the existing manifest untouched

## 5. Run `validate_session.py`

From the repo root:

```bash
python3 scripts/validate_session.py sessions/DJPRIMECUTS/2026-04-12/baby_scratch
```

It writes:

```text
manifests/validation_report.txt
```

## 6. Interpret Validation Results

### PASS

`Status: PASS` means:

- `manifests/session_manifest.json` exists and can be read
- every renamed take is listed in `take_log.csv`
- each valid take has `camA`
- each valid take has `serato`
- naming matches the standard
- the session has `70`, `90`, and `110` BPM coverage

### FAIL

`Status: FAIL` means the session is not ready yet.

Most likely fixes:

- `renamed files exist on disk but the take is missing from manifests/take_log.csv`
  - add the missing row to `take_log.csv`
  - rerun `rename_files.py`
  - rerun `validate_session.py`

- `missing serato audio file`
  - copy the correct WAV into `raw/`
  - update `take_log.csv` if needed
  - rerun `rename_files.py`
  - rerun `validate_session.py`

- `missing camA video file`
  - copy the primary iPhone video into `raw/`
  - do not rely on `camB` alone
  - rerun `rename_files.py`
  - rerun `validate_session.py`

- `Missing BPM set`
  - record or recover at least one usable take for that BPM
  - add the row to `take_log.csv`
  - rerun the scripts

## 7. Pilot Session Done

The pilot session is ready when:

- validation passes
- the take log matches the files on disk
- all three BPMs are covered
- the session folder is easy to review by a second person
