# Metadata Schema

## Purpose

Each take should have one metadata record that is easy to read and easy to validate.

This document also records the current cross-platform session metadata audit and the
canonical session-level metadata shape used by ScratchLab exports.

## Session Metadata Audit

Audit date: `2026-04-26`

### iOS guided capture

Current user-facing session metadata shown before capture starts:

- `performerName`
- `drillID` via the `Drill` picker
- `captureMode`
- `bpm` for timed capture only
- `beatEngineMode` via the timed-capture `Practice beat` selector
- `handedness`
- `deckProfile`
- `cameraProfile`
- `watchWrist`
- `practiceMode`
- `notes`

Current export persistence:

- Exports all of the fields above through the shared session metadata payload.
- Derives `scratchTypeID` and `scratchTypeName` from the existing drill selection.
- Maps the existing `practiceMode` picker into canonical `drillMode` until a separate drill-mode editor exists.
- Persists click-track defaults, optional practice-beat fields, and timing fields through the shared capture metadata path.
- Persists `takeCount`, `totalDurationSeconds`, and capture `deviceInfo` from the first completed take sidecar.
- Persists export-mix state through the shared `export_metadata.json` resolver path.

### macOS routine capture

Current user-facing session metadata shown in the routine workspace:

- performer name
- click track mode
- BPM for timed capture only
- practice beat selection for timed capture only
- handedness
- scratch type
- capture mode
- notes
- selected camera device
- selected routed audio device
- export mix selection on the completed/export-ready state

Current export persistence:

- Exports the shared session metadata payload using the routine session ID, workflow, platform, session name, created-at timestamp, `takeCount`, `totalDurationSeconds`, and sidecar-derived `deviceInfo`.
- Persists the same click, beat, and capture metadata fields as iOS through the shared export resolver and sidecar timing path.
- Persists export-mix state and derived dataset-quality metadata through the same shared export builder used by iOS.

### Current cross-platform gap

- iOS and macOS now both expose the shared click/capture mode model, timed BPM controls, optional practice-beat timing source, and export-mix choices.
- Platform differences remain in layout and device routing, not in the timing/export metadata contract.
- Both platforms export the same canonical click/beat metadata keys, with absent values left explicit as `null` instead of inventing placeholder strings.

## Canonical Session Metadata Shape

`SessionExportMetadata` is the current shared session-level payload written into ScratchLab's exported metadata documents.

| Field | Type | Required | Source / mapping |
|---|---|---|---|
| `schemaVersion` | string | yes | Export schema version |
| `sessionID` | string | yes | Shared session identifier |
| `workflow` | string | yes | `guided_capture` or `routine_capture` |
| `platform` | string | yes | Platform reported by the capture sidecar |
| `sessionName` | string | yes | User-visible session/export name |
| `createdAt` | ISO-8601 date | yes | Earliest take start for the session |
| `performerName` | string/null | no | Operator-entered performer name when available |
| `scratchTypeID` | string/null | no | Operator-entered scratch selection ID when available |
| `scratchTypeName` | string/null | no | Operator-entered scratch selection title when available |
| `drillMode` | string/null | no | Shared practice/capture-mode mapping when available |
| `bpm` | integer/null | no | Operator-entered BPM when available |
| `captureMode` | string | yes | `calibration_no_click` or `timed_click` |
| `clickEnabled` | boolean | yes | Shared mode-derived click state |
| `beatEngineMode` | string | yes | `silent`, `click_track`, `boom_bap_trainer`, `minimal_funk`, or `battle_loop` |
| `beatEnabled` | boolean | yes | True when the timing source is a generated practice beat |
| `beatPatternName` | string/null | no | Generated beat pattern token when a practice beat is selected |
| `beatPatternVersion` | string | yes | Currently `scratchlab-beats-v1` |
| `swingAmount` | number | yes | Currently `0.0` except for swung patterns like `minimal_funk` |
| `engineVersion` | string | yes | Currently `scratchlab-beat-engine-v1` |
| `countInBeats` | integer | yes | Currently `4` |
| `beatsPerBar` | integer | yes | Currently `4` |
| `clickAccentPattern` | string | yes | Currently `accent-first-beat` |
| `clickVersion` | string | yes | Currently `scratchlab-click-v1` |
| `timingPrintedToRecording` | string | yes | `true`, `false`, or `unknown` |
| `handedness` | string/null | no | Operator-entered handedness when available |
| `takeCount` | integer | yes | Count of completed takes included in the export |
| `totalDurationSeconds` | number | yes | Sum of exported take durations |
| `deckProfile` | string/null | no | iOS guided-capture deck profile when available |
| `cameraProfile` | string/null | no | iOS guided-capture camera profile when available |
| `watchWrist` | string/null | no | iOS watch wrist selection when available |
| `notes` | string/null | no | Operator-entered notes only; no generated placeholder text |
| `deviceInfo` | object/null | no | First-take sidecar device metadata |

