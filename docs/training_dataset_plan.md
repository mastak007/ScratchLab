# Training Dataset Plan — Multi-Scratch Recognition

This document describes the **offline-only** workflow for growing the ScratchLab
training set so that detection can recognise more than just Baby Scratch.

It is intentionally written so that a maintainer with no extra context can
follow the steps, label clips, and validate the dataset locally, **without
shipping any raw media, vendor names, or rights metadata into the app or repo**.

---

## 1. What ships vs. what stays local

| Stays **local-only** (gitignored, never bundled)         | May ship in the repo / app                       |
| -------------------------------------------------------- | ------------------------------------------------ |
| Raw video / audio source files (`.mkv`, `.iso`, `.mov`)  | Source code under `ScratchLab/` and tests        |
| Per-clip ripped/intermediate exports                     | Python scripts under `scripts/` (no media)       |
| Any source DVD / vendor / ripper tool names              | This document                                    |
| `/Users/...` style paths or hostnames                    | The manifest *template* under `templates/`       |
| `LocalTrainingData/`, `TrainingData/`, `Datasets/`       | Aggregate / derived metrics (no per-clip paths)  |
| Per-clip provenance, rights, or review state             | Confusion matrix summaries                       |

The constraint is enforced two ways:

1. The `.gitignore` excludes `LocalTrainingData/`, `TrainingData/`,
   `Datasets/`, `build/training/`, `build/eval/`, `*.trace`, `*.mkv`,
   `*.iso`, `training_runs/`, `local_dataset_cache/`, and
   `offline_eval_outputs/`.
2. `scripts/dataset_processor/validate_training_manifest.py` rejects any
   manifest that contains banned strings such as `/Users/`, `MakeMKV`,
   `sourceMKV`, `processed_makemkv`, `QBERT`, `SXRATCH`, `rightsStatus`,
   or `reviewStatus`. See PART F of the implementation plan and the
   `BANNED_PROVENANCE_TOKENS` constant in that script.

---

## 2. Scratch types that are already modelled

The Swift enum [`CaptureSessionScratchType`](../ScratchLab/Models/CaptureCore.swift)
already enumerates 25 scratch families, including:

- `babyScratch`
- `chirp`
- `transform`
- `flare1Click` / `flare2Click` / `flare3Click`
- `tear`, `scribble`, `stab`, `crab`, `orbit`, `twiddle`,
  `boomerang`, `hydroplane`, `autobahn`, `military`, `prizm`
- `comboL1` … `comboL5`

The Python normalizer
[`SCRATCH_TYPE_LOOKUP`](../scripts/dataset_processor/process_dataset.py)
accepts all of these and the obvious aliases (e.g. `"1-click flare"` →
`flare_1click`). New training clips should use one of these canonical labels.

The recognition target for the next training milestone is the five families
called out in the brief:

1. Baby Scratch (regression baseline — must not break)
2. Chirp
3. 1-click flare
4. 2-click flare
5. Transform-style cuts

Any of the other 20 enum cases can be added the moment we have enough
labelled clips for them.

---

## 3. Folder layout (local machine)

A local training tree is expected to look like this. Every directory listed
here is **gitignored**:

```
LocalTrainingData/
├── clips/
│   ├── <clip_id>.mov          # or .mp4 / .wav / .m4a
│   └── <clip_id>.meta.json    # written by label_clip.py
├── manifests/
│   └── training_clips.json    # written by aggregate step (see §5)
└── reports/
    └── eval_<date>.json       # output of evaluate_classifier.py
```

The clip files themselves are not committed. Only derived, sanitised summaries
(e.g. confusion matrix counts) ever land under `docs/` or `build/`.

---

## 4. Manifest schema

The training clip manifest schema is defined by
[`templates/training_clip_manifest_template.json`](../templates/training_clip_manifest_template.json).
It is a JSON document with a top-level `clips` array. Each clip entry has:

| Field              | Type                | Notes                                                  |
| ------------------ | ------------------- | ------------------------------------------------------ |
| `clip_id`          | string              | Stable identifier. Must not include `/Users/` or paths. |
| `scratch_type`     | string              | One of the canonical types in `SCRATCH_TYPE_LOOKUP`.   |
| `bpm`              | int or null         | Required when `beat_mode` is `withBeat` or `metronome`.|
| `beat_mode`        | enum                | `withBeat` / `noBeat` / `metronome` / `unknown`.       |
| `performer`        | string              | Free-form, but must not contain a vendor / DVD name.   |
| `capture_device`   | string              | Free-form, generic device label.                       |
| `has_video`        | bool                |                                                        |
| `has_audio`        | bool                |                                                        |
| `has_motion`       | bool                | True if a paired `.motion.json` exists.                |
| `label_confidence` | float in `[0.0,1.0]`| Reviewer's confidence in the label.                    |
| `split`            | enum                | `train` / `validation` / `test`.                       |
| `duration_seconds` | float, optional     | If known, > 0.                                         |
| `notes`            | string, optional    | Free-text — the validator will scan for banned tokens. |

