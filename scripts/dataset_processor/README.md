# ScratchLab Dataset Processor

`process_dataset.py` is a terminal-only offline dataset pipeline for turning ScratchLab exports and older manually labeled clips into a clean accepted/rejected dataset layout without touching the apps.

`label_clip.py` is the companion helper for creating loose-clip `.meta.json` sidecars quickly before running the processor.

`ingest_media_scratch.py` is the companion helper for first-pass normalization of local source media into canonical ScratchLab dataset-ready folders with one remuxed angle video, per-stream WAV extraction, metadata sidecars, and manifests.

`build_coach_demo_audio.py` is a small helper for refreshing bundled ScratchLab Coach demo WAVs from local development-only media. Its development manifest stays beside the script and must not be bundled.

## Supported Inputs

The processor accepts two source types under one input folder:

1. ScratchLab exported session ZIPs
2. Loose clips with sidecar metadata

Supported loose media extensions:

- `.wav`
- `.aiff`
- `.mp3`
- `.m4a`
- `.mp4`
- `.mov`

## Loose Clip Sidecars

Loose clips must have a matching metadata sidecar in the same folder:

```text
clip_001.mov
clip_001.meta.json
```

Optional motion sidecar:

```text
clip_001.motion.json
```

Required loose sidecar schema:

```json
{
  "performer": "unknown_or_name",
  "scratchType": "baby",
  "bpm": 90,
  "beatMode": "withBeat",
  "labelSource": "manual",
  "confidence": 1.0,
  "notes": "",
  "startTime": 0.0,
  "endTime": null
}
```

Rules:

- Loose clips are only scanned when `--allow-loose-clips` is passed.
- Loose clips without metadata are rejected by default.
- Use `--allow-unlabeled` if you want metadata-free or explicitly unlabeled clips routed into `rejected/unlabeled`.
- Unknown scratch types are rejected unless the clip is explicitly unlabeled.

## Creating Sidecars Quickly

Use `label_clip.py` to write `.meta.json` files next to older loose clips without hand-editing JSON.

Single-file labeling:

```bash
python3 scripts/dataset_processor/label_clip.py data/loose_clips/clip_001.mov --performer "CXL Dataset" --scratch-type baby --bpm 90 --beat-mode withBeat --confidence 0.9
```

Batch labeling:

```bash
python3 scripts/dataset_processor/label_clip.py --input-dir data/loose_clips/baby_90 --performer "CXL Dataset" --scratch-type baby --bpm 90 --beat-mode withBeat --label-source batch_manual --confidence 0.9
```

Labeling rules:

- `clip_001.mov` writes `clip_001.meta.json` beside the source clip.
- Existing sidecars are not overwritten unless `--force` is passed.
- `--bpm` must be positive when present.
- `--bpm` may be omitted for `--beat-mode noBeat` or `--beat-mode unknown`.
- Batch mode only labels supported media files and skips existing sidecars unless `--force` is passed.

## ScratchLab ZIP Processing

For each ZIP export the processor:

1. Extracts the archive into a temporary folder
2. Reads `manifests/session_manifest.json`
3. Reads `manifests/session_metadata.json`
4. Validates required audio/video presence
5. Preserves `sessionID` and `takeID` when present
6. Copies whole takes into the dataset output with `segmentation: "whole_take"`

This processor does not segment takes yet.

Future segmentation planning lives in `scripts/dataset_processor/SEGMENTATION_PLAN.md`. That plan is documentation-only and preserves the current non-destructive whole-take dataset contract until a separate offline segmenter is implemented later.

## Source Media Scratch Ingest

Use `ingest_media_scratch.py` when you have cleaner source media scratch folders and want a first-pass normalization into one canonical offline dataset layout before later review or training work.

Workflow:

1. Prepare source media locally.
2. Keep each scratch under one parent folder.
3. Run `--inspect-streams` first to list each media file's audio streams and the currently proposed roles.
4. Confirm the stream roles and provide an `--audio-map` when files contain multiple audio streams.
5. Run the real ingest only after the stream-role mapping is correct.
6. Treat the output as `reviewStatus = needs_review` until you confirm angle and stream labels.

Folder naming convention:

- Preferred: `Chirp flare_92bpm`
- Allowed: `Transformer`

Folder-name behavior:

- Folder BPM is preferred when present and stored as `bpmSource = "folder_name"`.
- Missing BPM stays unset for this first pass and is stored as `bpmSource = "missing"`.
- This ingest step does not attempt BPM inference yet.

Audio stream roles:

- `withBeat`: beat plus scratch together, exported as `*_withBeat.wav`
- `noBeat`: scratch with no beat, exported as `*_noBeat.wav`
- `beatOnly`: beat only with no scratch, exported as `*_beatOnly.wav`

Audio mapping:

- When a media file contains multiple audio streams, the ingester does not rely on filename-only beat/no-beat guesses.
- Use `--inspect-streams` to list `0:<stream_index>`, codec, duration, and the current proposed role for each audio stream.
- Provide `--audio-map path/to/audio_map.json` to map stream indexes to `withBeat`, `noBeat`, or `beatOnly`.

Example `audio_map.json`:

```json
{
  "default": {
    "0:1": "withBeat",
    "0:2": "noBeat",
    "0:3": "beatOnly"
  },
  "Crabs_92bpm": {
    "0:1": "withBeat",
    "0:2": "noBeat",
    "0:3": "beatOnly"
  }
}
```

Single-stream fallback:

- If a media file only has one audio stream and no `--audio-map` is supplied, explicit filename markers still fall back to `withBeat` or `noBeat`.
- That fallback is intentionally not used for multi-stream source media files.