### `deviceInfo`

When present, `deviceInfo` uses this shape:

| Field | Type | Required | Notes |
|---|---|---|---|
| `sourceDeviceName` | string | yes | Physical device or host name that created the take |
| `appSurface` | string | yes | Human-readable app surface label from the sidecar |
| `cameraPosition` | string/null | no | iOS camera position when available |
| `audioInputName` | string/null | no | iOS selected audio input label when available |
| `videoDeviceUniqueID` | string/null | no | Selected capture camera identifier |
| `videoDeviceName` | string/null | no | Selected capture camera label |
| `audioDeviceUniqueID` | string/null | no | Selected capture audio identifier |
| `audioDeviceName` | string/null | no | Selected capture audio label |

## Exported Capture Metadata Document

ScratchLab now emits `manifests/session_metadata.json` alongside the canonical manifest and take log.

`SessionExportMetadataDocument` contains:

- `session`: the shared `SessionExportMetadata` payload above
- `takes`: one entry per exported take with:
  - `takeID`
  - `takeNumber`
  - `bpm`
  - `captureMode`
  - `clickEnabled`
  - `beatEngineMode`
  - `beatEnabled`
  - `beatPatternName`
  - `beatPatternVersion`
  - `swingAmount`
  - `engineVersion`
  - `countInBeats`
  - `beatsPerBar`
  - `clickStartHostTime`
  - `recordingStartHostTime`
  - `clickAccentPattern`
  - `clickVersion`
  - `timingPrintedToRecording`

## Exported Artifact Metadata Document

ScratchLab also emits `manifests/export_metadata.json` through the same shared export resolver and archive builder.

`SessionExportArtifactMetadataDocument` contains:

- `sessionID`
- `sessionName`
- `exportMixMode`
- `captureQuality`
- `timingPrintedToRecording`
- `takes`: one entry per exported take with:
  - `takeID`
  - `takeNumber`
  - `bpm`
  - `exportMixMode`
  - `captureQuality`
  - `timingPrintedToRecording`
  - `captureMode`
  - `clickEnabled`
  - `beatEngineMode`
  - `beatEnabled`
  - `beatPatternName`
  - `beatPatternVersion`
  - `swingAmount`
  - `countInBeats`
  - `beatsPerBar`
  - `clickStartHostTime`
  - `recordingStartHostTime`
  - `clickVersion`
  - `engineVersion`
  - `scratchFile`
  - `timingFile`
  - `rawTakeFile`

Current export-mix rules:

- `exportMixMode` defaults to `scratch_only`
- `captureQuality = clean` only when `timingPrintedToRecording = false`
- `captureQuality = mixed` when timing may be present in the recorded audio
- `captureQuality = processed` for regenerated timing or remixed exports such as `scratch_with_timing` and `timing_only`
- practice beats are optional training/demo timing sources and should not be treated as ground-truth dataset audio

### Implementation note

This audit-first pass intentionally does not introduce a new cross-platform editor or state-management layer.
It documents the canonical click/capture shape and keeps both export paths on the same shared resolver instead of introducing a parallel metadata export path.

## Required Fields

| Field | Type | Required | Allowed values | Notes |
|---|---|---|---|---|
| `dj_name` | string | yes | free text | Human-readable DJ name |
| `date` | string | yes | `YYYY-MM-DD` | Session date |
| `scratch_type` | string | yes | `baby` | Fixed for MVP |
| `bpm` | integer | yes | `70`, `90`, `110` | Store as number |
| `take_number` | integer | yes | `1+` | Restart numbering within each BPM |
| `segment_count` | integer | yes | `3` | Fixed for MVP |
| `camera_id` | string | yes | `camA`, `camA+camB` | Primary video coverage used for the take |
| `audio_source` | string | yes | `serato` | Fixed for MVP |
| `watch_source` | string | yes | `watch`, `none` | Use `none` if no watch file exists |
| `verbal_slate_used` | boolean | yes | `true`, `false` | Enter an explicit boolean in `take_log.csv`; blank is invalid |
| `sync_clap_used` | boolean | yes | `true`, `false` | Enter an explicit boolean in `take_log.csv`; blank is invalid |
| `notes` | string | yes | free text | Leave blank if nothing to note |
| `files` | object | yes | source-keyed relative paths | Canonical renamed file paths for each source present in the take |
| `artifacts` | object | yes | source-keyed records | Per-file path, byte size, SHA-256, and probed media facts for each renamed artifact |

