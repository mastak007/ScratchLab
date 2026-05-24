# Local-only `baby_platter.json` fixture pipeline

Tooling for generating a real-motion `PlatterPositionTimeline` JSON fixture from
Karl-owned demo video, for **test use only**. Nothing here ships in any build
product, ever.

## What this is

A four-script + one-test workflow that turns a local `.mov` of a baby-scratch
take into `Tests/Fixtures/LocalOnly/baby_platter.json`, matching the existing
`PlatterPositionTimeline` Codable schema in
`ScratchLab/Models/PlatterPositionTimeline.swift:20-172` exactly. The
JSON is then validated by `ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests.swift`.

## What this is **not**

- **Not bundled.** `Tests/Fixtures/LocalOnly/baby_platter.json` is gitignored
  by `Tests/Fixtures/LocalOnly/.gitignore` and is not added to any Xcode target,
  source group, Resources phase, or Copy Bundle Resources phase. The
  `testFixtureNotBundled` test runs on every `xcodebuild test` invocation and
  fails if the file ever appears in a loaded bundle.
- **Not committed.** The fixture, the extracted frames, the per-frame
  timestamps, the saved axis, and the raw clicks all live under
  `.scratch_fixture_work/` (gitignored at repo root) or under the gitignored
  `Tests/Fixtures/LocalOnly/baby_platter.json`. The source `.mov` lives outside
  the repo entirely (e.g. `~/Downloads/`).
- **Not training data.** Nothing in `Tools/Fixtures/` or
  `Tests/Fixtures/LocalOnly/` is scanned by `TrainModels` or by any dataset
  loader. The fixture exists for decoder/renderer validation only.
- **Not coupled to app runtime.** No production code path reads this JSON. The
  schema is the only shared surface; the live capture pipeline
  (`PlatterPositionRecorder`) and the renderer are not modified by anything
  here.

## Files in this directory

| File | Purpose |
|---|---|
| `extract_frames.sh` | ffmpeg + ffprobe wrapper: PNG frames + per-frame PTS sidecar. |
| `click_baby_platter.py` | Python tkinter tool: two-click axis setup, then per-frame marker clicking at a configurable stride. Min-distance guard on axis setup; auto-discard of any saved degenerate axis. |
| `click_to_platter_timeline.py` | Converter: projects clicks onto the axis, normalizes by image width, linearly interpolates between clicks, emits `baby_platter.json`. Refuses to run on a degenerate axis (no auto-derivation). |
| `README.md` | This file. |

## Prerequisites

- macOS with Xcode toolchain (for the Swift test target).
- `ffmpeg` and `ffprobe` (Homebrew: `brew install ffmpeg`).
- Python 3 with `Pillow`. Both `/usr/bin/python3` (Apple Python) and the
  Framework Python in `PATH` have been verified. Install hint:
  `python3 -m pip install --user Pillow`.

## The runbook

All commands assume the repo root (`/Users/karlwatson/Downloads/ScratchLab`) is
the working directory.

### 1. Point at the source `.mov` (no copy / no move)

```sh
export BABY_PLATTER_VIDEO_PATH=~/Downloads/demo_baby_scratch.mov
```

The video stays outside the repo. The path is recorded into `axis.json` purely
for provenance.

### 2. Extract frames + per-frame timestamps

```sh
./Tools/Fixtures/extract_frames.sh
```

Writes to `${BABY_PLATTER_WORK_DIR:-.scratch_fixture_work/baby_platter}`:

```
frames/frame_000001.png … frame_NNNNNN.png   (native cadence, -fps_mode passthrough)
frames/timestamps.csv                         (ffprobe pts_time, one per line)
```

Re-runs are idempotent: prior PNGs and timestamps are wiped before re-extraction.
Expect ~2.6 GB for the 26.75 s / 642-frame demo at 3840×2160.

### 3. Click the marker

```sh
python3 Tools/Fixtures/click_baby_platter.py --stride 3
```

Two phases:

1. **Axis setup.** Click two clearly-separated points along the platter motion
   axis on frame 1. If your second click lands within 20 source pixels of the
   first the tool flashes a status message and waits for a real second point —
   this prevents the degenerate-axis trap that bit us once. A previously saved
   degenerate axis is auto-discarded on relaunch, so simply re-running the tool
   sends you back through axis setup; `clicks.csv` is preserved.

2. **Click loop.** Walks frames at the chosen stride (default 3 — i.e. frame
   1, 4, 7, …). Click the marker per frame. Hotkeys:

   | Key | Action |
   |---|---|
   | LMB | record marker for current frame; autosaves; advances |
   | `n` / `→` | next visited frame (no click; leaves a gap) |
   | `p` / `←` | previous visited frame |
   | `u` | undo current frame's click |
   | `s` | skip (same as `n`) |
   | `q` / Esc / window-close | save and quit |

Per `PROFILE.md`, the click priority is:

1. visible platter sticker / marker
2. visible high-contrast vinyl point
3. platter edge point
4. hand center (fallback only)