Fields that are **explicitly forbidden** in the manifest:

- `source_dvd`, `source_app`, `source_mkv`, `source_path`
- `rights_status`, `review_status`, `provenance`
- `path`, `absolute_path`, anything containing `/Users/`

`validate_training_manifest.py` rejects the manifest if any of those keys
appear or if any string value contains a banned token.

---

## 5. Step-by-step workflow

1. **Gather clips locally.** Place trimmed `.mov` / `.wav` files under
   `LocalTrainingData/clips/`. Each clip should be one continuous example
   of one scratch type. Long performances should be cut into per-type
   clips before this step.

2. **Label each clip.** Use the existing labeller for sidecar files:

   ```bash
   python3 scripts/dataset_processor/label_clip.py \
       LocalTrainingData/clips/example_chirp_001.mov \
       --performer in_house_demo \
       --scratch-type chirp \
       --bpm 90 \
       --beat-mode withBeat \
       --confidence 0.9
   ```

   Or label a whole directory at once with `--input-dir` and `--recursive`.

3. **Aggregate into a training manifest.** Combine the `.meta.json`
   sidecars and add `split` / `clip_id` fields to produce
   `LocalTrainingData/manifests/training_clips.json` matching
   [`templates/training_clip_manifest_template.json`](../templates/training_clip_manifest_template.json).
   This step is manual (or scripted privately) — the aggregate file
   stays local.

4. **Validate the manifest.** Run:

   ```bash
   python3 scripts/dataset_processor/validate_training_manifest.py \
       --manifest LocalTrainingData/manifests/training_clips.json
   ```

   The validator enforces canonical scratch types, splits, label-confidence
   range, BPM consistency, and the banned-token blocklist. It exits non-zero
   on any failure.

5. **Run the offline evaluation harness.** Once a classifier (any object
   that maps clip features → predicted scratch type) exists, run:

   ```bash
   python3 scripts/dataset_processor/evaluate_classifier.py \
       --manifest LocalTrainingData/manifests/training_clips.json \
       --predictions LocalTrainingData/manifests/predictions.json \
       --output build/eval/eval_$(date +%Y%m%d).json
   ```

   The output is a confusion matrix, per-label precision/recall, and a
   list of low-confidence / misclassified clip ids.

6. **Document model results in the repo.** Only the aggregate confusion
   matrix and per-label metrics may be committed (e.g. summarised in
   `DEV_LOG.md` or a future `docs/recognition_eval_<date>.md`).
   Per-clip rows, file paths, and provenance must stay local.

---

## 6. App integration plan (deferred)

The detection layer
([`MacScratchDetector`](../ScratchLabDesktop/Services/MacScratchDetector.swift))
currently emits `scratchID = "baby_scratch"` only. To add new types **without
regressing Baby Scratch**, the work is staged behind a protocol:

- New protocol `ScratchClassifying` (added in this pass) describes a single
  method that turns audio features into an optional
  `MacScratchDetectionResult`.
- `MacScratchDetector` is wrapped by `BabyScratchClassifier`, which
  conforms to `ScratchClassifying`. Existing call sites continue to work.
- A new `ScratchClassifierRegistry` accepts a list of classifiers and
  returns the highest-confidence match, defaulting to Baby Scratch when
  no other classifier is registered.
- Real classifiers for Chirp / Flare / Transform are **not** added in this
  pass. They are added later, one type at a time, each gated by a unit
  test that confirms Baby Scratch keeps the same accuracy on the existing
  reference samples.

This means the app already accepts more types in its export schema and
exports never leak banned strings, while real-time detection only
graduates to multi-type once we have data to back it.

---

## 7. Next manual steps for the maintainer

1. Drop trimmed clips into `LocalTrainingData/clips/`.
2. Run `label_clip.py` for each clip (or in batch).
3. Hand-edit a manifest matching
   `templates/training_clip_manifest_template.json` and place it under
   `LocalTrainingData/manifests/`.
4. Run `validate_training_manifest.py`.
5. Run `evaluate_classifier.py` once predictions are available.
6. Once Chirp / Flare / Transform have ≥ 30 train + 10 validation +
   10 test clips each, file a follow-up to add a real classifier
   conforming to `ScratchClassifying` and register it.