## Field Guidance

### `dj_name`

Store the readable DJ name, not the filename token.

Example:

```json
"dj_name": "DJ Prime Cuts"
```

### `date`

Use the session date, not the file import date.

### `camera_id`

Use:

- `camA` when only the primary phone is used
- `camA+camB` when both videos exist for the same take

The primary `camA` video is required for a valid take. `camB` is optional extra coverage only.

### `watch_source`

Use:

- `watch` when an Apple Watch capture exists for the take
- `none` when no watch capture was recorded

### `files`

The file keys must exactly match the renamed source files present for the take.

Use:

- `camA` and `serato` for every valid take
- `camB` only when the secondary video exists
- `watch` only when the watch CSV exists

Each value must be the canonical relative path inside the session, such as `video/...`, `audio/...`, or `watch/...`.

Do not omit a renamed source from `files`, do not add extra source keys, and do not leave stale paths from a different take or filename.

### `artifacts`

The artifact keys must exactly match the renamed source files present for the take.

Use:

- `camA` and `serato` for every valid take
- `camB` only when the secondary video exists
- `watch` only when the watch CSV exists

Do not omit a renamed source from `artifacts`, and do not add extra source keys that do not exist on disk for that take.

### `verbal_slate_used` and `sync_clap_used`

These fields must be entered explicitly in `take_log.csv`.

Use:

- `true` when the slate or sync clap happened
- `false` when it did not

Do not leave either field blank. Blank values fail rename and validation.

## Example Record

```json
{
  "dj_name": "DJ Prime Cuts",
  "date": "2026-04-12",
  "scratch_type": "baby",
  "bpm": 90,
  "take_number": 1,
  "segment_count": 3,
  "camera_id": "camA",
  "audio_source": "serato",
  "watch_source": "watch",
  "verbal_slate_used": true,
  "sync_clap_used": true,
  "notes": "",
  "files": {
    "camA": "video/DJPRIMECUTS_baby_090_take01_camA.mov",
    "serato": "audio/DJPRIMECUTS_baby_090_take01_serato.wav",
    "watch": "watch/DJPRIMECUTS_baby_090_take01_watch.csv"
  },
  "artifacts": {
    "camA": {
      "path": "video/DJPRIMECUTS_baby_090_take01_camA.mov",
      "bytes": 12345678,
      "sha256": "abc123",
      "probe": {
        "kind": "video",
        "duration_seconds": 61.2,
        "width": 1920,
        "height": 1080,
        "frame_rate_fps": 30.0,
        "codec": "h264"
      }
    },
    "serato": {
      "path": "audio/DJPRIMECUTS_baby_090_take01_serato.wav",
      "bytes": 3456789,
      "sha256": "def456",
      "probe": {
        "kind": "audio",
        "duration_seconds": 61.2,
        "sample_rate_hz": 44100,
        "channel_count": 2,
        "frame_count": 2698920,
        "sample_width_bytes": 2
      }
    },
    "watch": {
      "path": "watch/DJPRIMECUTS_baby_090_take01_watch.csv",
      "bytes": 45678,
      "sha256": "ghi789",
      "probe": {
        "kind": "csv",
        "row_count": 6102,
        "data_row_count": 6101,
        "column_count": 18
      }
    }
  }
}
```

## Validation Expectations

A take should be flagged during validation if:

- a required field is missing
- `scratch_type` is not `baby`
- `bpm` is not one of the allowed values
- `segment_count` is not `3`
- `audio_source` is not `serato`
- `watch_source` is not `watch` or `none`
- `verbal_slate_used` or `sync_clap_used` is blank or not a readable boolean
- a `files` entry is missing a renamed source, includes an unexpected source, points at the wrong canonical relative path, or references a missing file
- an artifact record set is missing a renamed source, includes an unexpected source, points at the wrong path, or no longer matches the file bytes or probed media facts on disk
- the primary `camA` or `serato` duration is too short to represent a usable take
- the `camA` and `serato` durations disagree enough to suggest a truncated or mismatched capture pair
- a watch CSV is present but does not use the expected exported motion header or does not contain enough non-empty sample rows to look like a real capture

## Storage Recommendation

Store per-take metadata inside the session manifest and keep a row in the take log for quick human review.