Pick one target and keep it consistent across the take.

Writes to `${BABY_PLATTER_WORK_DIR:-.scratch_fixture_work/baby_platter}`:

```
axis.json     axis_start, axis_end, image dims, stride, video path
clicks.csv    frame_index,x,y in source-image pixels (1-indexed; autosaved)
```

### 4. Convert clicks → `baby_platter.json`

```sh
python3 Tools/Fixtures/click_to_platter_timeline.py
```

Writes `Tests/Fixtures/LocalOnly/baby_platter.json` matching the
`PlatterPositionTimeline` Codable schema:

```
{
  "source": "coachAuthored",
  "startTime": <first sample t, seconds>,
  "endTime":   <last sample t, seconds>,
  "samples": [
    { "time": <t>, "position": <signed scalar>, "confidence": <0..1> },
    …
  ]
}
```

Math:

- Axis unit vector: `A = (axis_end - axis_start) / |axis_end - axis_start|`.
- Per click: `proj_px = (click - axis_start) · A`, then
  `position = proj_px / image_width` (signed, ≈ in `[-1, 1]`).
- Confidence: `1.0` for clicked frames; `0.75` for linearly-interpolated frames
  between bracketing clicks.
- Frames before the first click or after the last click are dropped, so
  `startTime == samples[0].time` and `endTime == samples[-1].time`.

The converter **refuses to run on a degenerate axis** (`|Δ| < 1 px`) — it does
not derive an axis from the click trajectory. Redo step 3 if you hit that error.

### 5. Run tests with the fixture enabled (expect 5 passes)

```sh
export BABY_PLATTER_FIXTURE_PATH="$PWD/Tests/Fixtures/LocalOnly/baby_platter.json"
xcodebuild test -scheme ScratchLab -destination 'platform=macOS' \
    -only-testing:ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests
```

Five tests run:

| Test | Behavior |
|---|---|
| `testFixtureDecodes` | Decodes via `JSONDecoder().decode(PlatterPositionTimeline.self, …)`; checks `source == .coachAuthored`, sample count, duration ≈ 26.75 s ± 1.0. |
| `testFixtureSamplesAreFinite` | No NaN / inf. |
| `testFixtureConfidenceBounds` | Every confidence in `[0.0, 1.0]`. |
| `testFixtureMovementResemblesBabyScratch` | `positionRange` span ≥ 0.05 and ≥ 2 midpoint sign-flips. |
| `testFixtureNotBundled` | `baby_platter.json` is not present in `Bundle.main`, `Bundle.allBundles`, or `Bundle.allFrameworks`. |

> **Known macOS workaround.** On this machine, `xcodebuild test` may hang
> with `Unable to Install "com.machelpnz.scratchlab"` (memory:
> `project_test_runner_hang`). The fallback is `xcrun xctest` on the built
> bundle:
> ```sh
> XCT=~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest
> # one-time: bridge the @rpath gap (DerivedData-local, not the repo)
> mkdir -p "$XCT/Contents/Frameworks"
> ln -sf ../../../../MacOS/ScratchLab.debug.dylib "$XCT/Contents/Frameworks/ScratchLab.debug.dylib"
> xcrun xctest -XCTest ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests "$XCT"
> ```

### 6. Run tests with the env var unset (expect 4 skip + 1 pass)

```sh
unset BABY_PLATTER_FIXTURE_PATH
xcodebuild test -scheme ScratchLab -destination 'platform=macOS' \
    -only-testing:ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests
```

The four decode-dependent tests `throw XCTSkip` cleanly. `testFixtureNotBundled`
always runs and passes — this is the CI-safe path and the bundle-safety net for
any future PR that might drift the fixture into a build product.

## Re-running from scratch

To start a fresh axis + click session while keeping the extracted frames:

```sh
rm .scratch_fixture_work/baby_platter/{axis.json,clicks.csv}
python3 Tools/Fixtures/click_baby_platter.py --stride 3
```

To wipe everything and re-extract from the source video:

```sh
rm -rf .scratch_fixture_work/baby_platter
./Tools/Fixtures/extract_frames.sh
```

## File-layout summary

```
Tools/Fixtures/                          ← tracked, lives in repo
    extract_frames.sh
    click_baby_platter.py
    click_to_platter_timeline.py
    README.md
Tests/Fixtures/LocalOnly/                ← tracked dir, contents gitignored
    .gitignore                           ← tracked
    baby_platter.json                    ← gitignored, generated, not bundled
.scratch_fixture_work/                   ← gitignored at repo root
    baby_platter/
        frames/frame_NNNNNN.png          ← gitignored
        frames/timestamps.csv            ← gitignored
        axis.json                        ← gitignored
        clicks.csv                       ← gitignored
ScratchLabDesktopTests/
    BabyPlatterFixtureDecodeTests.swift  ← tracked, test-target-only
```

The source `.mov` lives **outside** the repo (e.g. `~/Downloads/demo_baby_scratch.mov`)
and is referenced only through `$BABY_PLATTER_VIDEO_PATH`.