Current scope:

- ingest only
- no instruction extraction yet
- no BPM inference yet
- no transcription
- no AI rewriting

Angle handling:

- source media files are sorted by filename and assigned deterministic `angle_1`, `angle_2`, `angle_3`, and `angle_4`
- each source media file is preserved once as `angle_n_video.mov`
- each mapped audio stream is extracted separately as `angle_n_withBeat.wav`, `angle_n_noBeat.wav`, or `angle_n_beatOnly.wav`
- each WAV gets its own `*.meta.json` sidecar with `audioStreamIndex`, `audioStreamRole`, `beatMode`, `trainingUse`, and `linkedVideoFile`
- the tool warns when the found angle count is not `4`

Output layout:

```text
processed_media/
  chirp_flare/
    92bpm/
      angle_1_video.mov
      angle_1_withBeat.wav
      angle_1_withBeat.meta.json
      angle_1_noBeat.wav
      angle_1_noBeat.meta.json
      angle_1_beatOnly.wav
      angle_1_beatOnly.meta.json
      angle_2_video.mov
      angle_2_withBeat.wav
      angle_2_noBeat.wav
      angle_2_beatOnly.wav
      manifest.json
```

## Coach Demo Audio Prep

Use `build_coach_demo_audio.py` only when you need to refresh the bundled ScratchLab Coach demo WAVs that ship inside the app.

Current scope:

- trims only the supported app demo scratches: `baby` and `chirpflare`
- reads the configured performance start section from local source media with `ffprobe`
- adds a small fixed offset so the exported clip starts after the explanation/talking boundary
- extracts the `noBeat` audio stream only
- writes bundled app outputs under `ScratchLab/Resources/CoachDemoAudio/`
- writes the development-only manifest outside app resources
- keeps the original source media files untouched

Current assumptions:

- Chapter 1 is instruction/explanation
- Chapter 2 is the performance section
- `audioStreamIndex = 2` is the `noBeat` stream for the current `baby` and `chirpflare` sources

Example:

```bash
python3 scripts/dataset_processor/build_coach_demo_audio.py \
  --source-root "$HOME/Movies/CXL Dataset Source" \
  --output-root ScratchLab/Resources/CoachDemoAudio \
  --offset 2.0 \
  --force
```

The helper also writes `coach_demo_manifest.dev.json` beside this script with only the runtime-safe clip name, bundled filename, and demo timing window. That development manifest must stay outside app resources.

## Output Layout

`process` mode writes:

```text
processed_dataset/
  accepted/
    baby/
      90bpm/
        take_0001/
          audio.wav
          video.mov
          meta.json
  rejected/
    missing_metadata/
      clip_001_0001/
        clip_001.mov
        meta.json
  manifest.json
```

Accepted items use canonical folders by:

- scratch type
- BPM
- sequential `take_####`

Rejected items are grouped by reason.

## Future Segmentation Planning

Segmentation is not implemented in the current dataset processor. The accepted whole-take or whole-clip items remain the source of truth for now.

Planned offline-only placeholders are documented in `SEGMENTATION_PLAN.md`:

- audio onset detection placeholder
- beat-grid segmentation placeholder
- motion peak segmentation placeholder
- manual review status for proposed segments
- per-segment `meta.json` schema planning

## Modes

`validate`

- scans inputs
- writes `manifest.json`
- does not copy media into accepted/rejected folders
- exits non-zero if any item would be rejected

`process`

- scans inputs
- writes `manifest.json`
- copies accepted items into `accepted/`
- copies rejected items into `rejected/`

## Duration Probing

The processor uses the Python standard library where possible:

- `.wav` via `wave`
- `.aiff` via `aifc` when available

If `ffprobe` is installed, it is used for optional duration probing of other media types. If `ffprobe` is missing or a probe fails, the processor keeps running and records duration as unavailable instead of modifying source files or crashing.

## Example Commands

Process ScratchLab ZIP exports:

```bash
python3 scripts/dataset_processor/process_dataset.py --input data/raw_zips --output data/processed_dataset --mode process
```

Process labeled loose clips:

```bash
python3 scripts/dataset_processor/process_dataset.py --input data/loose_clips --output data/processed_dataset --mode process --allow-loose-clips
```

Label loose clips, then process them:

```bash
python3 scripts/dataset_processor/label_clip.py --input-dir data/loose_clips/baby_90 --performer "CXL Dataset" --scratch-type baby --bpm 90 --beat-mode withBeat --label-source batch_manual --confidence 0.9
python3 scripts/dataset_processor/process_dataset.py --input data/loose_clips --output data/processed_dataset --mode process --allow-loose-clips
```

Ingest cleaner source media folders:

```bash
python3 scripts/dataset_processor/ingest_media_scratch.py \
  --input-root "$HOME/Movies/CXL Dataset Source" \
  --output-root "$HOME/Movies/CXL Dataset/processed_media" \
  --inspect-streams \
  --audio-map "$HOME/Movies/CXL Dataset/audio_map.json"
```

Run the real ingest after confirming the stream roles:

```bash
python3 scripts/dataset_processor/ingest_media_scratch.py \
  --input-root "$HOME/Movies/CXL Dataset Source" \
  --output-root "$HOME/Movies/CXL Dataset/processed_media" \
  --audio-map "$HOME/Movies/CXL Dataset/audio_map.json" \
  --performer "CXL Dataset"
```

Validate mixed inputs without copying media:

```bash
python3 scripts/dataset_processor/process_dataset.py --input data/raw_inputs --output data/processed_dataset --mode validate --allow-loose-clips
```
